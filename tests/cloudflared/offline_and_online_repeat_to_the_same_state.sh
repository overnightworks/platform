#!/usr/bin/env bash
# Drive `scripts/take_platform_offline_or_online.sh` against a fake kubectl, for the states the cluster cannot arrange:
# offline suspends the Kustomization tunnel, scales cloudflared to 0 and deletes its Pods, in that order, and a repeat or
# a run after a failed step ends in the same state with status 0; online clears the suspend and forces a reconcile, and a
# repeat ends in the same state with status 0; with the Kustomization unreadable offline refuses and changes nothing.
# Usage: mise exec -- tests/cloudflared/offline_and_online_repeat_to_the_same_state.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
state="$work_directory/state"
calls="$work_directory/calls"
mkdir "$fake_bin" "$state"

# The fake kubectl records each call and keeps the cluster's state in FAKE_STATE: patch writes the suspend, scale the
# replicas, delete removes the Pods, and the reads answer from them; a reconcile request is handled at once and restores
# the replicas and Pods unless the Kustomization is suspended. The call that contains FAKE_FAILING_CALL fails.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CALLS"
if [ -n "${FAKE_FAILING_CALL:-}" ] && [[ "$*" == *"$FAKE_FAILING_CALL"* ]]; then
  exit 1
fi
case "$*" in
  *"get kustomization tunnel"*lastHandledReconcileAt*) cat "$FAKE_STATE/token" ;;
  *"get kustomization tunnel"*Ready*) echo True ;;
  *"get kustomization tunnel"*'{.spec.suspend}'*) cat "$FAKE_STATE/suspend" 2>/dev/null || true ;;
  *"get kustomization tunnel"*) [ -e "$FAKE_STATE/layer" ] || exit 1 ;;
  *"patch kustomization tunnel"*'"suspend":true'*) echo true >"$FAKE_STATE/suspend" ;;
  *"patch kustomization tunnel"*'"suspend":null'*) rm -f "$FAKE_STATE/suspend" ;;
  *"scale deployment cloudflared --replicas="*) sed 's/.*--replicas=//; s/ .*//' <<<"$*" >"$FAKE_STATE/replicas" ;;
  *"delete pod"*) rm -f "$FAKE_STATE/pods" ;;
  *"get pod"*) if [ -e "$FAKE_STATE/pods" ]; then echo pod/cloudflared-0; fi ;;
  *"annotate kustomization tunnel"*)
    sed 's/.*requestedAt=//; s/ .*//' <<<"$*" >"$FAKE_STATE/token"
    if [ ! -e "$FAKE_STATE/suspend" ]; then echo 1 >"$FAKE_STATE/replicas"; touch "$FAKE_STATE/pods"; fi ;;
esac
FAKE
chmod +x "$fake_bin/kubectl"

# run_script <verb>: runs the script and leaves its status in `status` and its lines in `output`.
run_script() {
  : >"$calls"
  status=0
  output="$(PATH="$fake_bin:$PATH" FAKE_CALLS="$calls" FAKE_STATE="$state" KUBECONFIG=/nonexistent PLATFORM_OFFLINE_WAIT_SECONDS=2 \
    PLATFORM_OFFLINE_POLL_SECONDS=1 "$repository_root/scripts/take_platform_offline_or_online.sh" "$@" 2>&1)" || status=$?
}
made_call() { grep -q -- "$1" "$calls"; }
call_line() { grep -n -- "$1" "$calls" | head -1 | cut -d: -f1; }

# running_cluster: the cluster as Git declares it, one cloudflared Pod up and the Kustomization not suspended.
running_cluster() {
  rm -f "$state/suspend"
  touch "$state/layer" "$state/pods"
  echo 1 >"$state/replicas"
}
# cluster_state: the suspend, the replicas and whether a Pod exists, as one line.
cluster_state() {
  echo "suspend=$(cat "$state/suspend" 2>/dev/null || true) replicas=$(cat "$state/replicas") pods=$([ -e "$state/pods" ] && echo some || echo none)"
}
offline_state="suspend=true replicas=0 pods=none"
online_state="suspend= replicas=1 pods=some"

running_cluster
run_script offline
[ "$status" -eq 0 ] || fail "offline ended $status: $output"
made_call '"suspend":true' || fail "offline did not suspend tunnel"
made_call "scale deployment cloudflared --replicas=0" || fail "offline did not scale cloudflared to 0"
made_call "delete pod" || fail "offline did not delete the Pods"
[ "$(call_line '"suspend":true')" -lt "$(call_line 'scale deployment')" ] || fail "offline scaled before it suspended"
[ "$(call_line 'scale deployment')" -lt "$(call_line 'delete pod')" ] || fail "offline deleted the Pods before it scaled"
[ "$(cluster_state)" = "$offline_state" ] || fail "offline ended in $(cluster_state), not $offline_state"

run_script offline
[ "$status" -eq 0 ] || fail "a repeated offline ended $status: $output"
[ "$(cluster_state)" = "$offline_state" ] || fail "a repeated offline ended in $(cluster_state), not $offline_state"

running_cluster
FAKE_FAILING_CALL="scale deployment" run_script offline
[ "$status" -ne 0 ] || fail "an offline whose scale failed ended 0"
if made_call 'delete pod'; then fail "an offline whose scale failed went on to delete the Pods"; fi
run_script offline
[ "$status" -eq 0 ] || fail "an offline after an interrupted one ended $status: $output"
[ "$(cluster_state)" = "$offline_state" ] || fail "an offline after an interrupted one ended in $(cluster_state), not $offline_state"
echo "offline suspends, scales to 0 and deletes the Pods in that order, and repeats to the same state"

run_script online
[ "$status" -eq 0 ] || fail "online ended $status: $output"
made_call '"suspend":null' || fail "online did not clear the suspend"
made_call 'annotate kustomization tunnel reconcile.fluxcd.io/requestedAt=' || fail "online did not force a reconcile"
[ "$(cluster_state)" = "$online_state" ] || fail "online ended in $(cluster_state), not $online_state"
run_script online
[ "$status" -eq 0 ] || fail "a repeated online ended $status: $output"
[ "$(cluster_state)" = "$online_state" ] || fail "a repeated online ended in $(cluster_state), not $online_state"
echo "online clears the suspend, forces a reconcile and repeats to the same state"

rm "$state/layer"
run_script offline
[ "$status" -ne 0 ] || fail "offline ended 0 with the Kustomization unreadable"
if made_call 'patch\|scale\|delete'; then fail "offline changed something with the Kustomization unreadable: $(cat "$calls")"; fi
[ "$(cluster_state)" = "$online_state" ] || fail "offline changed the cluster to $(cluster_state) with the Kustomization unreadable"
echo "offline refuses with the Kustomization unreadable and changes nothing"
