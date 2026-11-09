#!/usr/bin/env bash
# Drive `mise run litellm:admin` against a fake kubectl, kcadm and curl, for the outcomes a cluster cannot arrange: a
# missing argument is refused before any call; a run on nothing writes the budget, the membership and the customer row
# in that order, and a second run sends no write and prints unchanged; a failure and a lost answer at each of the five
# writes, and a failed read-back after each of three, name what was written or may have been and never claim that
# nothing changed, a customer row that cannot be read before the first write stops the run with nothing written, and running again completes the work without resetting a customer's spend; an INT or a TERM after an
# attempted write names it and exits non-zero; and no output holds the person's id, the fingerprint, a key or a reply
# body.
# Usage: mise exec -- tests/litellm/admin_names_what_a_failed_write_may_have_left.sh
# Proves docs/commands.md ADMIN-1, ADMIN-2, ADMIN-3.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
master_key=sk-fake-master-key-0001
reply_body=REPLY-BODY-THAT-MUST-NOT-APPEAR
person_id=11111111-2222-3333-4444-555555555555
issuer=https://fake.example/realms/hallucinai

# The fake answers what the command reads from the cluster and from Keycloak's kcadm. Every call is recorded in
# FAKE_STATE/calls, and every write in FAKE_STATE/writes.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
echo "kubectl" >>"$FAKE_STATE/calls"
case " ${arguments[*]} " in
  *" sk-"*) echo "fake kubectl: a key in the arguments" >&2; exit 1 ;;
  *" rm -f -- "*) touch "$FAKE_STATE/config-removed"; exit 0 ;;
  *" bash -c "*"config credentials"*) exit 0 ;;
  *"get secret litellm "*) printf '%s' "$FAKE_MASTER_KEY" | base64 --wrap=0; exit 0 ;;
  *"get service litellm "*) printf 4000; exit 0 ;;
  *"port-forward service/litellm "*) echo "Forwarding from 127.0.0.1:4000 -> 4000"; exec sleep 600 ;;
  *"port-forward service/keycloak "*) echo "Forwarding from 127.0.0.1:8080 -> 8080"; exec sleep 600 ;;
esac
for index in "${!arguments[@]}"; do
  [ "${arguments[$index]}" = /opt/keycloak/bin/kcadm.sh ] && break
done
kcadm_arguments="${arguments[*]:$((index + 1)):$((${#arguments[@]} - index - 3))}"
case "$kcadm_arguments" in
  "get users --target-realm "*"--query search=\"alice\""*)
    if [[ "$kcadm_arguments" == *"--offset 0 "* ]]; then echo "[{\"id\": \"$FAKE_PERSON_ID\", \"username\": \"alice\"}]"; else echo '[]'; fi ;;
  "get users --target-realm "*) echo '[]' ;;
  "get group-by-path/services/litellm/admin "*) echo admin-group-id ;;
  "get users/$FAKE_PERSON_ID/groups --target-realm "*)
    if [ "${FAKE_READBACK_FAILS-}" = membership ] && [ -f "$FAKE_STATE/member" ]; then exit 1; fi
    if [ -f "$FAKE_STATE/member" ]; then
      case "$kcadm_arguments" in *"--fields path"*) echo /services/litellm/admin ;; *) echo admin-group-id ;; esac
    fi ;;
  "update users/$FAKE_PERSON_ID/groups/admin-group-id "*)
    echo "write membership" >>"$FAKE_STATE/writes"
    if [ "${FAKE_FAILING_WRITE-}" = membership ]; then
      echo "Resource not found for url: http://localhost:8080/admin/realms/hallucinai/users/$FAKE_PERSON_ID/groups/admin-group-id" >&2
      [ -z "${FAKE_TRANSPORT_FAILURE-}" ] || touch "$FAKE_STATE/member"
      exit 1
    fi
    touch "$FAKE_STATE/member" ;;
  *) echo "fake kubectl: unexpected $kcadm_arguments" >&2; exit 1 ;;
esac
FAKE
# The fake LiteLLM keeps the admin budget and the customer row in FAKE_STATE. A write named by FAKE_FAILING_WRITE (a
# path) is answered with 500 and a body, or, with FAKE_TRANSPORT_FAILURE, applied and answered by a lost connection; a
# write named by FAKE_SLOW_WRITE waits for the file FAKE_STATE/release before it is applied. FAKE_READBACK_FAILS names
# the read (budget, membership or customer) that fails once its own write was sent; FAKE_PREWRITE_FAILS=customer fails
# the customer read of a run that wrote nothing yet.
cat >"$fake_bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
path="${url#http://127.0.0.1:}"
port="${path%%/*}"
path="/${path#*/}"
config="$(cat)"
echo "curl $path" >>"$FAKE_STATE/calls"
for argument in "$@"; do
  case "$argument" in *"$FAKE_MASTER_KEY"*) echo "fake curl: the key in the arguments" >&2; exit 1 ;; esac
done
json() { yq --input-format json --output-format json --indent 0 "$@"; }
status=200 reply='{}'
fails_read() { [ "${FAKE_READBACK_FAILS-}" = "$1" ] && grep -q "^write /$1/" "$FAKE_STATE/writes"; }
if [ "$port" = 8080 ]; then
  printf '{"issuer":"%s"}\n' "$FAKE_ISSUER"
  exit 0
fi
case "$config" in *"Bearer $FAKE_MASTER_KEY"*) ;; *) echo "fake curl: no master key on stdin" >&2; exit 1 ;; esac
case "$path" in
  /budget/list)
    reply='[]'
    [ ! -f "$FAKE_STATE/budget.json" ] || reply="[$(cat "$FAKE_STATE/budget.json")]"
    ! fails_read budget || status=500 ;;
  "/customer/info?end_user_id="*)
    if [ ! -f "$FAKE_STATE/customer.json" ]; then status=404
    else reply="$(cat "$FAKE_STATE/customer.json")"; fi
    ! fails_read customer || status=500
    [ "${FAKE_PREWRITE_FAILS-}" != customer ] || [ -s "$FAKE_STATE/writes" ] || status=500 ;;
  /budget/new | /budget/update | /customer/new | /customer/update)
    echo "write $path" >>"$FAKE_STATE/writes"
    data="$(grep '^data = ' <<<"$config")"
    data="${data#data = \"}"
    data="$(sed 's/\\"/"/g; s/\\\\/\\/g' <<<"${data%\"}")"
    failing=false
    [ "${FAKE_FAILING_WRITE-}" != "$path" ] || failing=true
    [ "${FAKE_SLOW_WRITE-}" != "$path" ] || until [ -f "$FAKE_STATE/release" ]; do sleep 0.1; done
    if [ "$failing" = false ] || [ -n "${FAKE_TRANSPORT_FAILURE-}" ]; then
      case "$path" in
        /budget/*)
          [ -f "$FAKE_STATE/budget.json" ] || echo '{}' >"$FAKE_STATE/budget.json"
          json -i ". + $data" "$FAKE_STATE/budget.json" ;;
        /customer/new) echo "{\"spend\":0,\"alias\":null}" | json ". + $data" >"$FAKE_STATE/customer.json" ;;
        /customer/update) json -i ". + $data" "$FAKE_STATE/customer.json" ;;
      esac
    fi
    [ "$failing" = false ] || { [ -z "${FAKE_TRANSPORT_FAILURE-}" ] || exit 28; status=500 reply="$FAKE_REPLY_BODY"; } ;;
  *) echo "fake curl: unexpected $path" >&2; exit 1 ;;
esac
case " $* " in *" --output /dev/null "*) reply="" ;; esac
printf '%s\n%s' "$reply" "$status"
FAKE
chmod +x "$fake_bin/kubectl" "$fake_bin/curl"
# mise puts its own kubectl before PATH and the tasks fall back to the PC's kubeconfig, so neither may be reachable.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
[ "$(command -v kubectl)" = "$fake_bin/kubectl" ] || fail "kubectl on PATH is not the fake"
[ "$(command -v curl)" = "$fake_bin/curl" ] || fail "curl on PATH is not the fake"
export FAKE_MASTER_KEY="$master_key" FAKE_REPLY_BODY="$reply_body" FAKE_PERSON_ID="$person_id" FAKE_ISSUER="$issuer"

# The fingerprint is agent-runtime's recipe, computed here apart from the command.
fingerprint="$(ISS="$issuer" SUB="$person_id" python3 -I -c '
import hashlib, json, os
identity = json.dumps([os.environ["ISS"], os.environ["SUB"]], ensure_ascii=False, separators=(",", ":"))
print("fp-" + hashlib.sha256(identity.encode("utf-8")).hexdigest())')"

# seed <case name> <none|finite-budget|customer>: a fresh fake LiteLLM and Keycloak. finite-budget is an admin budget
# with a limit, a customer on the person budget with spend 3 and an alias, and nothing else.
seed() {
  export FAKE_STATE="$work_directory/state-$1"
  rm -rf "$FAKE_STATE"
  mkdir "$FAKE_STATE"
  : >"$FAKE_STATE/calls"
  : >"$FAKE_STATE/writes"
  case "$2" in
    finite-budget) echo '{"budget_id":"litellm-admin","max_budget":5,"budget_duration":"1d"}' >"$FAKE_STATE/budget.json" ;;
    customer)
      echo '{"budget_id":"litellm-admin","max_budget":null,"budget_duration":"1mo"}' >"$FAKE_STATE/budget.json"
      printf '{"user_id":"%s","spend":3,"alias":"keep","budget_id":"person-monthly"}\n' "$fingerprint" >"$FAKE_STATE/customer.json" ;;
  esac
}
# scan_for_secrets <what> <output>: fails when the output holds the person's id, the fingerprint, a key or a reply body.
scan_for_secrets() {
  local secret
  for secret in "$master_key" "$reply_body" "$person_id" "$fingerprint"; do
    case "$2" in *"$secret"*) fail "the output of $1 holds a key, a reply body, an id or the fingerprint" ;; esac
  done
}
# run_task <expected exit> <task argument>...: runs the task in FAKE_STATE, which must end as expected, and sets status,
# output and writes. No output holds the person's id, the fingerprint, a key or a reply body.
run_task() {
  local expected="$1"
  shift
  status=0
  : >"$FAKE_STATE/writes"
  output="$(cd "$repository_root" && mise run "$@" 2>&1)" || status=$?
  writes="$(cat "$FAKE_STATE/writes")"
  scan_for_secrets "$*" "$output"
  [ "$status" = "$expected" ] || fail "$*: exit $status, not $expected: $output"
}
# completes <case name>: a run without failure ends the work: the budget, the membership and the customer row on it.
completes() {
  unset FAKE_FAILING_WRITE FAKE_TRANSPORT_FAILURE FAKE_READBACK_FAILS FAKE_PREWRITE_FAILS
  run_task 0 litellm:admin alice
  [ -f "$FAKE_STATE/member" ] || fail "$1: the rerun left the person out of the group"
  [ "$(yq --input-format json --output-format yaml '.max_budget // "null"' "$FAKE_STATE/budget.json")" = null ] && [ "$(yq --input-format json --output-format yaml '.budget_duration' "$FAKE_STATE/budget.json")" = 1mo ] ||
    fail "$1: the rerun left the admin budget limited"
  [ "$(yq --input-format json --output-format yaml '.budget_id' "$FAKE_STATE/customer.json")" = litellm-admin ] || fail "$1: the rerun left the customer off the admin budget"
}

seed missing-argument none
run_task 1 litellm:admin
grep -q 'nothing changed$' <<<"$output" || fail "missing-argument: not refused with nothing changed: $output"
[ ! -s "$FAKE_STATE/calls" ] || fail "missing-argument: a call was made: $(cat "$FAKE_STATE/calls")"
echo "a missing argument is refused with nothing changed and no call"

seed fresh none
run_task 0 litellm:admin alice
[ "$writes" = $'write /budget/new\nwrite membership\nwrite /customer/new' ] || fail "fresh: the writes are not budget, membership, customer: $writes"
grep -q '^litellm:admin: alice is in ' <<<"$output" && ! grep -qE 'possibly|run again|nothing changed' <<<"$output" ||
  fail "fresh: a finished run does not say it finished: $output"
[ "$(yq --input-format json --output-format yaml '.user_id' "$FAKE_STATE/customer.json")" = "$fingerprint" ] || fail "fresh: the row is not under agent-runtime's fingerprint"
run_task 0 litellm:admin alice
[ -z "$writes" ] || fail "second run: a write was sent: $writes"
grep -q '^litellm:admin: alice unchanged$' <<<"$output" || fail "second run: no unchanged line: $output"
echo "a run on nothing writes the budget, the membership and the customer row, in that order, and a second sends no write and prints unchanged"

# A customer row that cannot be read before the first write stops the run with nothing written.
seed unreadable-customer none
export FAKE_PREWRITE_FAILS=customer
run_task 1 litellm:admin alice
[ -z "$writes" ] || fail "unreadable customer: a write was sent before the customer was read: $writes"
grep -q 'nothing changed$' <<<"$output" || fail "unreadable customer: not refused with nothing changed: $output"
unset FAKE_PREWRITE_FAILS
echo "a customer row that cannot be read before the first write ends the run with nothing written and nothing changed"

# A failure and a lost answer at each write, each followed by a run that completes the work.
write_cases=(
  'none:/budget/new:budget litellm-admin'
  'finite-budget:/budget/update:budget litellm-admin'
  'none:membership:alice in /services/litellm/admin'
  'none:/customer/new:customer row of alice'
  'customer:/customer/update:customer row of alice'
)
for write_case in "${write_cases[@]}"; do
  IFS=: read -r scenario failing named <<<"$write_case"
  for lost in "" 1; do
    seed "fail-${failing//\//-}-$lost" "$scenario"
    export FAKE_FAILING_WRITE="$failing" FAKE_TRANSPORT_FAILURE="$lost"
    run_task 1 litellm:admin alice
    grep -qF "written or possibly written: " <<<"$output" && grep -qF "$named" <<<"$output" && grep -q 'run again to complete it$' <<<"$output" ||
      fail "$failing lost=$lost: the output does not name the write and the rerun: $output"
    ! grep -q 'nothing changed' <<<"$output" || fail "$failing lost=$lost: a run that wrote claims nothing changed: $output"
    [ "$(tail -n 1 <<<"$writes")" = "write $failing" ] || fail "$failing lost=$lost: a write ran after the failed one: $writes"
    completes "$failing lost=$lost"
    [ "$scenario" != customer ] || {
      [ "$(yq --input-format json --output-format yaml '.spend' "$FAKE_STATE/customer.json")" = 3 ] && [ "$(yq --input-format json --output-format yaml '.alias' "$FAKE_STATE/customer.json")" = keep ] ||
        fail "$failing lost=$lost: the rerun changed the customer's spend or alias"
    }
  done
done
unset FAKE_FAILING_WRITE FAKE_TRANSPORT_FAILURE
echo "a failure and a lost answer at each of the five writes name what may be written, never claim nothing changed, and a rerun completes it with the spend kept"

# A read-back that fails after its own write names that write; the write before it was sent and the next one was not.
readback_cases=(
  'budget:write /budget/new:budget litellm-admin'
  'membership:write membership:alice in /services/litellm/admin'
  'customer:write /customer/new:customer row of alice'
)
for readback_case in "${readback_cases[@]}"; do
  IFS=: read -r readback last_write named <<<"$readback_case"
  seed "readback-$readback" none
  export FAKE_READBACK_FAILS="$readback"
  run_task 1 litellm:admin alice
  grep -qF "written or possibly written: " <<<"$output" && grep -qF "$named" <<<"$output" && ! grep -q 'nothing changed' <<<"$output" ||
    fail "readback $readback: the output does not name what was written: $output"
  [ "$(tail -n 1 <<<"$writes")" = "$last_write" ] || fail "readback $readback: the last write is not '$last_write': $writes"
  completes "readback $readback"
done
unset FAKE_READBACK_FAILS
echo "a failed read-back after the budget, the membership or the customer row names what was written, and a rerun completes it"

# A signal after an attempted write names it and ends non-zero. Python restores the signal's default first, since a
# background job of a script ignores INT.
for signal_name in INT TERM; do
  seed "signal-$signal_name" none
  export FAKE_SLOW_WRITE=/budget/new
  (cd "$repository_root" && python3 -I -c '
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' bash scripts/litellm_keys.sh admin alice) >"$work_directory/signal-output" 2>&1 &
  command_pid=$!
  timeout 60 bash -c 'until [ -s "$0" ]; do sleep 0.2; done' "$FAKE_STATE/writes" || fail "$signal_name: no write was attempted"
  kill "-$signal_name" "$command_pid"
  touch "$FAKE_STATE/release"
  status=0
  wait "$command_pid" || status=$?
  [ "$status" != 0 ] || fail "$signal_name: the command ended 0"
  grep -q 'written or possibly written: budget litellm-admin' "$work_directory/signal-output" ||
    fail "$signal_name: the output does not name the write: $(cat "$work_directory/signal-output")"
  scan_for_secrets "$signal_name" "$(cat "$work_directory/signal-output")"
  unset FAKE_SLOW_WRITE
  completes "signal $signal_name"
done
echo "an INT or a TERM after an attempted write names it and exits non-zero"
