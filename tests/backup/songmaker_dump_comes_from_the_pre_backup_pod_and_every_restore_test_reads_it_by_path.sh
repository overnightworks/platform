#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# songmaker's dump comes from the PreBackupPod and every restore test reads its dump by path; prints names, counts and
# verdicts, never a row, a dump byte or a secret. It runs after the cells of
# backup_restores_keeps_repositories_apart_and_prunes_by_the_rule.sh, which made each namespace's repository.
export KUBECONFIG="$HOME/.kube/config"
namespace="$SONGMAKER_NAMESPACE"
dump_path="/$namespace-postgres.dump"
check_pod=staging-dump-check
backup_name=pre-backup-pod-backup

cleanup() {
  local cell_status=$?
  delete_object --namespace "$namespace" delete pod "$check_pod" --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$namespace" delete backup "$backup_name" --ignore-not-found --wait --timeout=2m
  end_deletions "$cell_status"
}
trap cleanup EXIT

# backup_pods <namespace>: how many Pods of the namespace carry a backup command.
backup_pods() {
  kubectl --namespace "$1" get pods --output json |
    yq --input-format json '[.items[] | select(.metadata.annotations["k8up.io/backupcommand"] != null)] | length'
}

# run_restic <name> <shell script>: a Pod built from songmaker's restore test init container, so it holds the namespace's
# repository credentials and nothing more; sets restic_output and restic_exit to what the script wrote and its exit code.
# shellcheck disable=SC2034 # restic_output and restic_exit are this function's results for the cells below.
run_restic() {
  local name="$1" script="$2" manifest
  manifest="$(kubectl --namespace "$namespace" get cronjob restore-test --output json |
    NAME="$name" SCRIPT="$script" yq --output-format json \
      '.spec.jobTemplate.spec.template.spec as $spec | $spec.initContainers[0] as $dump |
       { "apiVersion": "v1", "kind": "Pod", "metadata": { "name": strenv(NAME) }, "spec": ($spec | del(.initContainers) |
           .volumes |= map(select(.name == "restore")) |
           .containers = [$dump | .name = "restic" | .command = ["sh", "-c", strenv(SCRIPT)]]) }')"
  kubectl --namespace "$namespace" create --filename - <<<"$manifest" >/dev/null
  kubectl --namespace "$namespace" wait "pod/$name" --timeout=5m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'
  restic_exit="$(kubectl --namespace "$namespace" get "pod/$name" \
    --output jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  restic_output="$(kubectl --namespace "$namespace" logs "pod/$name")"
  kubectl --namespace "$namespace" delete pod "$name" --wait --timeout=2m >/dev/null
}

# restore_test_passes <namespace>: runs the namespace's restore test CronJob once; returns 0 when its Job completes.
restore_test_passes() {
  local target="$1" job="pre-backup-pod-restore-test" outcome=
  kubectl --namespace "$target" create job "$job" --from=cronjob/restore-test >/dev/null
  until_true 600 "the Job $target/$job ends" job_has_ended "$target" "$job"
  case "$(job_conditions "$target" "$job")" in *Complete*) outcome=passed ;; esac
  kubectl --namespace "$target" delete job "$job" --cascade=foreground --wait --timeout=2m >/dev/null
  [ "$outcome" = passed ]
}
job_conditions() {
  kubectl --namespace "$1" get job "$2" --output jsonpath='{.status.conditions[?(@.status=="True")].type}'
}
job_has_ended() {
  case "$(job_conditions "$1" "$2")" in *Complete* | *Failed*) return 0 ;; esac
  return 1
}

# Cell 1: the staging claim is Bound on the Retain class with prune disabled before any Backup of this script.
claim="$(kubectl --namespace "$namespace" get pvc backup-staging --output json)"
[ "$(yq --input-format json '.status.phase' <<<"$claim")" = Bound ] || fail "the claim backup-staging of $namespace is not Bound"
[ "$(yq --input-format json '.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]' <<<"$claim")" = disabled ] ||
  fail "the claim backup-staging of $namespace does not disable the prune"
volume="$(yq --input-format json '.spec.volumeName' <<<"$claim")"
[ "$(kubectl get pv "$volume" --output jsonpath='{.spec.persistentVolumeReclaimPolicy}')" = Retain ] ||
  fail "the volume of backup-staging in $namespace is not on the Retain class"
[ "$(kubectl --namespace "$namespace" get job backup-staging-binder --output jsonpath='{.status.succeeded}')" = 1 ] ||
  fail "the Job backup-staging-binder of $namespace has not completed"
echo "the staging claim of $namespace is Bound on the Retain class with prune disabled, bound by its completed Job"

# Cell 3: the dump the PreBackupPod's container makes over the Service holds the live database's table digests. A Pod made
# from the PreBackupPod's own spec stands in for the one k8up runs only during a Backup, which would end before it is read.
kubectl --namespace "$namespace" get prebackuppod files --output json |
  NAME="$check_pod" yq --input-format json --output-format json \
    '{ "apiVersion": "v1", "kind": "Pod", "metadata": { "name": strenv(NAME) }, "spec": .spec.pod.spec }' |
  kubectl --namespace "$namespace" create --filename - >/dev/null
kubectl --namespace "$namespace" wait "pod/$check_pod" --for=condition=Ready --timeout=5m ||
  { kubectl --namespace "$namespace" describe "pod/$check_pod" >&2; fail "the PreBackupPod's container of $namespace did not turn Ready on a finished dump"; }
digests='pg_restore --file=- | sh /etc/postgres-checks/table-digests.sh'
live_digests="$(kubectl --namespace "$namespace" exec postgres-0 --container postgres -- sh -c "pg_dump --format=custom | $digests")"
staged_digests="$(kubectl --namespace "$namespace" exec "$check_pod" -- cat /staging/postgres.dump |
  kubectl --namespace "$namespace" exec --stdin postgres-0 --container postgres -- sh -c "$digests")"
[ -n "$live_digests" ] || fail "the live database of $namespace gave no table digests"
[ "$staged_digests" = "$live_digests" ] || fail "the staged dump of $namespace differs from the live database in its table digests"
echo "the staged dump of $namespace restores to the live database's table digests: $(wc -l <<<"$live_digests") tables, equal"
kubectl --namespace "$namespace" delete pod "$check_pod" --wait --timeout=2m >/dev/null

# Cell 2, first half: no StatefulSet carries a backup command in songmaker, and one does in a namespace without ./files.
[ -z "$(kubectl --namespace "$namespace" get statefulset postgres \
  --output jsonpath='{.spec.template.metadata.annotations.k8up\.io/backupcommand}')" ] ||
  fail "the StatefulSet postgres of $namespace still carries a backup command"
for other in $BACKUP_NAMESPACES; do
  [ "$other" != "$namespace" ] || continue
  [ -n "$(kubectl --namespace "$other" get statefulset postgres \
    --output jsonpath='{.spec.template.metadata.annotations.k8up\.io/backupcommand}')" ] ||
    fail "the StatefulSet postgres of $other carries no backup command, though it has no PreBackupPod"
done
[ "$(backup_pods "$namespace")" = 0 ] || fail "a Pod of $namespace carries a backup command outside a Backup"
echo "no StatefulSet of $namespace carries a backup command, and no pod does outside a Backup"

# Cell 5, before: the snapshots the repository holds.
run_restic snapshots-before 'restic --no-cache snapshots --json | jq length'
[ "$restic_exit" = 0 ] || fail "the snapshots of $namespace cannot be counted (exit $restic_exit)"
snapshots_before="$restic_output"

# One Backup, as the Schedule would start it. Cell 2, second half: at every look during it, at most one Pod of the
# namespace carries a backup command, and one does at some look.
kubectl --namespace "$namespace" get schedule postgres --output json |
  NAME="$backup_name" yq --input-format json --output-format json \
    '{ "apiVersion": "k8up.io/v1", "kind": "Backup", "metadata": { "name": strenv(NAME) },
       "spec": { "backend": .spec.backend, "podConfigRef": .spec.podConfigRef } }' |
  kubectl --namespace "$namespace" create --filename - >/dev/null
seen_one=false
deadline=$((SECONDS + 300))
while :; do
  pods="$(backup_pods "$namespace")"
  [ "$pods" -le 1 ] || fail "$pods Pods of $namespace carry a backup command during the Backup"
  [ "$pods" != 1 ] || seen_one=true
  reason="$(kubectl --namespace "$namespace" get backup "$backup_name" \
    --output jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')"
  [ -z "$reason" ] || break
  if [ "$SECONDS" -ge "$deadline" ]; then
    kubectl --namespace "$namespace" describe backup "$backup_name" >&2
    fail "the Backup $backup_name of $namespace did not complete within 5 minutes"
  fi
  sleep 1
done
[ "$reason" = Succeeded ] || fail "the Backup $backup_name of $namespace ended with reason $reason"
[ "$seen_one" = true ] || fail "no Pod of $namespace carried a backup command at any look during the Backup"
echo "exactly one pod of $namespace carried a backup command during the Backup"

# Cell 5, after: one more snapshot, whose only path is the dump streamed from the PreBackupPod's file, in custom format.
run_restic snapshots-after '
  restic --no-cache snapshots --json | jq length
  restic --no-cache snapshots --json | jq --raw-output ".[].paths[]" | sort -u
  restic --no-cache ls --json latest | jq --raw-output "select(.type == \"file\") | .path"
  # An early exit of head kills restic by SIGPIPE while it holds its read lock, which a Prune waits out; draining ends it.
  restic --no-cache dump --path "/$(NAMESPACE)-postgres.dump" latest "/$(NAMESPACE)-postgres.dump" | { head -c 5; cat >/dev/null; }'
[ "$restic_exit" = 0 ] || fail "the snapshot of $namespace cannot be read (exit $restic_exit)"
mapfile -t listing <<<"$restic_output"
[ "${listing[0]}" = "$((snapshots_before + 1))" ] || fail "the Backup left ${listing[0]} snapshots in $namespace, after $snapshots_before"
[ "${#listing[@]}" = 4 ] || fail "the snapshots of $namespace hold paths or files beside the dump"
[ "${listing[1]}" = "$dump_path" ] || fail "the snapshots of $namespace hold the path ${listing[1]}, not $dump_path"
[ "${listing[2]}" = "$dump_path" ] || fail "the latest snapshot of $namespace holds ${listing[2]}, not $dump_path"
[ "${listing[3]}" = PGDMP ] || fail "the latest snapshot of $namespace holds no custom-format dump"
echo "the Backup left one more snapshot in $namespace, $dump_path in custom format, and none for the staging claim"

# Cell 4: every restore test reads its dump by path, and passes.
for target in $BACKUP_NAMESPACES; do
  command="$(kubectl --namespace "$target" get cronjob restore-test \
    --output jsonpath='{.spec.jobTemplate.spec.template.spec.initContainers[0].command[2]}')"
  [[ $command == *'--path "/$(NAMESPACE)-postgres.dump"'* ]] || fail "the restore test of $target reads its dump without --path"
  restore_test_passes "$target" || fail "the restore test of $target failed"
  echo "the restore test of $target reads its dump by path and passes"
done
