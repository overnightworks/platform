#!/usr/bin/env bash
# Drive `mise run live:check hopin` against a fake kubectl, whose kcadm answers from a small model of the realm's test
# person, and a fake curl, which models hopin's sign-in routes and Keycloak's login form, for what the live stack cannot
# arrange: that the per-run password stands in no argument, no output, no child's environment and no file of the run's
# runtime and temporary directories, and reaches kcadm and curl on stdin only; that no cookie or code is printed; that
# the enable write clears the required actions and the brute-force clear comes before the sign-in; that a success, a
# red sign-in, a TERM during the sign-in, a failed write and a kcadm whose sign-in file is gone each end with the person
# signed out, its credentials deleted and the person disabled, read back; that a failing hopin sign-out or credential
# delete does not stop the steps after it and is named; that an undeclared person, a held lock and a Deployment that is
# not Available are refused or skipped with no write; and that what an untrapped earlier run left is cleaned up first.
# Usage: mise exec -- tests/keycloak/live_check_leaves_the_person_disabled_on_every_exit.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
realm_file="$repository_root/infrastructure/keycloak/realm.yaml"
realm="$(yq '.realm' "$realm_file")"
person="$(yq '.users[] | select(.serviceAccountClientId == null) | .username' "$realm_file")"
app_origin="$(yq '.clients[] | select(.clientId == "hopin") | .baseUrl' "$realm_file")"
app_origin="${app_origin%/}"
callback_url="$(yq '.clients[] | select(.clientId == "hopin") | .redirectUris[0]' "$realm_file")"
keycloak_origin=https://auth.example.invalid

# What both fakes share: the event log, the violation file and the scan of their own arguments and environment, which
# holds no 48-digit hex string (the password's shape) and not the password once the realm model has recorded it.
cat >"$work_directory/fake_lib.sh" <<'FAKE'
log_event() { echo "$1" >>"$FAKE_STATE/log"; }
violate() { echo "$1" >>"$FAKE_STATE/violation"; }
scan_arguments_and_environment() {
  local name="$1" known="" shape='(^|[^0-9a-f])[0-9a-f]{48}($|[^0-9a-f])'
  shift
  [ ! -s "$FAKE_STATE/password" ] || known="$(<"$FAKE_STATE/password")"
  if [[ " $* " =~ $shape ]] || { [ -n "$known" ] && [[ "$*" == *"$known"* ]]; }; then violate "$name: a password in an argument"; fi
  if env | grep -Eq "$shape" || { [ -n "$known" ] && env | grep -qF -- "$known"; }; then violate "$name: a password in the environment"; fi
}
FAKE

# The realm model. State files: enabled (true or false), required (the person's required actions as JSON), credentials
# (one id per line), keycloak-session and hopin-session (present while the session exists), signed-in (kcadm's config
# file exists), password (what the reset wrote). FAKE_FAIL names the one write that fails; FAKE_DROP_CONFIG_AT=enable
# removes kcadm's config file after the enable write; FAKE_DEPLOYMENT=unavailable makes hopin's Deployment not Available.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
arguments=("$@")
scan_arguments_and_environment kubectl "$@"
case " ${arguments[*]} " in
  *" get deployment "*)
    log_event "kubectl: deployment read"
    if [ "${FAKE_DEPLOYMENT:-available}" = unavailable ]; then echo False; else echo True; fi
    exit 0 ;;
  *" rm -f -- "*) rm -f "$FAKE_STATE/signed-in"; log_event "kubectl: config-removed"; exit 0 ;;
  *" bash -c "*"config credentials"*) touch "$FAKE_STATE/signed-in"; log_event "kubectl: kcadm-signed-in"; exit 0 ;;
esac
[ -e "$FAKE_STATE/signed-in" ] || { echo "fake kubectl: kcadm has no config" >&2; log_event "kubectl: refused, no config"; exit 1; }
for index in "${!arguments[@]}"; do
  [ "${arguments[$index]}" = /opt/keycloak/bin/kcadm.sh ] && break
done
kcadm_arguments=("${arguments[@]:$((index + 1))}")
[ "${kcadm_arguments[-2]}" = --config ] || { echo "fake kubectl: a call without the sign-in file" >&2; exit 1; }
call="${kcadm_arguments[*]::${#kcadm_arguments[@]}-2}"
state() { cat "$FAKE_STATE/$1"; }
case "$call" in
  "get users --target-realm "*"--query search="*)
    if [[ "$call" == *"--offset 0 "* ]]; then echo '[{"id": "person-id", "username": "'"$FAKE_PERSON"'"}]'; else echo '[]'; fi ;;
  "get users/person-id --target-realm "*)
    echo "{\"id\": \"person-id\", \"username\": \"$FAKE_PERSON\", \"enabled\": $(state enabled), \"requiredActions\": $(state required)}" ;;
  "get users/person-id/credentials "*)
    echo "[$(sed 's/.*/{"id": "&", "type": "password"}/' "$FAKE_STATE/credentials" | paste -sd, -)]" ;;
  "get users/person-id/sessions "*)
    if [ -e "$FAKE_STATE/keycloak-session" ]; then echo '[{"id": "session-id"}]'; else echo '[]'; fi ;;
  "delete attack-detection/brute-force/users/person-id "*) log_event "kubectl: brute-force-cleared" ;;
  "update users/person-id --target-realm "*)
    body="$(cat)"
    [ -z "$(<"$FAKE_STATE/password")" ] || [[ "$body" != *"$(<"$FAKE_STATE/password")"* ]] || violate "kubectl: the password in a write that is no reset"
    enabled="$(yq -p json '.enabled' <<<"$body")"
    if [ "$enabled" = true ]; then
      [ "${FAKE_FAIL:-}" != enable ] || exit 1
      yq -p json -o json -I0 '.requiredActions' <<<"$body" >"$FAKE_STATE/enable-required-actions"
    fi
    echo "$enabled" >"$FAKE_STATE/enabled"
    yq -p json -o json -I0 '.requiredActions' <<<"$body" >"$FAKE_STATE/required"
    log_event "kubectl: write enabled=$enabled"
    if [ "$enabled" = true ] && [ "${FAKE_DROP_CONFIG_AT:-}" = enable ]; then rm -f "$FAKE_STATE/signed-in"; log_event "kubectl: config dropped"; fi ;;
  "update users/person-id/reset-password --target-realm "*)
    body="$(cat)"
    [ "${FAKE_FAIL:-}" != password ] || exit 1
    yq -p json '.value' <<<"$body" >"$FAKE_STATE/password"
    touch "$FAKE_STATE/password-on-kcadm-stdin"
    echo credential-new >"$FAKE_STATE/credentials"
    log_event "kubectl: password-set" ;;
  "delete users/person-id/credentials/"*)
    [ "${FAKE_FAIL:-}" != delete-credential ] || exit 1
    : >"$FAKE_STATE/credentials"
    log_event "kubectl: credential-deleted" ;;
  "create users/person-id/logout "*)
    rm -f "$FAKE_STATE/keycloak-session" "$FAKE_STATE/hopin-session"
    log_event "kubectl: keycloak-logout" ;;
  *) echo "fake kubectl: unexpected $call" >&2; exit 1 ;;
esac
FAKE

# hopin's routes and Keycloak's login form. The form accepts the password the realm model recorded and only for an
# enabled person with a credential and no required action; FAKE_SIGNIN=refused makes it answer the page again;
# FAKE_LOGOUT_STATUS sets hopin's sign-out answer; FAKE_TERM_AT=login-page sends TERM to the command's own process, through
# the timeout that runs it, while this request is open.
cat >"$fake_bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
scan_arguments_and_environment curl "$@"
format="" jar="" url="" origin_header="" data_given=false password_stdin=false
while [ $# -gt 0 ]; do
  case "$1" in
    --silent | --show-error) ;;
    --max-time | --output | --cookie) shift ;;
    --write-out) format="$2"; shift ;;
    --cookie-jar) jar="$2"; shift ;;
    --config) url="$(sed -n 's/^url = "\(.*\)"$/\1/p' "$2")"; shift ;;
    --header) origin_header="$2"; shift ;;
    --data) data_given=true; shift ;;
    --data-urlencode) [ "$2" != password@- ] || password_stdin=true; data_given=true; shift ;;
    *) echo "fake curl: unexpected argument" >&2; exit 1 ;;
  esac
  shift
done
code="" redirect="" body=""
jar_has_session() { [ -s "$jar" ] && grep -q "$FAKE_COOKIE_VALUE" "$jar"; }
# terminate_command: TERM to the command's own process, the topmost ancestor below the timeout that caps it (the
# ancestors between are the command's subshells).
terminate_command() {
  local pid=$PPID command_pid="" capped=false
  while [ "$pid" -gt 1 ]; do
    case "$(ps -o args= -p "$pid")" in
      timeout*) capped=true; break ;;
      *live_check.sh*) command_pid="$pid" ;;
    esac
    pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
  done
  [ "$capped" = true ] && [ -n "$command_pid" ] || { violate "curl: no command process below a timeout to terminate"; return; }
  kill -TERM "$command_pid"
  sleep 2
}
case "$url" in
  "$FAKE_APP_ORIGIN/auth/start")
    log_event "curl: start"
    code=303 redirect="$FAKE_KEYCLOAK_ORIGIN/realms/$FAKE_REALM/protocol/openid-connect/auth?client_id=hopin&state=fake-state" ;;
  "$FAKE_KEYCLOAK_ORIGIN/realms/$FAKE_REALM/protocol/openid-connect/auth?"*)
    log_event "curl: login page"
    [ "${FAKE_TERM_AT:-}" != login-page ] || terminate_command
    code=200
    body="<html><form action=\"$FAKE_KEYCLOAK_ORIGIN/realms/$FAKE_REALM/login-actions/authenticate?session_code=FAKECODE&amp;execution=1\" method=\"post\"></form></html>" ;;
  "$FAKE_KEYCLOAK_ORIGIN/realms/$FAKE_REALM/login-actions/authenticate?"*)
    log_event "curl: sign-in form"
    [ "$password_stdin" = true ] || violate "curl: the form was posted without the password on stdin"
    posted="$(cat)"
    code=200
    if [ "$posted" = "$(<"$FAKE_STATE/password")" ] && [ "$(<"$FAKE_STATE/enabled")" = true ] && [ -s "$FAKE_STATE/credentials" ] &&
      [ "$(<"$FAKE_STATE/required")" = '[]' ] && [ "${FAKE_SIGNIN:-}" != refused ]; then
      touch "$FAKE_STATE/password-on-curl-stdin" "$FAKE_STATE/keycloak-session"
      code=302 redirect="$FAKE_CALLBACK_URL?code=FAKECODE2&state=fake-state"
    fi ;;
  "$FAKE_CALLBACK_URL?"*)
    log_event "curl: callback"
    touch "$FAKE_STATE/hopin-session"
    printf '%s\n' "$(printf 'hopin\tFALSE\t/\tTRUE\t0\tsession\t%s' "$FAKE_COOKIE_VALUE")" >>"$jar"
    code=303 redirect="$FAKE_APP_ORIGIN/" ;;
  "$FAKE_APP_ORIGIN/api/account")
    log_event "curl: account"
    if [ -e "$FAKE_STATE/hopin-session" ] && jar_has_session; then code=200; else code=401; fi ;;
  "$FAKE_APP_ORIGIN/logout")
    log_event "curl: logout"
    [ "$origin_header" = "Origin: $FAKE_APP_ORIGIN" ] || violate "curl: a sign-out without hopin's own Origin"
    code="${FAKE_LOGOUT_STATUS:-200}"
    if [ "$code" = 200 ]; then rm -f "$FAKE_STATE/hopin-session"; : >"$jar"; fi ;;
  *) echo "fake curl: unexpected request" >&2; exit 1 ;;
esac
format="${format//'%{http_code}'/$code}"
printf '%s%s' "$body" "${format//'%{redirect_url}'/$redirect}"
FAKE
chmod +x "$fake_bin/kubectl" "$fake_bin/curl"
# mise puts its own kubectl before PATH and the command falls back to the PC's kubeconfig, so neither may be reachable.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
for tool in kubectl curl; do
  [ "$(command -v "$tool")" = "$fake_bin/$tool" ] || fail "$tool on PATH is not the fake"
done

# prepare_case <name> [start]: the state of the model before a run: the person as the realm file leaves it, or, for
# start=enabled, as an untrapped run left it (enabled, a credential, both sessions), or, for start=jar, with a cookie jar.
prepare_case() {
  state="$work_directory/state-$1"
  runtime="$work_directory/runtime-$1"
  mkdir "$state" "$work_directory/tmp-$1"
  mkdir -m 700 "$runtime"
  output_file="$work_directory/output-$1"
  echo false >"$state/enabled"
  echo '["TERMS_AND_CONDITIONS"]' >"$state/required"
  : >"$state/credentials"
  : >"$state/password"
  : >"$state/log"
  case "${2:-}" in
    enabled)
      echo true >"$state/enabled"
      echo credential-left >"$state/credentials"
      touch "$state/keycloak-session" "$state/hopin-session" ;;
    jar)
      mkdir -m 700 "$runtime/live-check"
      printf 'hopin\tFALSE\t/\tTRUE\t0\tsession\t%s\n' "$cookie_value" >"$runtime/live-check/cookies"
      touch "$state/hopin-session" ;;
  esac
}
cookie_value=SECRETCOOKIEVALUE
# run_command <name> <environment assignment>...: runs the command; sets status.
run_command() {
  local name="$1"
  shift
  status=0
  (cd "$repository_root" && env XDG_RUNTIME_DIR="$runtime" TMPDIR="$work_directory/tmp-$name" FAKE_STATE="$state" \
    FAKE_LIB="$work_directory/fake_lib.sh" FAKE_PERSON="$person" FAKE_REALM="$realm" FAKE_APP_ORIGIN="$app_origin" \
    FAKE_CALLBACK_URL="$callback_url" FAKE_KEYCLOAK_ORIGIN="$keycloak_origin" FAKE_COOKIE_VALUE="$cookie_value" "$@" \
    mise run live:check hopin) >"$output_file" 2>&1 || status=$?
}
show_output() { sed 's/^/  /' "$output_file" >&2; }
refuse() { show_output; fail "$1"; }
# event_line <pattern>: the line number of the first event that matches.
event_line() { grep -n -m 1 -- "$1" "$state/log" | cut -d: -f1; }
# no_event <pattern>: the log holds no matching event.
no_event() { ! grep -q -- "$1" "$state/log"; }
# in_order <case> <pattern>...: the first event of each pattern comes after the one before.
in_order() {
  local name="$1" earlier=0 line pattern
  shift
  for pattern in "$@"; do
    line="$(event_line "$pattern")"
    [ -n "$line" ] && [ "$line" -gt "$earlier" ] || refuse "$name: '$pattern' is missing or out of order: $(paste -sd'|' "$state/log")"
    earlier="$line"
  done
}
# kept_secret <case>: the password, the cookie and the code stand in no output and no file of the run, and no fake saw
# the password anywhere but stdin.
kept_secret() {
  local name="$1" password
  [ ! -s "$state/violation" ] || refuse "$name: $(paste -sd';' "$state/violation")"
  password="$(<"$state/password")"
  if [ -n "$password" ]; then
    ! grep -rqF -- "$password" "$output_file" "$runtime" "$work_directory/tmp-$name" || refuse "$name: the password is in an output or a file of the run"
    [ "${#password}" = 48 ] || refuse "$name: the password is not 48 hex digits"
  fi
  ! grep -qE "$cookie_value|FAKECODE" "$output_file" || refuse "$name: a cookie or code is in the output"
}
# left_clean <case> [credential]: the person is disabled with no session and, unless a credential is named, no
# credential; the sign-in file is gone, the jar is gone and the last event is its removal.
left_clean() {
  local name="$1"
  [ "$(<"$state/enabled")" = false ] || refuse "$name: the person is enabled"
  [ ! -e "$state/keycloak-session" ] && [ ! -e "$state/hopin-session" ] || refuse "$name: a session remains"
  { [ "${2:-}" = credential ] || [ ! -s "$state/credentials" ]; } || refuse "$name: a credential remains"
  [ ! -e "$state/signed-in" ] || refuse "$name: kcadm's sign-in file remains"
  [ ! -e "$runtime/live-check/cookies" ] || refuse "$name: the cookie jar remains"
  [ "$(tail -n 1 "$state/log")" = "kubectl: config-removed" ] || refuse "$name: the sign-in file was not removed last"
}
expect_result() {
  local name="$1" expected_status="$2" result="$3"
  [ "$status" = "$expected_status" ] || refuse "$name: exit $status, not $expected_status"
  grep -qE "^live:check: hopin $result( |\$)" "$output_file" || refuse "$name: no result line '$result'"
}
# cleanup_order <case>: sign-out at the app, Keycloak's sessions, the credential, the disable, the removal of the file.
cleanup_order() { in_order "$1" 'curl: logout' 'keycloak-logout' 'credential-deleted' 'write enabled=false' 'config-removed'; }

# ---------------------------------------------------------------------------------------------------- a success
prepare_case success
run_command success
expect_result success 0 green
kept_secret success
left_clean success
[ "$(<"$state/enable-required-actions")" = '[]' ] || refuse "success: the enable write left required actions"
[ -e "$state/password-on-kcadm-stdin" ] && [ -e "$state/password-on-curl-stdin" ] || refuse "success: the password did not reach kcadm and the form on stdin"
in_order success 'brute-force-cleared' 'write enabled=true' 'password-set' 'curl: start' 'curl: login page' 'curl: sign-in form' 'curl: callback' 'curl: account'
cleanup_order success
grep -q 'account=200 sign-out=200 account-after=401' "$output_file" || refuse "success: the output holds not the codes of the sign-in and sign-out"
echo "a success signs in on stdin credentials only, clears the required actions, and leaves the person signed out, disabled, with no credential and no file"

# --------------------------------------------------------------------------------- each exit that is not a success
prepare_case red-sign-in
run_command red-sign-in FAKE_SIGNIN=refused
expect_result red-sign-in 1 red
kept_secret red-sign-in
left_clean red-sign-in
cleanup_order red-sign-in
echo "a refused sign-in is red, and the person is signed out and disabled"

prepare_case term-during-sign-in
run_command term-during-sign-in FAKE_TERM_AT=login-page
[ "$status" != 0 ] || refuse "term-during-sign-in: exit 0"
grep -qE '^live:check: hopin red' "$output_file" || refuse "term-during-sign-in: no red result line"
kept_secret term-during-sign-in
left_clean term-during-sign-in
cleanup_order term-during-sign-in
echo "a TERM during the sign-in ends red, and the person is signed out and disabled"

prepare_case failed-password-write
run_command failed-password-write FAKE_FAIL=password
expect_result failed-password-write 1 red
kept_secret failed-password-write
left_clean failed-password-write
in_order failed-password-write 'write enabled=true' 'write enabled=false' 'config-removed'
echo "a failed password write ends red after the enable, and the person is disabled"

prepare_case config-dropped
run_command config-dropped FAKE_DROP_CONFIG_AT=enable
expect_result config-dropped 1 red
kept_secret config-dropped
left_clean config-dropped
[ "$(grep -c 'kcadm-signed-in' "$state/log")" = 2 ] || refuse "config-dropped: kcadm did not sign in again for the cleanup"
echo "a lost kcadm sign-in file is made again for the cleanup, and the person is disabled"

prepare_case hopin-sign-out-fails
run_command hopin-sign-out-fails FAKE_LOGOUT_STATUS=502
[ "$status" = 1 ] || refuse "hopin-sign-out-fails: exit $status, not 1"
grep -q "may remain: .*the person's hopin session" "$output_file" || refuse "hopin-sign-out-fails: the output names no hopin session"
kept_secret hopin-sign-out-fails
left_clean hopin-sign-out-fails
echo "a hopin sign-out that answers 502 is named, and the credential is still deleted and the person disabled"

prepare_case credential-delete-fails
run_command credential-delete-fails FAKE_FAIL=delete-credential
[ "$status" = 1 ] || refuse "credential-delete-fails: exit $status, not 1"
grep -q "may remain: .*the person's password credential" "$output_file" || refuse "credential-delete-fails: the output names no credential"
kept_secret credential-delete-fails
left_clean credential-delete-fails credential
in_order credential-delete-fails 'keycloak-logout' 'write enabled=false' 'config-removed'
echo "a credential that cannot be deleted is named, and the person is still disabled"

# ------------------------------------------------------------------------------- what stops the run before a write
undeclared="$work_directory/realm-without-person.yaml"
yq 'del(.users[] | select(.serviceAccountClientId == null))' "$realm_file" >"$undeclared"
prepare_case undeclared-person enabled
run_command undeclared-person REALM_FILE="$undeclared"
[ "$status" = 1 ] || refuse "undeclared-person: exit $status, not 1"
grep -q "declares no person" "$output_file" || refuse "undeclared-person: the refusal names no missing person"
[ ! -s "$state/log" ] || refuse "undeclared-person: the stack was called: $(paste -sd'|' "$state/log")"
[ "$(<"$state/enabled")" = true ] || refuse "undeclared-person: a person was written"
echo "a person the realm file does not declare is refused before any call"

prepare_case lock-held enabled
mkdir -m 700 "$runtime/live-check"
exec {lock_descriptor}>"$runtime/live-check/lock"
flock --nonblock "$lock_descriptor"
run_command lock-held
exec {lock_descriptor}>&-
[ "$status" = 1 ] || refuse "lock-held: exit $status, not 1"
grep -q "another run holds" "$output_file" || refuse "lock-held: the refusal names no other run"
[ ! -s "$state/log" ] || refuse "lock-held: the stack was called: $(paste -sd'|' "$state/log")"
[ "$(<"$state/enabled")" = true ] || refuse "lock-held: a person was written"
echo "a second run is refused with no call and no write"

prepare_case unavailable
run_command unavailable FAKE_DEPLOYMENT=unavailable
expect_result unavailable 3 skipped
! grep -qE 'write|brute-force|password-set|credential-deleted|keycloak-logout' "$state/log" || refuse "unavailable: a write was made: $(paste -sd'|' "$state/log")"
echo "an app that is not Available is skipped, exit 3, with no write"

prepare_case unavailable-after-heal enabled
run_command unavailable-after-heal FAKE_DEPLOYMENT=unavailable
expect_result unavailable-after-heal 3 skipped
left_clean unavailable-after-heal
for write in 'write enabled=true' 'brute-force' 'password-set'; do
  no_event "$write" || refuse "unavailable-after-heal: a write beyond the heal: $write"
done
echo "an app that is not Available is skipped after the heal, with no write beyond it"

# ----------------------------------------------------------------------------- what an untrapped earlier run left
declare -A first_cleanup_event=([enabled]='keycloak-logout' [jar]='curl: logout')
for start in enabled jar; do
  prepare_case "heal-$start" "$start"
  run_command "heal-$start"
  expect_result "heal-$start" 0 green
  kept_secret "heal-$start"
  left_clean "heal-$start"
  grep -q "leftovers were cleaned up first" "$output_file" || refuse "heal-$start: the output says nothing of the heal"
  in_order "heal-$start" "${first_cleanup_event[$start]}" 'write enabled=false' 'brute-force-cleared' 'write enabled=true' 'curl: callback'
  echo "a person left $start by an earlier run is cleaned up before the new run writes"
done
