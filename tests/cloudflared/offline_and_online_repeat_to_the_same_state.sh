#!/usr/bin/env bash
# Drive `scripts/take_platform_offline_or_online.sh` against a fake kubectl, for the states the cluster cannot arrange:
# offline suspends the Kustomization tunnel, scales cloudflared to 0 and deletes its Pods, in that order, and makes the
# same calls when repeated or run again after a step failed; online clears the suspend and forces a reconcile, and
# makes the same calls when repeated; with the Kustomization unreadable offline refuses and changes nothing.
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

# The fake kubectl records each call and answers the reads the script makes; the call that contains FAKE_FAILING_CALL
# fails. A Pod listing is empty, and a reconcile request is handled at once.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CALLS"
if [ -n "${FAKE_FAILING_CALL:-}" ] && [[ "$*" == *"$FAKE_FAILING_CALL"* ]]; then
  exit 1
fi
case "$*" in
  *"get kustomization tunnel"*lastHandledReconcileAt*) cat "$FAKE_STATE/token" ;;
  *"get kustomization tunnel"*Ready*) echo True ;;
  *"get kustomization tunnel"*) [ -e "$FAKE_STATE/layer" ] || exit 1 ;;
  *"annotate kustomization tunnel"*) sed 's/.*requestedAt=//; s/ .*//' <<<"$*" >"$FAKE_STATE/token" ;;
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

touch "$state/layer"
run_script offline
[ "$status" -eq 0 ] || fail "offline ended $status: $output"
made_call '"suspend":true' || fail "offline did not suspend tunnel"
made_call "scale deployment cloudflared --replicas=0" || fail "offline did not scale cloudflared to 0"
made_call "delete pod" || fail "offline did not delete the Pods"
[ "$(call_line '"suspend":true')" -lt "$(call_line 'scale deployment')" ] || fail "offline scaled before it suspended"
[ "$(call_line 'scale deployment')" -lt "$(call_line 'delete pod')" ] || fail "offline deleted the Pods before it scaled"
first_offline="$(cat "$calls")"

run_script offline
[ "$status" -eq 0 ] && [ "$(cat "$calls")" = "$first_offline" ] || fail "a repeated offline made other calls or ended $status: $output"
FAKE_FAILING_CALL="scale deployment" run_script offline
[ "$status" -ne 0 ] || fail "an offline whose scale failed ended 0"
if made_call 'delete pod'; then fail "an offline whose scale failed went on to delete the Pods"; fi
run_script offline
[ "$status" -eq 0 ] && [ "$(cat "$calls")" = "$first_offline" ] || fail "an offline after an interrupted one ended in another state: $output"
echo "offline suspends, scales to 0 and deletes the Pods in that order, and repeats to the same state"

run_script online
[ "$status" -eq 0 ] || fail "online ended $status: $output"
made_call '"suspend":null' || fail "online did not clear the suspend"
made_call 'annotate kustomization tunnel reconcile.fluxcd.io/requestedAt=' || fail "online did not force a reconcile"
first_online_names="$(sed 's/requestedAt=[0-9]*/requestedAt=T/' "$calls")"
run_script online
[ "$status" -eq 0 ] && [ "$(sed 's/requestedAt=[0-9]*/requestedAt=T/' "$calls")" = "$first_online_names" ] ||
  fail "a repeated online made other calls or ended $status: $output"
echo "online clears the suspend, forces a reconcile and repeats to the same state"

rm "$state/layer"
run_script offline
[ "$status" -ne 0 ] || fail "offline ended 0 with the Kustomization unreadable"
if made_call 'patch\|scale\|delete'; then fail "offline changed something with the Kustomization unreadable: $(cat "$calls")"; fi
echo "offline refuses with the Kustomization unreadable and changes nothing"
