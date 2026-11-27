#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=staging_cell.sh
source "$(dirname "${BASH_SOURCE[0]}")/staging_cell.sh"
# shellcheck source=../layer_includes.sh
source "$(dirname "${BASH_SOURCE[0]}")/../layer_includes.sh"
# `mise run backup:now` stages a first copy that one pre-sync cannot, in the Pod backup-seed, and its Backup then succeeds:
# songmaker's PreBackupPod gets a pre-sync budget of 20 seconds and a bandwidth limit on its bucket step, and the bucket holds
# 240 MiB. A Backup of its own fails at the bucket's pre-sync, and backup:now's seeds, then makes a Backup whose snapshot
# holds the bucket by key, size and sha256. Beside a seed that copies, a second backup:now and a Backup are refused; a
# backup:now sent TERM while it seeds leaves no seed Pod and no Backup; an ended Pod named backup-seed is deleted before the
# next seed; and a pod that mounts the staging claim makes the seed refuse. It prints names, counts, digests and sentences,
# never a key of the bucket or a secret. It needs APP_MANIFEST (the web's manifest, which the client Pod that fills the bucket
# is furnished from) and the Kustomization of the layer in flux-system, which it suspends while it patches the PreBackupPod.
export KUBECONFIG="$HOME/.kube/config"
namespace="$SONGMAKER_NAMESPACE"
export APP_NAMESPACE="$namespace"
# shellcheck source=../objectstore/client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../objectstore/client_pod.sh"
staging=/data/backup-staging
seed_pod=backup-seed
holder=staging-holder
reading_uid="$(kubectl --namespace "$namespace" get deployment web --output jsonpath='{.spec.template.spec.securityContext.runAsUser}')"
[ -n "$reading_uid" ] || fail "the Deployment web of $namespace sets no runAsUser, the reading uid"
work="$(mktemp -d)"
background_pid=

cleanup() {
  local cell_status=$?
  [ -z "$background_pid" ] || ! kill -0 "$background_pid" 2>/dev/null || kill -TERM "$background_pid" 2>/dev/null || true
  [ -z "$background_pid" ] || wait "$background_pid" 2>/dev/null || true
  restore_pre_backup_pod || cell_status=1
  delete_object --namespace "$namespace" delete pod "$seed_pod" "$holder" --ignore-not-found --wait --timeout=2m
  delete_backups
  remove_client
  rm -rf -- "$work"
  delete_restic_objects
  end_deletions "$cell_status"
}
trap cleanup EXIT
install_client

# backup_now <output file>: the task, run as an operator runs it in the foreground; a background run starts the script itself, so
# that a signal reaches it.
backup_now() { scripts/backup_now.sh "$namespace" >"$1" 2>&1; }
# seed_runs: the Pod backup-seed runs its containers.
seed_runs() { [ "$(kubectl --namespace "$namespace" get pod "$seed_pod" --ignore-not-found --output jsonpath='{.status.phase}')" = Running ]; }
backup_names() { kubectl --namespace "$namespace" get backups.k8up.io --output name | sort; }
snapshot_count() {
  run_restic "$namespace" "$1" "restic --no-cache snapshots --json --path $staging | jq length"
  [ "$restic_exit" = 0 ] || fail "the staging snapshots of $namespace cannot be read (exit $restic_exit)"
  echo "$restic_output"
}

run_client plant-clear "$credentials_secret" clear "$bucket_variable"
run_client plant-large "$credentials_secret" plant "$bucket_variable" large
client_output digests-large digests "$bucket_variable"
bucket_before="$client_log"
objects="$(bucket_listing "$bucket_before" | cut -d' ' -f2)"
echo "planted the bucket $bucket of $namespace through a client Pod furnished as its web: $objects objects of 40 MiB"

# A pre-sync budget of 20 seconds and 3 MiB/s on the bucket's step: one pre-sync stages a fraction of the set.
suspend_layer
set_env stager PRE_SYNC_BUDGET 20
set_env bucket RCLONE_BWLIMIT 3M
refused_backup large-backup '^stage: bucket-pre-sync ran out of its budget$'
! staged_file_exists /staging/MANIFEST || fail "the Backup that ran out of its budget left a MANIFEST"
end_backup large-backup
echo "a Backup of its own ran out of the bucket's pre-sync budget and left no MANIFEST"

snapshots_before="$(snapshot_count snapshots-before)"
backups_before="$(backup_names)"
scripts/backup_now.sh "$namespace" >"$work/first" 2>&1 &
background_pid=$!
until_true 300 "the seed Pod runs" seed_runs
# A second backup:now refuses while the seed copies, and makes and deletes nothing.
status=0
backup_now "$work/second" || status=$?
[ "$status" = 1 ] && grep -q "another run's seed Pod $seed_pod of $namespace is still running" "$work/second" ||
  fail "a second backup:now beside a seed ended $status with '$(cat "$work/second")'"
seed_runs || fail "the second backup:now touched the seed Pod"
# A Backup created beside the seed is refused by its stager's guard.
refused_backup seed-held '^stage: refused: [0-9]+ other pods mount the staging claim$'
end_backup seed-held
echo "beside a seed that copies, a second backup:now refused naming the Pod and a Backup was refused by its guard"
status=0
wait "$background_pid" || status=$?
background_pid=
cat "$work/first"
[ "$status" = 0 ] || fail "backup:now ended $status after its seed"
grep -q "the seed of $namespace staged its copies" "$work/first" || fail "backup:now did not say that its seed staged the copies"
[ -z "$(kubectl --namespace "$namespace" get pod "$seed_pod" --ignore-not-found --output name)" ] || fail "the seed Pod is left after backup:now"
new_backups="$(comm -13 <(echo "$backups_before") <(backup_names) | grep -c '/backup-now-' || true)"
[ "$new_backups" = 1 ] || fail "backup:now made $new_backups Backups named backup-now-"
[ "$(snapshot_count snapshots-after)" = "$((snapshots_before + 1))" ] || fail "the repository does not hold exactly one snapshot more than before backup:now"
run_restic "$namespace" snapshot-bucket '
  set -e
  tab="$(printf "\t")"
  staging='"$staging"'
  echo "manifest-bucket $(restic --no-cache dump --path "$staging" latest "$staging/MANIFEST" | grep -c "^file$tab[0-9]*$tab[0-9]*${tab}bucket/" || true)"
  '"$snapshot_bucket_digests"
[ "$restic_exit" = 0 ] || fail "the newest staging snapshot of $namespace cannot be read (exit $restic_exit)"
[ "$(value bucket)" = "$(bucket_listing "$bucket_before")" ] || fail "the newest snapshot's bucket/ differs by key, size or bytes from the bucket"
[ "$(value manifest-bucket)" = "$objects" ] || fail "MANIFEST lists $(value manifest-bucket) bucket files, not $objects"
echo "backup:now seeded, its Backup Succeeded with the restore test, and the one new snapshot holds the bucket's $objects objects by key, size and sha256, listed in MANIFEST"

# A backup:now sent TERM while its seed copies leaves no seed Pod and no Backup. The set is planted anew, so the seed copies.
run_client plant-clear-again "$credentials_secret" clear "$bucket_variable"
run_client plant-large-again "$credentials_secret" plant "$bucket_variable" large
backups_before="$(backup_names)"
scripts/backup_now.sh "$namespace" >"$work/terminated" 2>&1 &
background_pid=$!
until_true 300 "the seed Pod runs" seed_runs
kill -TERM "$background_pid"
wait "$background_pid" 2>/dev/null || true
background_pid=
[ -z "$(kubectl --namespace "$namespace" get pod "$seed_pod" --ignore-not-found --output name)" ] || fail "the seed Pod is left after backup:now was sent TERM"
[ "$(backup_names)" = "$backups_before" ] || fail "a Backup was made by the backup:now that was sent TERM"
echo "a backup:now sent TERM while it seeded left no seed Pod and made no Backup"

# An ended Pod named backup-seed is deleted before the next seed, which a pod on the staging claim then refuses.
# staging_pod <name> <command as a JSON array>: a Pod at the reading uid that mounts the staging claim read-only and runs the command.
staging_pod() {
  NAME="$1" COMMAND="$2" IMAGE="$PROBE_IMAGE" USER_ID="$reading_uid" yq --null-input --output-format json '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false, "enableServiceLinks": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": env(USER_ID), "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "holder", "image": strenv(IMAGE), "command": env(COMMAND),
         "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
         "volumeMounts": [{"name": "staging", "mountPath": "/staging", "readOnly": true}]}],
       "volumes": [{"name": "staging", "persistentVolumeClaim": {"claimName": "backup-staging", "readOnly": true}}]}}' |
    kubectl --namespace "$namespace" create --filename - >/dev/null
}
staging_pod "$seed_pod" '["true"]'
kubectl --namespace "$namespace" wait "pod/$seed_pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m >/dev/null
staging_pod "$holder" '["sleep", "3600"]'
kubectl --namespace "$namespace" wait "pod/$holder" --for=condition=Ready --timeout=5m >/dev/null
backups_before="$(backup_names)"
status=0
backup_now "$work/held" || status=$?
[ "$status" = 1 ] && grep -q "the earlier seed Pod $seed_pod of $namespace had ended; it was deleted" "$work/held" &&
  grep -q "the seed of $namespace refused: 1 other pods mount the staging claim" "$work/held" || fail "a seed beside a holder ended $status with '$(cat "$work/held")'"
[ "$(backup_names)" = "$backups_before" ] || fail "a Backup was made by the backup:now whose seed was refused"
echo "an ended Pod named $seed_pod was deleted, and a pod on the staging claim made the seed refuse with no Backup"

# No backup:now output holds a stager's line, and no output names a planted key.
for output in "$work"/*; do
  ! grep -q '^stage: \|large-object-' "$output" || fail "an output of backup:now holds a stager's line or a planted key"
done
echo "no output of backup:now holds a stager's line or the name of a planted key"
