#!/usr/bin/env bash
# The files half of `mise run db:load-dump --files <dir>`: the checks of the source tree and the loader Pod that holds
# the namespace's claim while rsync replaces its content with the tree's. It prints names, counts, bytes and outcomes,
# never a file name; rsync's messages go to the log file the caller names.
# Usage: scripts/load_files.sh check <dir>
#        scripts/load_files.sh start <namespace> <pod> <dir>
#        scripts/load_files.sh sync <namespace> <pod> <dir> <log>
#        scripts/load_files.sh verify <namespace> <pod> <dir> <log>
#        scripts/load_files.sh stop <namespace> <pod>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
say() { echo "db:load-dump: $1"; }
fail() { echo "db:load-dump: $1" >&2; exit 1; }
rsh="$(dirname "${BASH_SOURCE[0]}")/rsh_into_pod.sh"

# count_entries <dir> <find expression>...: how many entries of the tree match; an entry find cannot read counts.
count_entries() {
  local directory="$1"
  shift
  { find "$directory" -mindepth 1 "$@" -print0 2>/dev/null || true; } | tr -cd '\0' | wc -c
}

source_bytes() { find "$1" -type f -printf '%s\n' | awk '{ bytes += $1 } END { print bytes + 0 }'; }

check() {
  local directory="$1" other unreadable newline_names files
  [ -d "$directory" ] || fail "$directory is no directory; nothing changed"
  command -v rsync >/dev/null || fail "rsync is not installed on this machine; nothing changed"
  find "$directory" >/dev/null 2>&1 || fail "$directory cannot be read completely; nothing changed"
  other="$(count_entries "$directory" '!' -type f '!' -type d)"
  unreadable="$(count_entries "$directory" '!' -readable)"
  newline_names="$(count_entries "$directory" -name $'*\n*')"
  files="$(count_entries "$directory" -type f)"
  [ "$other" = 0 ] || fail "$directory holds $other entries that are neither regular files nor directories; nothing changed"
  [ "$unreadable" = 0 ] || fail "$directory holds $unreadable entries this user cannot read; nothing changed"
  [ "$newline_names" = 0 ] || fail "$directory holds $newline_names names with a newline; nothing changed"
  [ "$files" != 0 ] || fail "$directory holds no file; nothing changed"
  say "the files of $directory: $files files, $(source_bytes "$directory") bytes"
}

# The Pod is the copy container's image of the namespace's PreBackupPod, the one image the platform runs rsync in, at the
# reading uid that PreBackupPod sets, with the claim the layer declares writable and no token.
start() {
  local namespace="$1" pod="$2" directory="$3" claim manifest free needed
  claim="$(kubectl --namespace "$namespace" get configmap postgres --output jsonpath='{.data.backup-claim}')" ||
    fail "cannot read the claim of $namespace; nothing changed"
  kubectl --namespace "$namespace" delete pod "$pod" --ignore-not-found --wait >/dev/null ||
    fail "cannot delete an earlier loader Pod $pod in $namespace"
  # shellcheck disable=SC2016 # $uid is yq's variable
  manifest="$(kubectl --namespace "$namespace" get prebackuppod.k8up.io files --output json |
    NAME="$pod" CLAIM="$claim" yq --input-format json --output-format json \
      '.spec.pod.spec.securityContext.runAsUser as $uid |
       { "apiVersion": "v1", "kind": "Pod", "metadata": { "name": strenv(NAME) },
         "spec": { "automountServiceAccountToken": false, "enableServiceLinks": false,
           "terminationGracePeriodSeconds": 1,
           "securityContext": { "runAsNonRoot": true, "runAsUser": $uid, "runAsGroup": $uid,
             "seccompProfile": { "type": "RuntimeDefault" } },
           "containers": [{ "name": "loader",
             "image": (.spec.pod.spec.containers[] | select(.name == "copy") | .image),
             "command": ["sleep", "86400"],
             "securityContext": { "allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true,
               "capabilities": { "drop": ["ALL"] } },
             "volumeMounts": [{ "name": "claim", "mountPath": "/target" }] }],
           "volumes": [{ "name": "claim", "persistentVolumeClaim": { "claimName": strenv(CLAIM) } }] } }')" ||
    fail "cannot read the PreBackupPod files in $namespace; nothing changed"
  kubectl --namespace "$namespace" create --filename - <<<"$manifest" >/dev/null ||
    fail "could not start the loader Pod $pod in $namespace; nothing changed"
  kubectl --namespace "$namespace" wait "pod/$pod" --for=condition=Ready --timeout=5m >/dev/null ||
    fail "the loader Pod $pod is not Ready after 5 minutes; nothing changed"
  free="$(kubectl --namespace "$namespace" exec "$pod" --container loader -- df -Pk /target |
    awk 'NR == 2 { print $4 * 1024 }')" || fail "cannot read the free space of the claim of $namespace; nothing changed"
  needed="$(source_bytes "$directory")"
  [ "$free" -ge "$needed" ] || fail "the claim of $namespace has $free bytes free and $directory holds $needed; nothing changed"
  say "the claim of $namespace has $free bytes free for $needed"
}

rsync_into_pod() {
  local namespace="$1" pod="$2" directory="$3"
  shift 3
  # The claim's root belongs to the provisioner's user, so the loader cannot set its mode or time; the files below it are
  # the loader's, with the modes its umask gives.
  RSH_NAMESPACE="$namespace" RSH_POD="$pod" rsync --rsh="$rsh" -a --no-perms --omit-dir-times --delete "$@" \
    "$directory/" "$pod:/target/"
}

sync() {
  local namespace="$1" pod="$2" directory="$3" log="$4"
  rsync_into_pod "$namespace" "$pod" "$directory" 2>>"$log" ||
    fail "rsync into the claim of $namespace failed; $(grep -c . "$log") lines in $log"
  say "copied the files of $directory into the claim of $namespace; $(grep -c . "$log") lines in $log"
}

# Every line --itemize-changes prints names a difference, so zero lines is equal.
verify() {
  local namespace="$1" pod="$2" directory="$3" log="$4" itemized differing
  itemized="$(rsync_into_pod "$namespace" "$pod" "$directory" --checksum --dry-run --itemize-changes 2>>"$log")" ||
    fail "the checksum comparison of the claim of $namespace failed; $(grep -c . "$log") lines in $log"
  differing="$(grep -c . <<<"$itemized" || true)"
  [ "$differing" = 0 ] || fail "the claim of $namespace differs from $directory in $differing entries"
  say "the claim of $namespace equals $directory: 0 differing entries"
}

stop() { kubectl --namespace "$1" delete pod "$2" --ignore-not-found --wait >/dev/null; }

case "${1:-}" in
  check) check "$2" ;;
  start) start "$2" "$3" "$4" ;;
  sync) sync "$2" "$3" "$4" "$5" ;;
  verify) verify "$2" "$3" "$4" "$5" ;;
  stop) stop "$2" "$3" ;;
  *) fail "unknown step '${1:-}'" ;;
esac
