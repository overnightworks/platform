#!/usr/bin/env bash
# Drive `mise run gpu:use` against a fake kubectl that records its calls and fails the one it is told to, for the
# outcomes the cluster cannot arrange: `speech` stops songmaker's worker and waits until its pod is gone, starts the GPU
# image and waits until it is Ready, and only then stops the small image, so the Service speech-runtime never has no
# Ready pod; `songs` does it the other way round, starting the small image at two pods and waiting until both are
# Ready before the GPU image stops and the card is free; every wait for a Deployment is for the ready replicas it was
# scaled to and never for its rollout status, which a progress deadline that ran out while a pod waited for the card
# would fail; a wait that fails ends non-zero, names the
# Deployment and the way back and makes none of the later calls; `free` runs only while speech holds the card, arms the
# user timer before its first scale, runs the voice half `songs` runs and leaves the worker alone, and a repeated `free`
# stops the timer it armed; the guarded `return` the timer runs acts only while nobody took the card since; `songs` and
# `speech` make no systemd call; an unknown user is refused before any call.
# Usage: mise exec -- tests/gpu/use_orders_the_switch_names_the_way_back_and_waits_for_the_ready_replica.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
calls="$work_directory/calls"
mkdir "$fake_bin"

# One fake stands for kubectl, systemd-run and systemctl: it records each call as its program, subcommand and arguments
# in one file, so the order across them is read, and fails the call that contains FAKE_FAILING_CALL. `kubectl get` answers
# the replicas of a Deployment from a state file of its name, and fails without one; `systemctl is-active` reports
# active once `systemd-run` armed a timer, until `systemctl stop` ended it. `systemctl --user stop` names the unit.
cat >"$work_directory/fake" <<'FAKE'
#!/usr/bin/env bash
call="$(basename "$0") $*"
echo "$call" >>"$FAKE_CALLS"
if [ -n "${FAKE_FAILING_CALL:-}" ] && [[ "$call" == *"$FAKE_FAILING_CALL"* ]]; then
  exit 1
fi
case "$(basename "$0") $*" in
  "kubectl get "*)
    for argument in "$@"; do
      if [[ "$argument" == deployment/* ]]; then cat "$FAKE_STATE/${argument#deployment/}" || exit 1; fi
    done
    ;;
  "systemd-run "*) : >"$FAKE_STATE/armed" ;;
  "systemctl --user is-active"*) [ -e "$FAKE_STATE/armed" ] ;;
  "systemctl --user stop"*) rm -f "$FAKE_STATE/armed" ;;
esac
FAKE
chmod +x "$work_directory/fake"
for program in kubectl systemd-run systemctl; do ln -s ../fake "$fake_bin/$program"; done
state="$work_directory/state"
mkdir "$state"

# set_replicas <worker> <GPU voice>: the replicas the fake cluster reports.
set_replicas() {
  echo "$1" >"$state/acestep-worker"
  echo "$2" >"$state/speech-runtime-gpu"
}

# switch_to <user>: runs the task's script and leaves its status in `status` and its lines in `output`.
switch_to() {
  : >"$calls"
  status=0
  output="$(PATH="$fake_bin:$PATH" FAKE_CALLS="$calls" FAKE_STATE="$state" MISE_DISABLE_TOOLS=kubectl KUBECONFIG=/nonexistent "$repository_root/scripts/gpu_use.sh" "$@" 2>&1)" || status=$?
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

# No fake systemctl answer stands before the first arm.
set_replicas 0 1
switch_to speech
[ "$status" -eq 0 ] || fail "speech ended $status: $output"
expect_calls "speech" \
  "scale --namespace songmaker deployment/acestep-worker --replicas=0" \
  "wait --namespace songmaker --for=delete pod" \
  "scale --namespace speech-runtime deployment/speech-runtime-gpu --replicas=1" \
  "wait --namespace speech-runtime deployment/speech-runtime-gpu --for=jsonpath={.status.readyReplicas}=1" \
  "scale --namespace speech-runtime deployment/speech-runtime --replicas=0"

switch_to songs
[ "$status" -eq 0 ] || fail "songs ended $status: $output"
expect_calls "songs" \
  "scale --namespace speech-runtime deployment/speech-runtime --replicas=2" \
  "wait --namespace speech-runtime deployment/speech-runtime --for=jsonpath={.status.readyReplicas}=2" \
  "scale --namespace speech-runtime deployment/speech-runtime-gpu --replicas=0" \
  "wait --namespace speech-runtime --for=delete pod" \
  "scale --namespace songmaker deployment/acestep-worker --replicas=1" \
  "wait --namespace songmaker deployment/acestep-worker --for=jsonpath={.status.readyReplicas}=1"

# Neither `songs` nor `speech` touches the timer.
switch_to speech
if grep -q '^systemd' "$calls" || grep -q '^systemctl' "$calls"; then fail "speech made a systemd call"; fi
switch_to songs
if grep -q '^systemd' "$calls" || grep -q '^systemctl' "$calls"; then fail "songs made a systemd call"; fi

# A failed wait for the GPU image names it and the way back, and the small image is never stopped.
FAKE_FAILING_CALL="wait --namespace speech-runtime deployment/speech-runtime-gpu" switch_to speech
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
FAKE_FAILING_CALL="wait --namespace speech-runtime deployment/speech-runtime --for" switch_to songs
[ "$status" -ne 0 ] || fail "a failed wait for the small image ended 0"
if grep -q 'speech-runtime-gpu' "$calls"; then
  fail "the GPU image stopped although the small image was not Ready"
fi

# arm_name: the unit name the recorded `systemd-run` call armed.
arm_name() { sed -n 's/^systemd-run .*--unit=\([^ ]*\) .*/\1/p' "$calls"; }

# free: from speech's state it arms the bound before its first scale, then runs the voice half and leaves the worker.
set_replicas 0 1
rm -f "$state/armed"
switch_to free
[ "$status" -eq 0 ] || fail "free ended $status: $output"
expect_calls "free" \
  "kubectl get --namespace songmaker deployment/acestep-worker" \
  "kubectl get --namespace speech-runtime deployment/speech-runtime-gpu" \
  "systemctl --user is-active" \
  "systemd-run --user" \
  "kubectl scale --namespace speech-runtime deployment/speech-runtime --replicas=2" \
  "kubectl wait --namespace speech-runtime deployment/speech-runtime --for=jsonpath={.status.readyReplicas}=2" \
  "kubectl scale --namespace speech-runtime deployment/speech-runtime-gpu --replicas=0" \
  "kubectl wait --namespace speech-runtime --for=delete pod"
armed_call="$(grep '^systemd-run' "$calls")"
unit_name="$(arm_name)"
[ -n "$unit_name" ] || fail "free armed no named unit: $armed_call"
[[ "$armed_call" == *" --on-active="* ]] || fail "free armed no bound: $armed_call"
read -ra armed_arguments <<<"$armed_call"
[ "${armed_arguments[-1]}" = return ] || fail "the bound does not run the return: $armed_call"
[ "$(realpath "${armed_arguments[-2]}")" = "$(realpath "$repository_root/scripts/gpu_use.sh")" ] ||
  fail "the bound does not run this script by its absolute path: $armed_call"
[[ "${armed_arguments[-2]}" == /* ]] || fail "the bound's script path is not absolute: $armed_call"
[[ "$armed_call" == *"--setenv=PATH"* && "$armed_call" == *"--setenv=KUBECONFIG"* ]] ||
  fail "the bound does not pass PATH and KUBECONFIG: $armed_call"
if grep -q 'acestep-worker --replicas' "$calls"; then fail "free scaled the worker"; fi
[[ "$output" == *"the card is free"* ]] || fail "free printed no success line: $output"

# A second free stops the timer it armed, by the name it armed, before it arms again.
set_replicas 0 1
switch_to free
[ "$status" -eq 0 ] || fail "a second free ended $status: $output"
stopped_name="$(sed -n 's/^systemctl --user stop \(.*\)$/\1/p' "$calls")"
[ -n "$stopped_name" ] || fail "a second free stopped nothing: $(tr '\n' ';' <"$calls")"
[[ "$stopped_name" == "$unit_name"* ]] || fail "the second free stopped '$stopped_name', not the unit '$unit_name' it armed"
stop_line="$(grep -n '^systemctl --user stop' "$calls" | cut -d: -f1)"
arm_line="$(grep -n '^systemd-run' "$calls" | cut -d: -f1)"
[ "$stop_line" -lt "$arm_line" ] || fail "the second free armed before it stopped the old timer"

# free refuses without a scale or an arm, names what it found and the way back: worker running, GPU voice off, state unreadable.
for state_case in "1 1" "0 0" "0 2"; do
  # shellcheck disable=SC2086
  set_replicas $state_case
  switch_to free
  [ "$status" -ne 0 ] || fail "free ended 0 from the state '$state_case'"
  [[ "$output" == *acestep-worker* && "$output" == *speech-runtime-gpu* && "$output" == *"gpu:use speech"* && "$output" == *"gpu:use songs"* ]] ||
    fail "free's refusal from '$state_case' names no state and way back: $output"
  if grep -qE 'scale|systemd-run|systemctl' "$calls"; then fail "free made a scale or systemd call from '$state_case'"; fi
done
set_replicas 0 1
rm "$state/acestep-worker"
switch_to free
[ "$status" -ne 0 ] || fail "free ended 0 with an unreadable state"
if grep -qE 'scale|systemd-run|systemctl' "$calls"; then fail "free made a scale or systemd call with an unreadable state"; fi

# An arm that fails ends before any scale call and says the bound is not armed.
set_replicas 0 1
FAKE_FAILING_CALL="systemd-run" switch_to free
[ "$status" -ne 0 ] || fail "a failed arm ended 0"
[[ "$output" == *"gpu-use-return"* || "$output" == *"timer"* ]] || fail "a failed arm did not name the timer: $output"
if grep -q 'scale' "$calls"; then fail "free scaled although the bound was not armed"; fi

# A stale timer that cannot be stopped ends before the arm and any scale.
set_replicas 0 1
: >"$state/armed"
FAKE_FAILING_CALL="systemctl --user stop" switch_to free
[ "$status" -ne 0 ] || fail "a stale timer that would not stop ended 0"
if grep -qE 'scale|systemd-run' "$calls"; then fail "free went on although the stale timer was not stopped"; fi

# A replica count that is no number is an unreadable state.
echo none >"$state/acestep-worker"
echo 1 >"$state/speech-runtime-gpu"
switch_to free
[ "$status" -ne 0 ] || fail "free ended 0 with a replica count that is no number"

# A failed wait for the small voice ends before the GPU voice scales and leaves the bound armed.
set_replicas 0 1
rm -f "$state/armed"
FAKE_FAILING_CALL="wait --namespace speech-runtime deployment/speech-runtime --for" switch_to free
[ "$status" -ne 0 ] || fail "a failed wait for the small voice ended 0 in free"
grep -q '^systemd-run' "$calls" || fail "free armed no bound before the failed wait"
if grep -q 'speech-runtime-gpu --replicas' "$calls" || grep -q 'systemctl --user stop' "$calls"; then
  fail "a failed wait scaled the GPU voice or stopped the bound"
fi
[[ "$output" == *"gpu:use speech"* ]] || fail "a failed wait in free named no way back: $output"

# return acts only while nobody took the card: it makes no scale call and ends 0 when the worker or the GPU voice runs.
for state_case in "1 0" "0 1" "1 1"; do
  # shellcheck disable=SC2086
  set_replicas $state_case
  switch_to return
  [ "$status" -eq 0 ] || fail "return ended $status from '$state_case': $output"
  if grep -qE 'scale|systemd-run|systemctl' "$calls"; then fail "return acted from '$state_case'"; fi
  [[ "$output" == *"nothing returned"* ]] || fail "return from '$state_case' did not say it returned nothing: $output"
done
set_replicas 0 0
switch_to return
[ "$status" -eq 0 ] || fail "return ended $status with both at 0: $output"
expect_calls "return" \
  "kubectl get --namespace songmaker deployment/acestep-worker" \
  "kubectl get --namespace speech-runtime deployment/speech-runtime-gpu" \
  "kubectl scale --namespace songmaker deployment/acestep-worker --replicas=0" \
  "kubectl wait --namespace songmaker --for=delete pod" \
  "kubectl scale --namespace speech-runtime deployment/speech-runtime-gpu --replicas=1" \
  "kubectl wait --namespace speech-runtime deployment/speech-runtime-gpu --for=jsonpath={.status.readyReplicas}=1" \
  "kubectl scale --namespace speech-runtime deployment/speech-runtime --replicas=0"

# An unknown user is refused before any call.
switch_to everyone
[ "$status" -ne 0 ] || fail "an unknown user ended 0"
[[ "$output" == *"unknown user 'everyone'"* ]] || fail "an unknown user was not named: $output"
[ ! -s "$calls" ] || fail "an unknown user made calls: $(tr '\n' ';' <"$calls")"

echo "gpu:use orders the switch, names the way back and waits for each Deployment's ready replica"
