#!/usr/bin/env bash
# The GPU Deployment's progressDeadlineSeconds is not shorter than the wait `mise run gpu:use speech` grants its
# rollout, or the rollout status fails on the Deployment's deadline before its own timeout. The wait is read from the
# call the task's script makes, against a fake kubectl that answers every call with success.
# Usage: mise exec -- tests/gpu/progress_deadline_outlasts_the_wait_for_the_gpu_image.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
calls="$work_directory/calls"
mkdir "$fake_bin"

cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CALLS"
FAKE
chmod +x "$fake_bin/kubectl"

PATH="$fake_bin:$PATH" FAKE_CALLS="$calls" KUBECONFIG=/nonexistent "$repository_root/scripts/gpu_use.sh" speech >/dev/null
granted="$(sed -n 's/.*rollout status.*speech-runtime-gpu.*--timeout=\([0-9]*\)s.*/\1/p' "$calls")"
deadline="$(yq '.spec.progressDeadlineSeconds' "$repository_root/apps/speech-runtime/speech-runtime-gpu.yaml")"
[ -n "$granted" ] || fail "the wait for the GPU image grants no timeout"
[ "$deadline" != null ] && [ "$deadline" -ge "$granted" ] ||
  fail "the GPU Deployment's progress deadline ($deadline s) is shorter than the wait for it ($granted s)"
echo "the GPU Deployment's progress deadline outlasts the wait for the GPU image"
