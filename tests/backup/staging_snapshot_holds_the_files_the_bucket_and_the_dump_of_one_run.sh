#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=staging_cell.sh
source "$(dirname "${BASH_SOURCE[0]}")/staging_cell.sh"
# shellcheck source=../layer_includes.sh
source "$(dirname "${BASH_SOURCE[0]}")/../layer_includes.sh"
# songmaker's staging snapshot holds the copy of its declared claim, the copy of its bucket and the dump of one run; prints
# names, counts, digests and verdicts, never a file name, a file's content, a row or a secret. It needs APP_MANIFEST (the
# web's manifest, which the client Pod that fills the bucket is furnished from) and nothing from the other scripts under
# tests/backup/: its own Backups fill songmaker's repository. Each cell plants synthetic audio files at the reading uid into
# the declared claim and synthetic objects into the bucket, and reads them back through the snapshots.
export KUBECONFIG="$HOME/.kube/config"
namespace="$SONGMAKER_NAMESPACE"
export APP_NAMESPACE="$namespace"
# shellcheck source=../objectstore/client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../objectstore/client_pod.sh"
staging=/data/backup-staging
reading_uid="$(kubectl --namespace "$namespace" get deployment web --output jsonpath='{.spec.template.spec.securityContext.runAsUser}')"
declared_claim="$(kubectl --namespace "$namespace" get configmap postgres --output jsonpath='{.data.backup-claim}')"
[ -n "$reading_uid" ] || fail "the Deployment web of $namespace sets no runAsUser, the reading uid"
[ -n "$declared_claim" ] || fail "the ConfigMap postgres of $namespace declares no backup-claim"
# What the layer declares: the Components that put files/ and bucket/ into the snapshot, and the Secret the bucket Component
# mounts, which holds the backup's key.
layer_file="apps/$namespace/kustomization.yaml"
files_component=infrastructure/postgres/backup/files
bucket_component="$files_component/bucket"
bucket_patch="$(yq '.patches[] | select(.target.kind == "PreBackupPod") | .patch' "$bucket_component/kustomization.yaml")"
bucket_secret="$(yq '.[] | select(.op == "add" and .path == "/spec/pod/spec/volumes/-") | .value.secret.secretName' <<<"$bucket_patch")"
staging_claim="$(yq 'select(.kind == "PersistentVolumeClaim") | .metadata.name' "$files_component/files.yaml")"
# The top level of the snapshot: MANIFEST and the dump beside the directory each Component the layer lists adds.
expected_top="$(declared_top "$layer_file")"
# The synthetic audio, under one directory of the declared claim: a nested file, names with a space.
cell_directory="staging-cell"
first_file="$cell_directory/nested/deeper/first take.ogg"
changed_file="$cell_directory/second take.ogg"
deleted_file="$cell_directory/third take.ogg"
added_file="$cell_directory/nested/fourth take.ogg"
unreadable_file="$cell_directory/unreadable take.ogg"
newline_file="$cell_directory/line@NEWLINE@break.ogg"

holder="staging-holder"
cleanup() {
  local cell_status=$?
  delete_object --namespace "$namespace" delete pod "$holder" --ignore-not-found --wait --timeout=2m
  delete_backups
  # The planted audio and objects leave on every exit; their own Pods are deleted by run_files and run_client or here.
  (run_files remove-planted-audio "$declared_claim" false "rm -rf '/files/$cell_directory'") ||
    { delete_object --namespace "$namespace" delete pod remove-planted-audio --ignore-not-found --wait --timeout=2m; deletion_failures=$((deletion_failures + 1)); }
  (run_client clear-planted-objects "$credentials_secret" clear "$bucket_variable") ||
    { delete_object --namespace "$namespace" delete pod clear-planted-objects --ignore-not-found --wait --timeout=2m; deletion_failures=$((deletion_failures + 1)); }
  delete_object --namespace "$namespace" delete pod --selector cell=object-store --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$namespace" delete configmap object-store-client --ignore-not-found
  for name in prune-as-reading-uid check-as-reading-uid; do
    delete_object --namespace "$namespace" delete "${name%%-*}" "$name" --ignore-not-found --wait --timeout=2m
  done
  delete_restic_objects
  end_deletions "$cell_status"
}
trap cleanup EXIT

# run_files <name> <claim> <read-only> <shell script>: a busybox Pod at the reading uid with the claim at /files runs the
# script; sets files_output and files_exit. @NEWLINE@ in the script stands for a newline inside a file name.
run_files() {
  local name="$1" claim="$2" read_only="$3" script
  script='newline="$(printf "\nx")"; newline="${newline%x}"'$'\n'"${4//@NEWLINE@/\$\{newline\}}"
  NAME="$name" CLAIM="$claim" READ_ONLY="$read_only" SCRIPT="$script" IMAGE="$PROBE_IMAGE" USER_ID="$reading_uid" \
    yq --null-input --output-format json '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false, "enableServiceLinks": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": env(USER_ID), "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "files", "image": strenv(IMAGE), "command": ["sh", "-c", strenv(SCRIPT)],
         "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
         "volumeMounts": [{"name": "claim", "mountPath": "/files", "readOnly": env(READ_ONLY)}]}],
       "volumes": [{"name": "claim", "persistentVolumeClaim": {"claimName": strenv(CLAIM)}}]}}' |
    kubectl --namespace "$namespace" create --filename - >/dev/null
  restic_objects+=("$namespace pod $name")
  kubectl --namespace "$namespace" wait "pod/$name" --timeout=5m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' >/dev/null
  files_exit="$(kubectl --namespace "$namespace" get "pod/$name" \
    --output jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  files_output="$(kubectl --namespace "$namespace" logs "pod/$name")"
  kubectl --namespace "$namespace" delete pod "$name" --wait --timeout=2m >/dev/null
  [ "$files_exit" = 0 ] || fail "the Pod $name in $namespace ended with exit $files_exit"
}

# The digests a claim's files give, mounted at /files: "listing <sha256> <count>" of size, mtime and path per file as
# MANIFEST lists them, and "content <sha256>" of every file's bytes.
claim_digests='
  tab="$(printf "\t")"
  listing="$(cd / && find files -type f -exec stat -c "%s$tab%Y$tab%n" {} + | LC_ALL=C sort)"
  echo "listing $(printf "%s\n" "$listing" | sha256sum | cut -c1-64) $(printf "%s\n" "$listing" | grep -c .)"
  echo "content $(cd / && find files -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum | cut -c1-64)"'

# Planted: three files with fixed times, one nested, two names with a space.
run_files plant-audio "$declared_claim" false "
  set -e
  mkdir -p '/files/$cell_directory/nested/deeper'
  printf 'first' >'/files/$first_file'
  printf 'second' >'/files/$changed_file'
  printf 'third' >'/files/$deleted_file'
  touch -d '2026-01-02 03:04:05' '/files/$first_file' '/files/$changed_file' '/files/$deleted_file'
  $claim_digests"
claim_before="$files_output"
echo "planted 3 files in $declared_claim of $namespace at uid $reading_uid: $(grep '^listing' <<<"$claim_before" | cut -d' ' -f3) files in the claim"

install_client
run_client plant-clear "$credentials_secret" clear "$bucket_variable"
run_client plant-base "$credentials_secret" plant "$bucket_variable" base
client_output digests-first digests "$bucket_variable"
bucket_before="$client_log"
echo "planted the bucket $bucket of $namespace through a client Pod furnished as its web: $(bucket_listing "$bucket_before" | cut -d' ' -f2) objects"

# Cell 3: one Backup leaves a dump snapshot and a staging snapshot of the same dump; files/ equals the declared claim.
annotated="$(kubectl get pvc --all-namespaces --output json | jq --raw-output \
  '[.items[] | select(.metadata.annotations["k8up.io/backup"] == "true") | .metadata.namespace + "/" + .metadata.name] | join(" ")')"
[ "$annotated" = "$namespace/backup-staging" ] || fail "the claims annotated for k8up are '$annotated', not $namespace/backup-staging alone"
run_backup staging-first
first_pod="$staged_pod"
run_restic "$namespace" staging-first-listing '
  set -e
  tab="$(printf "\t")"
  staging='"$staging"'
  manifest="$(restic --no-cache dump --path "$staging" latest "$staging/MANIFEST")"
  files="$(printf "%s\n" "$manifest" | grep "^file$tab[0-9]*$tab[0-9]*${tab}files/" | cut -f2- | LC_ALL=C sort)"
  echo "listing $(printf "%s\n" "$files" | sha256sum | cut -c1-64) $(printf "%s\n" "$files" | grep -c .)"
  manifest_bucket="$(printf "%s\n" "$manifest" | grep "^file$tab[0-9]*$tab[0-9]*${tab}bucket/" | cut -f2,4 | LC_ALL=C sort)"
  echo "manifest-bucket $(printf "%s\n" "$manifest_bucket" | sha256sum | cut -c1-64) $(printf "%s\n" "$manifest_bucket" | grep -c .)"
  '"$snapshot_bucket_digests"'
  echo "manifest-dump $(printf "%s\n" "$manifest" | grep "^dump$tab" | cut -f2)"
  echo "staged-dump $(restic --no-cache dump --path "$staging" latest "$staging/postgres.dump" | sha256sum | cut -c1-64)"
  echo "streamed-dump $(restic --no-cache dump --path "/$NAMESPACE-postgres.dump" latest "/$NAMESPACE-postgres.dump" | sha256sum | cut -c1-64)"
  # An early exit of head kills restic by SIGPIPE while it holds its read lock; draining ends it.
  echo "streamed-head $(restic --no-cache dump --path "/$NAMESPACE-postgres.dump" latest "/$NAMESPACE-postgres.dump" | { head -c 5; cat >/dev/null; })"
  echo "top $(restic --no-cache ls --json --path "$staging" latest "$staging" | jq --raw-output "select(.type != null) | .path" |
    sed "s|^$staging/||" | grep -v / | LC_ALL=C sort | tr "\n" " ")"
  snapshot_names="$(restic --no-cache ls --json --recursive --path "$staging" latest "$staging/files" |
    jq --raw-output "select(.type == \"file\") | .path" | sed "s|^$staging/||" | LC_ALL=C sort)"
  manifest_names="$(printf "%s\n" "$files" | cut -f3- | LC_ALL=C sort)"
  if [ "$snapshot_names" = "$manifest_names" ]; then echo "names equal"; else echo "names differ"; fi'
[ "$restic_exit" = 0 ] || fail "the snapshots of the Backup staging-first cannot be read (exit $restic_exit)"
[ "$(value top)" = "$expected_top" ] || fail "the staging snapshot of $namespace holds '$(value top)', not '$expected_top'"
[ "$(value streamed-head)" = PGDMP ] || fail "the dump snapshot of $namespace holds no custom-format dump"
manifest_dump="$(value manifest-dump)"
[ "${#manifest_dump}" = 64 ] || fail "the MANIFEST of $namespace's staging snapshot names no dump sha256"
[ "$(value staged-dump)" = "$manifest_dump" ] || fail "the staging snapshot's postgres.dump differs from its MANIFEST's sha256"
[ "$(value streamed-dump)" = "$manifest_dump" ] || fail "the streamed dump snapshot differs from the staging MANIFEST's sha256"
[ "$(value listing)" = "$(sed -n 's/^listing //p' <<<"$claim_before")" ] ||
  fail "the staging MANIFEST lists $(value listing | cut -d' ' -f2) files that differ by name, size or mtime from the claim's $(grep '^listing' <<<"$claim_before" | cut -d' ' -f3)"
[ "$(value names)" = equal ] || fail "the staging snapshot's files/ differ by name from its MANIFEST"
[ "$(value bucket)" = "$(bucket_listing "$bucket_before")" ] ||
  fail "the staging snapshot's bucket/ differs by key, size or bytes from the bucket's $(bucket_listing "$bucket_before" | cut -d' ' -f2) objects"
[ "$(value manifest-bucket)" = "$(bucket_listing "$(bucket_manifest_lines "$bucket_before")")" ] ||
  fail "the staging MANIFEST lists the bucket's objects by other names or sizes than the bucket holds"
echo "one Backup left /$namespace-postgres.dump and $staging with $expected_top; both dumps equal the MANIFEST's sha256"
echo "bucket/ equals the bucket $bucket by key, size and bytes: $(value bucket | cut -d' ' -f2) objects, listed in MANIFEST"
echo "files/ equals $declared_claim by name, size and mtime: $(value listing | cut -d' ' -f2) files"
# The timed lines of the bucket's pre-sync and the count line, which name no object: the gate before landing reads the sync's
# throughput from them.
timed_lines="$(grep -E '^stage: (bucket-pre-sync (started|done) at |bucket [0-9]+ objects [0-9]+ bytes$)' <<<"$run_logs" || true)"
[ "$(wc -l <<<"$timed_lines")" = 3 ] || fail "the first Backup's log does not hold the bucket pre-sync's start and end lines and one count line"
echo "$timed_lines"
run_files staged-dump-owner "backup-staging" true "stat -c 'dump %u:%g %a' /files/postgres.dump"
[ "$(sed -n 's/^dump //p' <<<"$files_output")" = "70:70 640" ] ||
  fail "the staged dump of $namespace is owned and moded $(sed -n 's/^dump //p' <<<"$files_output"), not 70:70 640"
echo "the staged dump is owned by 70:70 at mode 640"
run_files claim-after-first "$declared_claim" true "$claim_digests"
[ "$files_output" = "$claim_before" ] || fail "the Backup changed the files of $declared_claim"
source_mounts="$(jq --raw-output --arg claim "$declared_claim" '
  [.spec.volumes[] | select(.persistentVolumeClaim.claimName? == $claim) | .name] as $volumes |
  [(.spec.containers[], .spec.initContainers[]?) | . as $container |
   [.volumeMounts[]? | select(.name | IN($volumes[]))] | select(length > 0) |
   $container.name + ":" + (map(.readOnly // false) | all | tostring)] | join(" ")' <<<"$first_pod")"
[ "$source_mounts" = "copy:true" ] || fail "the PreBackupPod's containers mount $declared_claim as '$source_mounts', not copy alone read-only"
echo "only copy mounts $declared_claim, read-only, and the claim's files are unchanged after the Backup"

# Cell 4: the restore test reads its dump by path while the newest snapshot is the staging one. Which of a run's two
# snapshots k8up writes last is not fixed, so the cell makes the staging snapshot the newest by rewriting its time. Only
# songmaker's repository can hold that state: the other namespaces' repositories hold the snapshots of their own runs,
# whose restore tests the dump script runs.
run_restic "$namespace" staging-newest '
  set -e
  staging='"$staging"'
  newest="$(restic --no-cache snapshots --json | jq --raw-output "max_by(.time) | .paths | join(\" \")")"
  if [ "$newest" != "$staging" ]; then
    staged="$(restic --no-cache snapshots --json --path "$staging" | jq --raw-output "max_by(.time) | .id")"
    restic --no-cache rewrite --forget --new-time "$(date -u -d "@$(($(date +%s) + 2))" "+%Y-%m-%d %H:%M:%S")" "$staged" >/dev/null
    echo arranged
  fi
  echo "newest $(restic --no-cache snapshots --json | jq --raw-output "max_by(.time) | .paths | join(\" \")")"'
[ "$restic_exit" = 0 ] || fail "the snapshots of $namespace cannot be ordered (exit $restic_exit)"
[ "$(sed -n 's/^newest //p' <<<"$restic_output")" = "$staging" ] || fail "the newest snapshot of $namespace is not the staging one"
echo "the newest snapshot of $namespace is the staging one$(grep -q '^arranged$' <<<"$restic_output" && echo ', by a rewritten time' || true)"
run_restore_test "$namespace" staging-newest-restore-test
[ "$status" = passed ] || fail "the restore test of $namespace failed while its newest snapshot is the staging one"
echo "the restore test of $namespace passes"

# Cell 6: a second Backup reads only the changed files, from its parent, and --delete drops the deleted file.
run_files change-audio "$declared_claim" false "
  set -e
  printf ' again' >>'/files/$changed_file'
  touch -d '2026-02-03 04:05:06' '/files/$changed_file'
  printf 'fourth' >'/files/$added_file'
  rm '/files/$deleted_file'
  $claim_digests"
claim_second="$files_output"
claim_count="$(grep '^listing' <<<"$claim_second" | cut -d' ' -f3)"
# The bucket changes between the runs: one object rewritten to the same size, one deleted, one added.
run_client change-bucket "$credentials_secret" plant "$bucket_variable" change
client_output digests-second digests "$bucket_variable"
bucket_after="$client_log"
bucket_keys() { printf '%s\n' "$1" | cut -f3 | grep . | LC_ALL=C sort; }
deleted_key="$(comm -23 <(bucket_keys "$bucket_before") <(bucket_keys "$bucket_after"))"
added_key="$(comm -13 <(bucket_keys "$bucket_before") <(bucket_keys "$bucket_after"))"
changed_count="$(comm -13 <(printf '%s\n' "$bucket_before" | LC_ALL=C sort) <(printf '%s\n' "$bucket_after" | LC_ALL=C sort) | cut -f3 |
  grep -vxF -f <(printf '%s\n' "$added_key") | grep -c . || true)"
bucket_count="$(bucket_listing "$bucket_after" | cut -d' ' -f2)"
[ "$(grep -c . <<<"$deleted_key")" = 1 ] && [ "$(grep -c . <<<"$added_key")" = 1 ] && [ "$changed_count" = 1 ] ||
  fail "the planted change is not one deleted, one added and one rewritten object"
[[ $deleted_key != *"'"* && $added_key != *"'"* ]] || fail "a changed key holds a quote, which the snapshot reader cannot take"
run_backup staging-second
run_restic "$namespace" staging-second-listing '
  set -e
  staging='"$staging"'
  snapshots="$(restic --no-cache snapshots --json --path "$staging" | jq "sort_by(.time)")"
  previous="$(printf "%s" "$snapshots" | jq --raw-output ".[-2].id")"
  latest="$(printf "%s" "$snapshots" | jq --raw-output ".[-1].id")"
  echo "parent $(printf "%s" "$snapshots" | jq --raw-output "if .[-1].parent == .[-2].id then \"equal\" else \"differs\" end")"
  echo "summary $(printf "%s" "$snapshots" | jq --raw-output ".[-1].summary | \"\(.files_new) \(.files_changed) \(.files_unmodified)\"")"
  deleted="$staging/files/'"$deleted_file"'"
  deleted_object="$staging/bucket/'"$deleted_key"'"
  added_object="$staging/bucket/'"$added_key"'"
  for snapshot in "$previous" "$latest"; do
    echo "deleted $(restic --no-cache ls --json --recursive "$snapshot" "$staging/files" | jq --raw-output "select(.type == \"file\") | .path" |
      grep -Fxc "$deleted" || true)"
    echo "deleted-object $(restic --no-cache ls --json --recursive "$snapshot" "$staging/bucket" | jq --raw-output "select(.type == \"file\") | .path" |
      grep -Fxc "$deleted_object" || true)"
    echo "added-object $(restic --no-cache ls --json --recursive "$snapshot" "$staging/bucket" | jq --raw-output "select(.type == \"file\") | .path" |
      grep -Fxc "$added_object" || true)"
  done
  tab="$(printf "\t")"
  '"$snapshot_bucket_digests"''
[ "$restic_exit" = 0 ] || fail "the snapshots of the Backup staging-second cannot be read (exit $restic_exit)"
[ "$(value parent)" = equal ] || fail "the second staging snapshot of $namespace was not made from the first as its parent"
# Among the audio files and the objects one of each is new and one changed; the run's own postgres.dump and MANIFEST are
# rewritten every run.
expected_summary="2 4 $((claim_count - 2 + bucket_count - 2))"
[ "$(value summary)" = "$expected_summary" ] ||
  fail "the second staging snapshot counts new, changed and unmodified files as $(value summary), not $expected_summary"
[ "$(sed -n 's/^deleted //p' <<<"$restic_output" | tr '\n' ' ')" = "1 0 " ] ||
  fail "the deleted file is not in the first staging snapshot alone"
[ "$(sed -n 's/^deleted-object //p' <<<"$restic_output" | tr '\n' ' ')" = "1 0 " ] ||
  fail "the deleted object is not in the first staging snapshot alone"
[ "$(sed -n 's/^added-object //p' <<<"$restic_output" | tr '\n' ' ')" = "0 1 " ] ||
  fail "the added object is not in the second staging snapshot alone"
[ "$(value bucket)" = "$(bucket_listing "$bucket_after")" ] ||
  fail "the second staging snapshot's bucket/ differs by key, size or bytes from the bucket's $bucket_count objects"
echo "the second Backup read from its parent: 2 new, 4 changed and $((claim_count - 2 + bucket_count - 2)) unmodified files; the deleted file and object are in the first snapshot alone, the added object in the second, and bucket/ equals the bucket again, the rewritten object's new bytes included"

# Cell 8: the stager refuses to stage while another pod mounts the staging claim; the tree and MANIFEST stay.
staging_digests='cd /staging && echo "tree $(find . -exec stat -c "%n %s %Y" {} + | LC_ALL=C sort | sha256sum | cut -c1-64)" &&
  echo "manifest $(sha256sum <MANIFEST | cut -c1-64)"'
NAME="$holder" IMAGE="$PROBE_IMAGE" USER_ID="$reading_uid" yq --null-input --output-format json '
  {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
   "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false, "enableServiceLinks": false,
     "securityContext": {"runAsNonRoot": true, "runAsUser": env(USER_ID), "seccompProfile": {"type": "RuntimeDefault"}},
     "containers": [{"name": "holder", "image": strenv(IMAGE), "command": ["sleep", "3600"],
       "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
       "volumeMounts": [{"name": "staging", "mountPath": "/staging", "readOnly": true}]}],
     "volumes": [{"name": "staging", "persistentVolumeClaim": {"claimName": "backup-staging", "readOnly": true}}]}}' |
  kubectl --namespace "$namespace" create --filename - >/dev/null
kubectl --namespace "$namespace" wait "pod/$holder" --for=condition=Ready --timeout=5m >/dev/null
held_before="$(kubectl --namespace "$namespace" exec "$holder" -- sh -c "$staging_digests")"
refused_backup staging-held '^stage: refused: [0-9]+ other pods mount the staging claim$'
held_after="$(kubectl --namespace "$namespace" exec "$holder" -- sh -c "$staging_digests")"
[ "$held_after" = "$held_before" ] || fail "the refused stager changed the staging tree or its MANIFEST"
end_backup staging-held
kubectl --namespace "$namespace" delete pod "$holder" --wait --timeout=2m >/dev/null
run_backup staging-after-holder
echo "the stager refused while another pod mounted the staging claim, the tree and MANIFEST stayed, and a Backup after the holder succeeded"

# Cell 7: a file the reading uid cannot read, and a name with a newline, leave no MANIFEST and no Ready pod.
run_files plant-unreadable "$declared_claim" false "set -e; printf 'unreadable' >'/files/$unreadable_file'; chmod 000 '/files/$unreadable_file'"
refused_backup staging-unreadable '^stage: pre-sync failed with exit 23$'
! staged_file_exists /staging/MANIFEST || fail "the staging claim holds a MANIFEST after an unreadable file"
! staged_file_exists /scratch/ready || fail "the stager wrote ready after an unreadable file"
end_backup staging-unreadable
run_files restore-unreadable "$declared_claim" false "chmod 600 '/files/$unreadable_file'"
echo "an unreadable file failed the pre-sync with rsync's exit 23 and left no MANIFEST and no Ready pod; its mode is restored"
run_files plant-newline "$declared_claim" false "printf 'newline' >\"/files/$newline_file\""
refused_backup staging-newline '^stage: refused: a name under files/ holds a newline$'
! staged_file_exists /staging/MANIFEST || fail "the staging claim holds a MANIFEST after a name with a newline"
! staged_file_exists /scratch/ready || fail "the stager wrote ready after a name with a newline"
end_backup staging-newline
run_files remove-newline "$declared_claim" false "rm \"/files/$newline_file\""
echo "a name with a newline made the manifest refuse and left no MANIFEST and no Ready pod; the file is removed"

# Cell 9: k8up's Job pods in songmaker run as the reading uid, and a Prune and a Check succeed.
# k8up_object_succeeds <Prune|Check> <name>: one, as the Schedule would start it, which must succeed.
k8up_object_succeeds() {
  local kind="$1" name="$2" deadline=$((SECONDS + 600)) reason
  kubectl --namespace "$namespace" get schedule postgres --output json |
    jq --arg kind "$kind" --arg name "$name" \
      '{ apiVersion: "k8up.io/v1", kind: $kind, metadata: { name: $name },
         spec: ({ backend: .spec.backend, podConfigRef: .spec.podConfigRef } +
                (if $kind == "Prune" then { retention: .spec.prune.retention } else {} end)) }' |
    kubectl --namespace "$namespace" create --filename - >/dev/null
  while :; do
    reason="$(kubectl --namespace "$namespace" get "$kind" "$name" \
      --output jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')"
    [ -z "$reason" ] || break
    [ "$SECONDS" -lt "$deadline" ] || fail "the $kind $name of $namespace did not complete within 10 minutes"
    sleep 5
  done
  [ "$reason" = Succeeded ] || fail "the $kind $name of $namespace ended with reason $reason"
}
k8up_object_succeeds Prune prune-as-reading-uid
k8up_object_succeeds Check check-as-reading-uid
job_users="$(kubectl --namespace "$namespace" get jobs --output json | jq --raw-output '
  [.items[] | (.metadata.ownerReferences // [])[] as $owner | select($owner.apiVersion == "k8up.io/v1") |
   $owner.kind + ":" + (.spec.template.spec.securityContext.runAsUser // "unset" | tostring)] | unique | join(" ")')"
for kind in Backup Prune Check; do
  [[ " $job_users " == *" $kind:"* ]] || fail "no Job of a k8up $kind is left in $namespace to read its user from"
done
for entry in $job_users; do
  [ "${entry#*:}" = "$reading_uid" ] || fail "a Job of a k8up ${entry%%:*} in $namespace runs as ${entry#*:}, not the reading uid $reading_uid"
done
echo "k8up's Jobs in $namespace run as uid $reading_uid: $job_users; a Prune and a Check succeeded"

# Cell 10: only the stager holds a token, and its account may list and watch pods and nothing else.
token_holders="$(jq --raw-output '
  [.spec.volumes[] | select(any(.projected.sources[]?; has("serviceAccountToken"))) | .name] as $tokens |
  [(.spec.containers[], .spec.initContainers[]?) | select(any(.volumeMounts[]?; .name | IN($tokens[]))) | .name] |
  join(" ")' <<<"$first_pod")"
[ "$(jq '.spec.automountServiceAccountToken' <<<"$first_pod")" = false ] ||
  fail "the PreBackupPod's pod mounts the account's token in every container"
[ "$token_holders" = stager ] || fail "the containers '$token_holders' hold a token, not stager alone"
account="system:serviceaccount:$namespace:$(jq --raw-output '.spec.serviceAccountName' <<<"$first_pod")"
for question in "list pods yes" "watch pods yes" "get pods no" "create pods no" "delete pods no" "create pods/exec no" \
  "get secrets no" "list secrets no" "list deployments.apps no" "list persistentvolumeclaims no"; do
  read -r verb resource expected <<<"$question"
  answer="$(kubectl auth can-i "$verb" "$resource" --namespace "$namespace" --as "$account" 2>/dev/null || true)"
  [ "$answer" = "$expected" ] || fail "the stager's account answers '$answer' to $verb $resource, not $expected"
done
echo "only stager holds a token, and its account may list and watch pods and nothing else"
bucket_mounts="$(jq --raw-output '
  . as $pod | [.spec.containers[] | select(.name == "bucket") | .volumeMounts[].name] as $names |
  [$pod.spec.volumes[] | select(.name | IN($names[])) |
   if .persistentVolumeClaim then "claim:" + .persistentVolumeClaim.claimName elif .secret then "secret:" + .secret.secretName
   else empty end] | sort | join(" ")' <<<"$first_pod")"
[ "$bucket_mounts" = "claim:$staging_claim secret:$bucket_secret" ] ||
  fail "the bucket container mounts the claims and Secrets '$bucket_mounts', not the staging claim and the Secret $bucket_secret alone"
echo "the bucket container mounts the staging claim and the Secret $bucket_secret and no other claim or Secret, and holds no token"

# Cell 11: no log names a planted file, a row or a credential. The logs are the PreBackupPod's containers', read above,
# and those of k8up's Jobs; each needle is named by its kind, never by its value.
job_logs="$(kubectl --namespace "$namespace" logs --selector k8upjob=true --all-pods --tail=-1)" || fail "cannot read k8up's Job logs in $namespace"
[ -n "$job_logs" ] || fail "k8up's Job logs in $namespace are empty"
[ -n "$run_logs" ] || fail "no log of the PreBackupPod's pods was read"
row="$(kubectl --namespace "$namespace" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only --no-align \
  --command='SELECT version_num FROM alembic_version')"
[ -n "$row" ] || fail "the table alembic_version of $namespace holds no row to look for"
needles=(
  "planted file:$cell_directory" "planted file:first take" "planted file:second take" "planted file:third take"
  "planted file:fourth take" "planted file:unreadable take" "planted file:break.ogg" "row:$row"
  "credential:$(secret_value postgres password)" "credential:$(secret_value restic password)"
  "credential:$(secret_value restic repository-password)"
  "credential:$(ini_value "$(secret_value "$credentials_secret" "$credentials_key")" aws_secret_access_key)"
  "credential:$(ini_value "$(secret_value "$bucket_secret" credentials)" aws_access_key_id)"
  "credential:$(ini_value "$(secret_value "$bucket_secret" credentials)" aws_secret_access_key)"
)
while IFS= read -r key; do needles+=("planted object:$key"); done < <(cut -f3 <<<"$bucket_before"; printf '%s\n' "$added_key")
for needle in "${needles[@]}"; do
  [ -n "${needle#*:}" ] || fail "a ${needle%%:*} to look for is empty"
  if grep -qF -- "${needle#*:}" <<<"$run_logs$job_logs"; then fail "a log of $namespace's backup names a ${needle%%:*}"; fi
done
echo "no log of the PreBackupPod's containers or k8up's Jobs names one of ${#needles[@]} planted names, rows or credentials"
