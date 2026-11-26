#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=staging_cell.sh
source "$(dirname "${BASH_SOURCE[0]}")/staging_cell.sh"
# Every Backup and seed of songmaker's staging claim measures its copies and refuses before any sync one that would leave the
# node less free than the kubelet's eviction margin. The stager's `stage: fit:` line holds the margin, the volume's size and
# the bucket's counts, each of which this reads from the node object and the bucket's own client; with the node's allocatable
# patched to 1 byte, so that the margin spans the whole disk, a Backup refuses before any sync and leaves the staged bucket/
# as it was, with no MANIFEST and no ready, and backup:now refuses with its room sentence and makes no Backup. It prints
# names, counts and sentences, never a key of the bucket or a secret. It needs APP_MANIFEST (the web's manifest, which the
# client Pod that fills the bucket is furnished from) and the Kustomization of the layer in flux-system, which it suspends
# while it patches the PreBackupPod.
export KUBECONFIG="$HOME/.kube/config"
namespace="$SONGMAKER_NAMESPACE"
export APP_NAMESPACE="$namespace"
# shellcheck source=../objectstore/client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../objectstore/client_pod.sh"
node="$(kubectl --namespace "$namespace" get pods --output jsonpath='{.items[0].spec.nodeName}')"
work="$(mktemp -d)"

cleanup() {
  local cell_status=$?
  restore_pre_backup_pod || cell_status=1
  delete_backups
  (run_client clear-planted-objects "$credentials_secret" clear "$bucket_variable") ||
    { delete_object --namespace "$namespace" delete pod clear-planted-objects --ignore-not-found --wait --timeout=2m; deletion_failures=$((deletion_failures + 1)); }
  delete_object --namespace "$namespace" delete pod --selector cell=object-store --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$namespace" delete configmap object-store-client --ignore-not-found
  rm -rf -- "$work"
  delete_restic_objects
  end_deletions "$cell_status"
}
trap cleanup EXIT
install_client
run_client fit-clear "$credentials_secret" clear "$bucket_variable"
run_client fit-base "$credentials_secret" plant "$bucket_variable" base
client_output fit-digests digests "$bucket_variable"
bucket_before="$client_log"
bucket_objects="$(bucket_listing "$bucket_before" | cut -d' ' -f2)"
bucket_bytes="$(awk -F'\t' '{ bytes += $1 } END { printf "%.0f", bytes }' <<<"$bucket_before")"

# The layer's own spec: the Backup passes, and its fit line agrees with the node and the bucket.
run_backup fit-passes
fit_line="$(grep -m1 '^stage: fit: ' <<<"$run_logs")" || fail "the stager of the Backup fit-passes printed no fit line"
capacity="$(kubectl get node "$node" --output jsonpath='{.status.capacity.ephemeral-storage}')"
allocatable="$(kubectl get node "$node" --output jsonpath='{.status.allocatable.ephemeral-storage}')"
[[ $fit_line =~ ^stage:\ fit:\ claim\ [0-9]+\ files\ [0-9]+\ directories\ [0-9]+\ bytes\;\ bucket\ ([0-9]+)\ objects\ [0-9]+\ prefixes\ ([0-9]+)\ bytes\;\ need\ [0-9]+\;\ free\ [0-9]+\ of\ ([0-9]+)\;\ margin\ ([0-9]+)$ ]] ||
  fail "the fit line has an unexpected form: '$fit_line'"
[ "${BASH_REMATCH[4]}" = "$((capacity - allocatable))" ] ||
  fail "the fit's margin ${BASH_REMATCH[4]} is not the node's capacity $capacity minus its allocatable $allocatable"
[ "${BASH_REMATCH[3]}" = "$capacity" ] || fail "the staging volume's size ${BASH_REMATCH[3]} is not the node's capacity $capacity"
[ "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" = "$bucket_objects $bucket_bytes" ] ||
  fail "the fit counts '${BASH_REMATCH[1]} ${BASH_REMATCH[2]}' objects and bytes, the bucket '$bucket_objects $bucket_bytes'"
echo "the fit's margin is the node's capacity minus its allocatable, its volume the node's capacity, its bucket $bucket_objects objects and $bucket_bytes bytes as the client counts"

# The node's allocatable patched to 1 byte: the margin spans the whole disk, so every copy is refused before any sync.
suspend_layer
set_env stager NODE_ALLOCATABLE_STORAGE 1
run_client fit-change "$credentials_secret" plant "$bucket_variable" change
refused_backup fit-refused '^stage: refused: the copies need [0-9]+ bytes beside the kubelet.s eviction margin of [0-9]+, and the staging volume has [0-9]+ of [0-9]+ bytes free; free disk space first'
! staged_file_exists /staging/MANIFEST || fail "the refused Backup left a MANIFEST"
! staged_file_exists /scratch/ready || fail "the refused stager wrote ready"
staged_keys="$(kubectl --namespace "$namespace" exec "$refused_pod" --container stager -- sh -c 'cd /staging/bucket && find . -type f | sed "s|^[.]/||" | LC_ALL=C sort')"
[ "$staged_keys" = "$(cut -f3 <<<"$bucket_before" | LC_ALL=C sort)" ] || fail "the staged bucket/ is not the set it held before the refused Backup"
end_backup fit-refused
echo "a Backup refused before any sync, left no MANIFEST and no ready, and the staged bucket/ holds the same files as before and no planted object"
backup_names() { kubectl --namespace "$namespace" get backups.k8up.io --output name | sort; }
backups_before="$(backup_names)"
status=0
scripts/backup_now.sh "$namespace" >"$work/now" 2>&1 || status=$?
[ "$status" = 1 ] && grep -q "the seed of $namespace refused: the copies need [0-9]* bytes beside the kubelet's eviction margin of [0-9]*, and the staging volume has [0-9]* of [0-9]* bytes free; free disk space first (mise run disk shows what holds it); no Backup was made" "$work/now" ||
  fail "backup:now beside a refused fit ended $status with '$(cat "$work/now")'"
[ "$(backup_names)" = "$backups_before" ] || fail "backup:now made a Backup after its seed was refused"
echo "backup:now refused with its room sentence and made no Backup"
