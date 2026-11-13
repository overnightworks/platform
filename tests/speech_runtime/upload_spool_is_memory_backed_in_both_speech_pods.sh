#!/usr/bin/env bash
# Both speech pods, the small one and the GPU one, mount /tmp, where an upload is spooled, as a memory-backed emptyDir,
# so a recording never reaches a disk.
# Usage: mise exec -- tests/speech_runtime/upload_spool_is_memory_backed_in_both_speech_pods.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"

# tmp_medium <deployment>: the medium of the emptyDir that the Deployment mounts at /tmp.
tmp_medium() {
  yq "select(.kind == \"Deployment\" and .metadata.name == \"$1\") | .spec.template.spec as \$pod
    | \$pod.containers[].volumeMounts[] | select(.mountPath == \"/tmp\") | .name as \$volume
    | \$pod.volumes[] | select(.name == \$volume) | .emptyDir.medium" "$repository_root/apps/speech-runtime/"*.yaml
}
[ "$(tmp_medium speech-runtime-gpu)" = Memory ] || fail "the GPU pod's /tmp, where an upload is spooled, is not memory-backed"
[ "$(tmp_medium speech-runtime)" = Memory ] || fail "the small pod's /tmp, where an upload is spooled, is not memory-backed"
echo "both speech pods spool an upload into memory"
