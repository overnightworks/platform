#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=staging_cell.sh
source "$(dirname "${BASH_SOURCE[0]}")/staging_cell.sh"
# shellcheck source=../layer_includes.sh
source "$(dirname "${BASH_SOURCE[0]}")/../layer_includes.sh"
# The Backups of songmaker's bucket that each need a run of their own: what the copy holds whole, and what it refuses
# loudly instead of staging half of it. Prints names of cells, counts, digests and verdicts, never a key of the bucket, a
# secret or a row. It needs APP_MANIFEST (the web's manifest, which the client Pod that fills the bucket is furnished
# from), and the Kustomization of the layer and platform-secrets in flux-system, which it suspends while it changes what
# they apply.
export KUBECONFIG="$HOME/.kube/config"
namespace="$SONGMAKER_NAMESPACE"
export APP_NAMESPACE="$namespace"
# shellcheck source=../objectstore/client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../objectstore/client_pod.sh"
staging=/data/backup-staging
files_component=infrastructure/postgres/backup/files
bucket_component="$files_component/bucket"
bucket_patch="$(yq '.patches[] | select(.target.kind == "PreBackupPod") | .patch' "$bucket_component/kustomization.yaml")"
bucket_secret="$(yq '.[] | select(.op == "add" and .path == "/spec/pod/spec/volumes/-") | .value.secret.secretName' <<<"$bucket_patch")"
layer_includes "apps/$namespace/kustomization.yaml" components "$bucket_component" || fail "apps/$namespace does not include $bucket_component"
expected_top="$(declared_top "apps/$namespace/kustomization.yaml")"
mask_secret() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::$1"; }

original_backup_data="$(kubectl --namespace "$namespace" get secret "$bucket_secret" --output json | jq --raw-output '.data.credentials')"
original_backup_key="$(secret_value "$bucket_secret" credentials)"
mask_secret "$(ini_value "$original_backup_key" aws_secret_access_key)"
saved_prebackup="$(mktemp)"
platform_secrets_suspended=0 layer_suspended=0

# restore: the Secret as it was, the PreBackupPod as the layer declares it, and the Kustomizations running again.
restore() {
  local failed=0
  if [ "$platform_secrets_suspended" = 1 ]; then
    kubectl --namespace "$namespace" patch secret "$bucket_secret" --type merge \
      --patch "{\"data\": {\"credentials\": \"$original_backup_data\"}}" >/dev/null || failed=1
    flux resume kustomization platform-secrets --namespace flux-system || failed=1
    platform_secrets_suspended=0
  fi
  if [ "$layer_suspended" = 1 ]; then
    flux resume kustomization "$namespace" --namespace flux-system || failed=1
    layer_suspended=0
  fi
  return "$failed"
}
cleanup() {
  local cell_status=$?
  restore || cell_status=1
  delete_backups
  (run_client clear-planted-objects "$credentials_secret" clear "$bucket_variable") ||
    { delete_object --namespace "$namespace" delete pod clear-planted-objects --ignore-not-found --wait --timeout=2m; deletion_failures=$((deletion_failures + 1)); }
  delete_object --namespace "$namespace" delete pod --selector cell=object-store --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$namespace" delete configmap object-store-client --ignore-not-found
  rm -f -- "$saved_prebackup"
  delete_restic_objects
  end_deletions "$cell_status"
}
trap cleanup EXIT
install_client

# plant <set>: the bucket holds the objects of that set and no other; sets planted_count.
plant() {
  run_client plant-clear "$credentials_secret" clear "$bucket_variable"
  client_output plant-set plant "$bucket_variable" "$1"
  planted_count="$(sed -n 's/^ok: planted the set .*: \([0-9]*\) objects$/\1/p' <<<"$client_log")"
}

# snapshot_facts <name>: the newest staging snapshot's top level, its bucket's file count and the bucket lines of its
# MANIFEST, as "top ...", "bucket-files <n>" and "manifest-bucket <n>".
snapshot_facts() {
  run_restic "$namespace" "$1" '
    set -e
    tab="$(printf "\t")"
    staging='"$staging"'
    echo "top $(restic --no-cache ls --json --path "$staging" latest "$staging" | jq --raw-output "select(.type != null) | .path" |
      sed "s|^$staging/||" | grep -v / | LC_ALL=C sort | tr "\n" " ")"
    echo "bucket-files $(restic --no-cache ls --json --recursive --path "$staging" latest "$staging" |
      jq --raw-output "select(.type == \"file\") | .path" | grep -c "^$staging/bucket/" || true)"
    echo "manifest-bucket $(restic --no-cache dump --path "$staging" latest "$staging/MANIFEST" | grep -c "^file$tab[0-9]*$tab[0-9]*${tab}bucket/" || true)"
    '"$snapshot_bucket_digests"
  [ "$restic_exit" = 0 ] || fail "the staging snapshot of $namespace cannot be read after the Backup $1 (exit $restic_exit)"
}

# refused <name> <set> <refusal> <description>: the Backup stops at the stager's refusal and leaves no MANIFEST and no ready.
refused() {
  plant "$2"
  refused_backup "$1" "$3"
  ! staged_file_exists /staging/MANIFEST || fail "$4: the staging claim holds a MANIFEST"
  ! staged_file_exists /scratch/ready || fail "$4: the stager wrote ready"
  end_backup "$1"
  echo "$4: the Backup failed with the stager's refusal and left no MANIFEST and no Ready pod"
}
step_failure='^stage: bucket-pre-sync failed with exit [0-9]+$'

# Row 2: an empty bucket stages an empty bucket/ and no MANIFEST line.
run_client clear-first "$credentials_secret" clear "$bucket_variable"
run_backup bucket-row-2
snapshot_facts bucket-row-2-facts
[ "$(value top)" = "$expected_top" ] || fail "the snapshot of an empty bucket holds '$(value top)', not '$expected_top'"
[ "$(value bucket-files)" = 0 ] && [ "$(value manifest-bucket)" = 0 ] || fail "the snapshot of an empty bucket holds files or MANIFEST lines under bucket/"
grep -qx 'stage: bucket 0 objects 0 bytes' <<<"$run_logs" || fail "the stager did not report an empty bucket as 0 objects 0 bytes"
echo "an empty bucket gave a snapshot with an empty bucket/, no MANIFEST line and the line 0 objects 0 bytes"

# Row 6: a key beside the same name as a directory prefix is refused, naming the step.
refused bucket-row-6 clash "$step_failure" "a key next to a key under it"
# Row 7b: a key that ends in a slash and has bytes is refused, naming the step.
refused bucket-row-7b marker-with-bytes "$step_failure" "a key with bytes that ends in a slash"
# Row 8: a name with a newline is refused by the manifest.
refused bucket-row-8 newline '^stage: refused: a name under bucket/ holds a newline$' "a key with a newline"
# Row 9: a path segment of 256 bytes is refused, naming the step.
refused bucket-row-9 long-segment "$step_failure" "a key with a path segment over 255 bytes"

# Row 10: keys with a `..` segment, a leading slash and an empty segment next to one without: the Backup fails, or every
# key is staged under bucket/ on a path of its own, and never a file lands outside bucket/.
plant dots
planted_keys="$planted_count"
[ "$planted_keys" -gt 1 ] || fail "the set dots holds $planted_keys objects"
create_backup bucket-row-10
deadline=$((SECONDS + 300))
until refused_pod="$(backup_pod)"; [ -n "$refused_pod" ] && grep -Eq "$step_failure|^stage: ready$" \
  <<<"$(kubectl --namespace "$namespace" logs "pod/$refused_pod" --container stager 2>/dev/null || true)"; do
  [ "$SECONDS" -lt "$deadline" ] || fail "the stager of the Backup bucket-row-10 neither failed nor turned ready within 5 minutes"
  sleep 1
done
dots_log="$(kubectl --namespace "$namespace" logs "pod/$refused_pod" --all-containers)"
run_logs+="$dots_log"$'\n'
if grep -qx 'stage: ready' <<<"$dots_log"; then
  until [ -n "$(kubectl --namespace "$namespace" get backup bucket-row-10 --output jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "the Backup bucket-row-10 did not complete within 5 minutes"
    sleep 2
  done
  [ "$(kubectl --namespace "$namespace" get backup bucket-row-10 --output jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')" = Succeeded ] ||
    fail "the Backup bucket-row-10 ended without Succeeded after the stager turned ready"
  snapshot_facts bucket-row-10-facts
  [ "$(value top)" = "$expected_top" ] || fail "the snapshot of the keys with dots holds '$(value top)', not '$expected_top'"
  [ "$(value bucket-files)" = "$planted_keys" ] && [ "$(value manifest-bucket)" = "$planted_keys" ] ||
    fail "the snapshot holds $(value bucket-files) files under bucket/ for $planted_keys keys, so two keys share a path or one is missing"
  echo "the $planted_keys keys with dots, an empty segment and a leading slash are staged on paths of their own under bucket/, and nothing outside it"
else
  ! staged_file_exists /staging/MANIFEST || fail "the keys with dots: the staging claim holds a MANIFEST after the failed step"
  end_backup bucket-row-10
  echo "the keys with dots, an empty segment and a leading slash failed the step, which named itself, and left no MANIFEST"
fi

# Row 14: a wrong key fails the step, naming it, and no log holds the key.
wrong_id="GK$(openssl rand -hex 12)"
wrong_secret="$(openssl rand -hex 32)"
mask_secret "$wrong_secret"
plant base
flux suspend kustomization platform-secrets --namespace flux-system
platform_secrets_suspended=1
kubectl --namespace "$namespace" patch secret "$bucket_secret" --type merge \
  --patch "{\"data\": {\"credentials\": \"$(printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$wrong_id" "$wrong_secret" | base64 --wrap=0)\"}}"
refused_backup bucket-row-14 "$step_failure"
! staged_file_exists /staging/MANIFEST || fail "a wrong key: the staging claim holds a MANIFEST"
end_backup bucket-row-14
restore
echo "a wrong key failed the step bucket-pre-sync, naming it and its exit, and left no MANIFEST; the Secret $bucket_secret and platform-secrets are as they were"

# Row 7a: a zero-byte key that ends in a slash is a directory marker, not staged; the key under it is.
plant marker
client_output digests-marker digests "$bucket_variable"
run_backup bucket-row-7a
snapshot_facts bucket-row-7a-facts
[ "$(value bucket)" = "$(bucket_listing "$client_log")" ] || fail "bucket/ differs from the bucket's keys without the zero-byte key that ends in a slash"
[ "$(value top)" = "$expected_top" ] || fail "the snapshot beside a directory marker holds '$(value top)', not '$expected_top'"
echo "a zero-byte key that ends in a slash was left out and the key under it staged: bucket/ equals the bucket without it"

# Row 21: the same Backup with the Component's patch withdrawn from the PreBackupPod leaves no bucket/ in the snapshot or
# MANIFEST. The layer's Kustomization is suspended, so that Flux does not put the patch back; it resumes on every exit.
flux suspend kustomization "$namespace" --namespace flux-system
layer_suspended=1
kubectl --namespace "$namespace" get prebackuppod files --output json >"$saved_prebackup"
withdrawal="$(jq --compact-output '
  (.spec.pod.spec.containers | map(.name)) as $names |
  [{op: "remove", path: "/spec/pod/spec/containers/\($names | index("stager"))/env/\(.spec.pod.spec.containers[$names | index("stager")].env | map(.name) | index("STAGE_BUCKET"))"},
   {op: "remove", path: "/spec/pod/spec/containers/\($names | index("bucket"))"}]' "$saved_prebackup")"
kubectl --namespace "$namespace" patch prebackuppod files --type json --patch "$withdrawal" >/dev/null
run_backup bucket-row-21
snapshot_facts bucket-row-21-facts
without_bucket="${expected_top/bucket /}"
[ "$(value top)" = "$without_bucket" ] || fail "the snapshot without the bucket patch holds '$(value top)', not '$without_bucket'"
[ "$(value manifest-bucket)" = 0 ] || fail "the MANIFEST of the snapshot without the bucket patch lists bucket/ lines"
restore
[ "$(kubectl --namespace "$namespace" get prebackuppod files --output json | jq '[.spec.pod.spec.containers[].name] | index("bucket") != null')" = true ] ||
  fail "the layer's Kustomization did not put the container bucket back into the PreBackupPod"
echo "a Backup with the bucket patch withdrawn left no bucket/ and no bucket line in MANIFEST; the layer put the container back"

# No log of the PreBackupPod's containers or k8up's Jobs names a planted key or a credential.
job_logs="$(kubectl --namespace "$namespace" logs --selector k8upjob=true --all-pods --tail=-1)" || fail "cannot read k8up's Job logs in $namespace"
needles=(
  "planted key:refused-" "credential:$wrong_secret" "credential:$wrong_id"
  "credential:$(ini_value "$original_backup_key" aws_access_key_id)" "credential:$(ini_value "$original_backup_key" aws_secret_access_key)"
  "credential:$(ini_value "$(secret_value "$credentials_secret" "$credentials_key")" aws_secret_access_key)")
for needle in "${needles[@]}"; do
  [ -n "${needle#*:}" ] || fail "a ${needle%%:*} to look for is empty"
  if grep -qF -- "${needle#*:}" <<<"$run_logs$job_logs"; then fail "a log of $namespace's backup names a ${needle%%:*}"; fi
done
echo "no log of the PreBackupPod's containers or k8up's Jobs names one of ${#needles[@]} planted keys or credentials"
