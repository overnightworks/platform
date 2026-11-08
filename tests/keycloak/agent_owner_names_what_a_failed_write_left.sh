#!/usr/bin/env bash
# Drive `mise run keycloak:agent-owner` against a fake kubectl whose kcadm answers from fixed data, for the outcomes the
# cluster cannot arrange: a person whose username starts like a service account's is taken, a client's service account
# is refused as owner with nothing changed, and a membership write that fails after the owner's write names what was
# written and does not claim that nothing changed.
# Usage: mise exec -- tests/keycloak/agent_owner_names_what_a_failed_write_left.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"

# The fake answers what the task asks kcadm; FAKE_PERSON_ID is the id of the user the username query finds.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
for index in "${!arguments[@]}"; do
  [ "${arguments[$index]}" = kcadm ] && break
done
kcadm_arguments="${arguments[*]:$((index + 1))}"
case "$kcadm_arguments" in
  "get clients --target-realm "*"--query clientId="*) echo agent-client-id ;;
  "get clients --target-realm "*"--fields id,serviceAccountsEnabled"*)
    echo '[{"id": "agent-client-id", "serviceAccountsEnabled": true}, {"id": "other-client-id", "serviceAccountsEnabled": false}]' ;;
  "get clients/agent-client-id/service-account-user "*) echo agent-account-id ;;
  "get users --target-realm "*"exact=true"*)
    echo "[{\"id\": \"$FAKE_PERSON_ID\", \"username\": \"service-account-someone\"}]" ;;
  "get users/agent-account-id "*) echo '{"id": "agent-account-id", "attributes": {}}' ;;
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

# run_task <person id>: runs the task for a person named like a service account and sets status, output_file and
# whether the fake saw an owner write.
run_task() {
  export FAKE_PERSON_ID="$1" FAKE_STATE="$work_directory/state-$1"
  mkdir "$FAKE_STATE"
  output_file="$work_directory/output-$1"
  status=0
  (cd "$repository_root" && mise run keycloak:agent-owner agent-mozart service-account-someone) >"$output_file" 2>&1 || status=$?
}
show_output() { sed 's/^/  /' "$output_file" >&2; }

run_task agent-account-id
[ "$status" != 0 ] || { show_output; fail "a client's service account was taken as owner"; }
grep --quiet 'is a service account, not a person; nothing changed' "$output_file" ||
  { show_output; fail "a refusal before any write did not name the service account and say nothing changed"; }
[ ! -e "$FAKE_STATE/owner-written" ] || fail "a refused service account changed agent_owner"
echo "a client's service account is refused before any write, nothing changed"

run_task person-id
[ "$status" != 0 ] || { show_output; fail "a failing membership write exited 0"; }
[ -e "$FAKE_STATE/owner-written" ] || { show_output; fail "a person named like a service account was not taken as owner"; }
if grep --quiet 'nothing changed' "$output_file"; then show_output; fail "a failure after the owner write claims nothing changed"; fi
grep --quiet 'agent_owner of agent-mozart.*run again to complete it' "$output_file" || { show_output; fail "the failure names no written agent_owner and no way back"; }
echo "a failure after the owner write names what was written and that running again completes it"
