#!/usr/bin/env bash
# Drive `mise run gpu:use` against a fake kubectl that records its calls and fails the one it is told to, for the
# outcomes the cluster cannot arrange: `speech` stops songmaker's worker and waits until its pod is gone, starts the GPU
# image and waits until it is Ready, and only then stops the small image, so the Service speech-runtime never has no
# Ready pod; `songs` does it the other way round, starting the small image before the GPU image stops and the card
# is free; a wait that fails ends non-zero, names the Deployment and the way back and makes none of the later calls;
# the GPU Deployment's progress deadline is not shorter than the wait the switch grants it; an unknown user is refused
# before any call; the GPU pod spools an upload into memory, as the small pod does, so a recording never reaches a disk.
# Usage: mise exec -- tests/gpu/use_orders_the_switch_and_names_the_way_back.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
calls="$work_directory/calls"
mkdir "$fake_bin"

# The fake records each call as its subcommand and arguments and fails the call that contains FAKE_FAILING_CALL.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CALLS"
if [ -n "${FAKE_FAILING_CALL:-}" ] && [[ "$*" == *"$FAKE_FAILING_CALL"* ]]; then
  exit 1
fi
FAKE
chmod +x "$fake_bin/kubectl"

# switch_to <user>: runs the task's script and leaves its status in `status` and its lines in `output`.
switch_to() {
  : >"$calls"
  status=0
  output="$(PATH="$fake_bin:$PATH" FAKE_CALLS="$calls" KUBECONFIG=/nonexistent "$repository_root/scripts/gpu_use.sh" "$@" 2>&1)" || status=$?
}

# expect_calls <description> <call fragment>...: the recorded calls contain the fragments in this order and nothing else.
expect_calls() {
  local description="$1" index=0 recorded
  shift
  [ "$(wc -l <"$calls")" -eq "$#" ] || fail "$description: expected $# calls, got $(wc -l <"$calls"): $(tr '\n' ';' <"$calls")"
  while IFS= read -r recorded; do
    index=$((index + 1))
    [[ "$recorded" == *"${!index}"* ]] || fail "$description: call $index is '$recorded', expected one with '${!index}'"
  done <"$calls"
}

switch_to speech
[ "$status" -eq 0 ] || fail "speech ended $status: $output"
expect_calls "speech" \
  "scale --namespace songmaker deployment/acestep-worker --replicas=0" \
  "wait --namespace songmaker --for=delete pod" \
  "scale --namespace speech-runtime deployment/speech-runtime-gpu --replicas=1" \
  "rollout status --namespace speech-runtime deployment/speech-runtime-gpu" \
  "scale --namespace speech-runtime deployment/speech-runtime --replicas=0"

switch_to songs
[ "$status" -eq 0 ] || fail "songs ended $status: $output"
expect_calls "songs" \
  "scale --namespace speech-runtime deployment/speech-runtime --replicas=1" \
  "rollout status --namespace speech-runtime deployment/speech-runtime" \
  "scale --namespace speech-runtime deployment/speech-runtime-gpu --replicas=0" \
  "wait --namespace speech-runtime --for=delete pod" \
  "scale --namespace songmaker deployment/acestep-worker --replicas=1" \
  "rollout status --namespace songmaker deployment/acestep-worker"

# A failed wait for the GPU image names it and the way back, and the small image is never stopped.
FAKE_FAILING_CALL="rollout status --namespace speech-runtime deployment/speech-runtime-gpu" switch_to speech
[ "$status" -ne 0 ] || fail "a failed wait for the GPU image ended 0"
[[ "$output" == *speech-runtime-gpu* && "$output" == *"gpu:use songs"* ]] ||
  fail "a failed wait for the GPU image did not name it and the way back: $output"
if grep -q 'deployment/speech-runtime --replicas=0' "$calls"; then
  fail "a failed wait for the GPU image still stopped the small image"
fi

# A failed wait for the worker's pod to go ends before the GPU image starts.
FAKE_FAILING_CALL="wait --namespace songmaker" switch_to speech
[ "$status" -ne 0 ] || fail "a failed wait for the worker's pod to go ended 0"
[[ "$output" == *acestep-worker* ]] || fail "a failed wait for the worker's pod to go did not name it: $output"
if grep -q 'speech-runtime-gpu' "$calls"; then
  fail "the GPU image started although the worker's pod was still there"
fi

# A failed wait for the small image ends before the GPU image stops, so the card stays with its user.
FAKE_FAILING_CALL="rollout status --namespace speech-runtime deployment/speech-runtime" switch_to songs
[ "$status" -ne 0 ] || fail "a failed wait for the small image ended 0"
if grep -q 'speech-runtime-gpu' "$calls"; then
  fail "the GPU image stopped although the small image was not Ready"
fi

# An unknown user is refused before any call.
switch_to everyone
[ "$status" -ne 0 ] || fail "an unknown user ended 0"
[[ "$output" == *"unknown user 'everyone'"* ]] || fail "an unknown user was not named: $output"
[ ! -s "$calls" ] || fail "an unknown user made calls: $(tr '\n' ';' <"$calls")"

# The Deployment's progress deadline outlasts the wait the switch grants the GPU image, or the rollout status fails
# before its own timeout.
switch_to speech
granted="$(sed -n 's/.*rollout status.*speech-runtime-gpu.*--timeout=\([0-9]*\)s.*/\1/p' "$calls")"
deadline="$(yq '.spec.progressDeadlineSeconds' "$repository_root/apps/speech-runtime/speech-runtime-gpu.yaml")"
[ -n "$granted" ] || fail "the wait for the GPU image grants no timeout"
[ "$deadline" != null ] && [ "$deadline" -ge "$granted" ] ||
  fail "the GPU Deployment's progress deadline ($deadline s) is shorter than the wait for it ($granted s)"

# tmp_medium <deployment>: the medium of the emptyDir that the Deployment mounts at /tmp.
tmp_medium() {
  yq "select(.kind == \"Deployment\" and .metadata.name == \"$1\") | .spec.template.spec as \$pod
    | \$pod.containers[].volumeMounts[] | select(.mountPath == \"/tmp\") | .name as \$volume
    | \$pod.volumes[] | select(.name == \$volume) | .emptyDir.medium" "$repository_root/apps/speech-runtime/"*.yaml
}
[ "$(tmp_medium speech-runtime-gpu)" = Memory ] || fail "the GPU pod's /tmp, where an upload is spooled, is not memory-backed"
[ "$(tmp_medium speech-runtime)" = Memory ] || fail "the small pod's /tmp, where an upload is spooled, is not memory-backed"
echo "gpu:use orders the switch, names the way back and waits as long as the Deployment allows"
