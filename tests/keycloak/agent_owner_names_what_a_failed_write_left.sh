#!/usr/bin/env bash
# Drive `mise run keycloak:agent-owner` against a fake kubectl whose kcadm answers from fixed data, for the outcomes the
# cluster cannot arrange: an unknown username is refused before any client's service account is read, a person whose
# username starts like a service account's is taken, a client's service account is refused as owner with nothing
# changed, the secret stands in no argument and the sign-in file goes on every exit, and a membership write that fails
# names what was written (after the owner's write or alone) and does not claim that nothing changed.
# Usage: mise exec -- tests/keycloak/agent_owner_names_what_a_failed_write_left.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"

# The fake answers what the task asks kcadm. FAKE_PERSON_ID is the id of the user the username query finds, empty for
# none; FAKE_NAMED_CLIENT is "yes" when a service-account client of the username's name exists; FAKE_OWNER_SET is "yes"
# when the agent's account already names the person. The state directory records the sign-in, the removal of its file
# and each read of a client's service account.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
for argument in "${arguments[@]}"; do
  [ "$argument" != --secret ] || { echo "fake kubectl: a secret in the arguments" >&2; exit 1; }
done
case " ${arguments[*]} " in
  *" rm -f -- "*) touch "$FAKE_STATE/config-removed"; exit 0 ;;
  *" bash -c "*"config credentials"*) touch "$FAKE_STATE/signed-in"; exit 0 ;;
esac
for index in "${!arguments[@]}"; do
  [ "${arguments[$index]}" = /opt/keycloak/bin/kcadm.sh ] && break
done
kcadm_arguments=("${arguments[@]:$((index + 1))}")
[ "${kcadm_arguments[-2]}" = --config ] || { echo "fake kubectl: a call without the sign-in file" >&2; exit 1; }
kcadm_arguments="${kcadm_arguments[*]::${#kcadm_arguments[@]}-2}"
case "$kcadm_arguments" in
  "get clients --target-realm "*"--query clientId=someone "*)
    if [ "$FAKE_NAMED_CLIENT" = yes ]; then echo '[{"id": "named-client-id", "serviceAccountsEnabled": true}]'; else echo '[]'; fi ;;
  "get clients --target-realm "*"--query clientId="*) echo agent-client-id ;;
  "get clients/named-client-id/service-account-user "*) touch "$FAKE_STATE/account-read"; echo agent-account-id ;;
  "get clients/agent-client-id/service-account-user "*) echo agent-account-id ;;
  "get users --target-realm "*"exact=true"*)
    if [ -z "$FAKE_PERSON_ID" ]; then echo '[]'
    else echo "[{\"id\": \"$FAKE_PERSON_ID\", \"username\": \"service-account-someone\"}]"; fi ;;
  "get users/agent-account-id "*)
    if [ "$FAKE_OWNER_SET" = yes ]; then echo '{"id": "agent-account-id", "attributes": {"agent_owner": ["person-id"]}}'
    else echo '{"id": "agent-account-id", "attributes": {}}'; fi ;;
  "update users/agent-account-id "*) cat >"$FAKE_STATE/owner-written" ;;
  "get group-by-path/agent-owners "*) echo owners-group-id ;;
  "get users/person-id/groups "*) ;;
  "update users/person-id/groups/owners-group-id "*) exit 1 ;;
  *) echo "fake kubectl: unexpected $kcadm_arguments" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/kubectl"
# mise puts its own kubectl before PATH and the task falls back to the PC's kubeconfig, so neither may be reachable.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
[ "$(command -v kubectl)" = "$fake_bin/kubectl" ] || fail "kubectl on PATH is not the fake"

# run_task <case name> <person id> <named client: yes|no> <owner set: yes|no>: runs the task for a username that starts
# like a service account's and sets status, output_file and FAKE_STATE.
run_task() {
  export FAKE_STATE="$work_directory/state-$1" FAKE_PERSON_ID="$2" FAKE_NAMED_CLIENT="$3" FAKE_OWNER_SET="$4"
  mkdir "$FAKE_STATE"
  output_file="$work_directory/output-$1"
  status=0
  (cd "$repository_root" && mise run keycloak:agent-owner agent-mozart service-account-someone) >"$output_file" 2>&1 || status=$?
  [ -e "$FAKE_STATE/signed-in" ] || { show_output; fail "$1: the task never signed in"; }
  [ -e "$FAKE_STATE/config-removed" ] || { show_output; fail "$1: the sign-in file was not removed"; }
}
show_output() { sed 's/^/  /' "$output_file" >&2; }

run_task unknown-user "" yes no
[ "$status" != 0 ] || { show_output; fail "an unknown username exited 0"; }
grep --quiet 'is not exactly one user of .*nothing changed' "$output_file" ||
  { show_output; fail "an unknown username was not refused with nothing changed"; }
[ ! -e "$FAKE_STATE/account-read" ] || fail "an unknown username was refused only after a client's service account was read"
echo "an unknown username is refused before any service account is read"

run_task service-account agent-account-id yes no
[ "$status" != 0 ] || { show_output; fail "a client's service account was taken as owner"; }
grep --quiet 'is a service account, not a person; nothing changed' "$output_file" ||
  { show_output; fail "a refusal before any write did not name the service account and say nothing changed"; }
[ ! -e "$FAKE_STATE/owner-written" ] || fail "a refused service account changed agent_owner"
echo "a client's service account is refused before any write, nothing changed"

run_task person person-id no no
[ "$status" != 0 ] || { show_output; fail "a failing membership write exited 0"; }
[ -e "$FAKE_STATE/owner-written" ] || { show_output; fail "a person named like a service account was not taken as owner"; }
[ ! -e "$FAKE_STATE/account-read" ] || fail "a name that no client carries led to a client's service account being read"
if grep --quiet 'nothing changed' "$output_file"; then show_output; fail "a failure after the owner write claims nothing changed"; fi
grep --quiet 'agent_owner of agent-mozart.*run again to complete it' "$output_file" || { show_output; fail "the failure names no written agent_owner and no way back"; }
echo "a failure after the owner write names what was written and that running again completes it"

run_task owner-already-set person-id no yes
[ "$status" != 0 ] || { show_output; fail "a failing membership write exited 0 with the owner set"; }
[ ! -e "$FAKE_STATE/owner-written" ] || fail "an owner that was already set was written again"
if grep --quiet 'nothing changed' "$output_file"; then show_output; fail "a failed membership write claims nothing changed"; fi
grep --quiet 'written or possibly written: service-account-someone in /agent-owners; run again to complete it' "$output_file" ||
  { show_output; fail "the failed membership write is not named"; }
echo "a failed membership write with the owner already set names the membership and that running again completes it"
