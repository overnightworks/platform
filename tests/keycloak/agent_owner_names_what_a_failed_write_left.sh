#!/usr/bin/env bash
# Drive `mise run keycloak:agent-owner` against a fake kubectl whose kcadm answers from fixed data, for the outcomes the
# cluster cannot arrange: a name no person carries, a service account's name (in any case) and a name that only
# another user's email carries are refused with nothing changed, a person whose username starts like a service
# account's is taken, the secret stands in no argument and the sign-in file goes on every exit, and a membership write
# that fails names what was written (after the owner's write or alone) and does not claim that nothing changed, and a
# line its caller wrote to the same file before the task survives.
# Usage: mise exec -- tests/keycloak/agent_owner_names_what_a_failed_write_left.sh
# Proves docs/commands.md OWNER-2.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"

# The fake answers what the task asks kcadm. Its user search behaves like Keycloak's: a quoted value matches a username
# or an email exactly, case-insensitively, and a service account never answers. FAKE_OWNER_SET is "yes" when the
# agent's account already names the person. The state directory records the sign-in and the removal of its file.
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
  "get clients --target-realm "*"--query clientId="*) echo agent-client-id ;;
  "get clients/agent-client-id/service-account-user "*) echo agent-account-id ;;
  "get users --target-realm "*"--query search="*)
    searched="$(sed -n 's/.*--query search="\([^"]*\)".*/\1/p' <<<"$kcadm_arguments")"
    searched="${searched,,}"
    found=()
    if [[ "$kcadm_arguments" == *"--offset 0 "* ]]; then
      while IFS='|' read -r id username is_service_account email; do
        [ "$is_service_account" = no ] || continue
        if [ "$username" = "$searched" ] || [ "$email" = "$searched" ]; then found+=("{\"id\": \"$id\", \"username\": \"$username\"}"); fi
      done <<'USERS'
person-id|service-account-someone|no|
agent-account-id|service-account-agent-mozart|yes|
other-person-id|other|no|ghost
USERS
    fi
    echo "[$(IFS=,; echo "${found[*]}")]" ;;
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

# run_task <case name> <username> <owner set: yes|no>: runs the task and sets status, output_file and FAKE_STATE.
run_task() {
  export FAKE_STATE="$work_directory/state-$1" FAKE_OWNER_SET="$3"
  mkdir "$FAKE_STATE"
  output_file="$work_directory/output-$1"
  status=0
  { echo "line before the task"; (cd "$repository_root" && mise run keycloak:agent-owner agent-mozart "$2") || status=$?; } \
    >"$output_file" 2>&1
  [ "$(head -n 1 "$output_file")" = "line before the task" ] ||
    { show_output; fail "$1: the task overwrote what its caller had written to the same file"; }
  [ -e "$FAKE_STATE/signed-in" ] || { show_output; fail "$1: the task never signed in"; }
  [ -e "$FAKE_STATE/config-removed" ] || { show_output; fail "$1: the sign-in file was not removed"; }
}
show_output() { sed 's/^/  /' "$output_file" >&2; }

# refused_unchanged <case name> <username> <what it is>: the task refuses before any write.
refused_unchanged() {
  run_task "$1" "$2" no
  [ "$status" != 0 ] || { show_output; fail "$3 exited 0"; }
  grep --quiet 'no person named .*nothing changed' "$output_file" ||
    { show_output; fail "$3 was not refused as no person with nothing changed"; }
  [ ! -e "$FAKE_STATE/owner-written" ] || fail "$3 changed agent_owner"
  echo "$3 is refused before any write, nothing changed"
}
refused_unchanged unknown-user nobody "an unknown username"
refused_unchanged email-only ghost "a name only another user's email carries"
refused_unchanged service-account service-account-agent-mozart "a service account"
refused_unchanged service-account-upper SERVICE-ACCOUNT-AGENT-MOZART "a service account in upper case"

run_task person service-account-someone no
[ "$status" != 0 ] || { show_output; fail "a failing membership write exited 0"; }
[ -e "$FAKE_STATE/owner-written" ] || { show_output; fail "a person named like a service account was not taken as owner"; }
if grep --quiet 'nothing changed' "$output_file"; then show_output; fail "a failure after the owner write claims nothing changed"; fi
grep --quiet 'agent_owner of agent-mozart.*run again to complete it' "$output_file" || { show_output; fail "the failure names no written agent_owner and no way back"; }
echo "a failure after the owner write names what was written and that running again completes it"

run_task owner-already-set service-account-someone yes
[ "$status" != 0 ] || { show_output; fail "a failing membership write exited 0 with the owner set"; }
[ ! -e "$FAKE_STATE/owner-written" ] || fail "an owner that was already set was written again"
if grep --quiet 'nothing changed' "$output_file"; then show_output; fail "a failed membership write claims nothing changed"; fi
grep --quiet 'written or possibly written: service-account-someone in /agent-owners; run again to complete it' "$output_file" ||
  { show_output; fail "the failed membership write is not named"; }
echo "a failed membership write with the owner already set names the membership and that running again completes it"
