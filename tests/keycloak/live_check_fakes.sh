# shellcheck shell=bash
# shellcheck disable=SC2154 # repository_root and the failure helpers belong to the sourcing cell.
# Sourced by the cells that drive `mise run live:check` against fakes: a fake kubectl, whose kcadm answers from a small
# model of the realm's test person, and a fake curl, which models each app's sign-in routes and Keycloak's login form. The
# caller sets repository_root, sources tests/failure.sh and runs its cases with prepare_case and run_command.
work_directory="$(mktemp -d)"
# end_the_fakes: ends the processes the fakes left (a held scope, the drive's straggler) and removes the run's files.
end_the_fakes() {
  jobs -p | xargs -r kill 2>/dev/null || true
  cat "$work_directory"/state-*/straggler 2>/dev/null | xargs -r kill 2>/dev/null || true
  rm -rf "$work_directory"
}
trap end_the_fakes EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
realm_file="$repository_root/infrastructure/keycloak/realm.yaml"
realm="$(yq '.realm' "$realm_file")"
person="$(yq '.users[] | select(.serviceAccountClientId == null) | .username' "$realm_file")"
keycloak_origin=https://auth.example.invalid

# The apps' routes as each app's own code answers them at the release platform runs: start 303, callback 303, sign-out
# POST checked by Origin, the account route 200 signed in and 401 otherwise. Per row: the app, which is its client in
# realm.yaml; where a sign-in starts; the account route; the sign-out; its Deployment; and a page that answers 200 signed
# in or not and so cannot be the account route (-: none).
contracts=(
  # hopin 2026.11.23.2 on webauth v0.45.0: its own routes
  "hopin /auth/start /api/account /logout hopin/hopin -"
  # skat 2026.11.20.1 on webauth v0.42.0: src/skat/web/constants.py:15-55
  "skat /auth/start /api/account /logout skat/skat -"
  # presentator 2026.11.22.1 on webauth v0.42.0: src/presentator/api/auth.py:95-99, preference_api.py:27; /api/session answers 200 signed out
  "presentator /login/oidc /api/account /logout presentator/web /api/session"
  # songmaker 2026.11.23.1 on webauth v0.44.0: src/songmaker_cli/constants.py:178-180; its head (songmaker#3447): the account route is GET /api/auth/me, any non-API path answers the page shell 200
  "songmaker /login/oidc /api/auth/me /auth/logout songmaker/web /auth/me"
)
# One line per app for the fake curl: the app, its origin and callback from its client in realm.yaml, then its contract.
apps_file="$work_directory/apps"
for contract in "${contracts[@]}"; do
  read -r contract_app contract_routes <<<"$contract"
  origin="$(APP="$contract_app" yq '.clients[] | select(.clientId == strenv(APP)) | .baseUrl' "$realm_file")"
  callback="$(APP="$contract_app" yq '.clients[] | select(.clientId == strenv(APP)) | .redirectUris[0]' "$realm_file")"
  echo "$contract_app ${origin%/} $callback $contract_routes" >>"$apps_file"
done

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
  if [ -s "$FAKE_STATE/cookie-values" ]; then
    while read -r known; do
      [[ " $* " != *"$known"* ]] || violate "$name: a cookie value in an argument"
    done <"$FAKE_STATE/cookie-values"
  fi
}
FAKE

# The realm model. State files: enabled (true or false), required (the person's required actions as JSON), credentials
# (one id per line), groups (the person's groups as Keycloak lists them), keycloak-session and session-<app> (present
# while the session exists), signed-in (kcadm's config file exists), password (what the reset wrote). FAKE_FAIL names the one write that fails; FAKE_DROP_CONFIG_AT=enable
# removes kcadm's config file after the enable write and =heal after the first read of the person's sessions;
# FAKE_FAIL=remove-first-config fails every removal of the first config file that is removed;
# FAKE_DEPLOYMENT=unavailable makes the app's Deployment, named by FAKE_DEPLOYMENT_REF, not Available; kcadm's sign-in prints
# its notice on stderr.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
arguments=("$@")
scan_arguments_and_environment kubectl "$@"
case " ${arguments[*]} " in
  *" get deployment "*)
    [[ " ${arguments[*]} " == *" --namespace ${FAKE_DEPLOYMENT_REF%/*} get deployment ${FAKE_DEPLOYMENT_REF#*/} "* ]] ||
      { echo "fake kubectl: no such Deployment" >&2; log_event "kubectl: no such deployment"; exit 1; }
    log_event "kubectl: deployment read"
    if [ "${FAKE_DEPLOYMENT:-available}" = unavailable ]; then echo False; else echo True; fi
    exit 0 ;;
  *" rm -f -- "*)
    if [ "${FAKE_FAIL:-}" = remove-first-config ]; then
      [ -e "$FAKE_STATE/first-config" ] || echo "${arguments[-1]}" >"$FAKE_STATE/first-config"
      if [ "${arguments[-1]}" = "$(<"$FAKE_STATE/first-config")" ]; then log_event "kubectl: config-removal-failed"; exit 1; fi
    fi
    rm -f "$FAKE_STATE/signed-in"; log_event "kubectl: config-removed"; exit 0 ;;
  *" bash -c "*"config credentials"*)
    echo "Logging into http://localhost:8080 as service-account-config-cli of realm master" >&2
    touch "$FAKE_STATE/signed-in"; log_event "kubectl: kcadm-signed-in"; exit 0 ;;
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
  "get users/person-id/groups "*) state groups ;;
  "get users/person-id/credentials "*)
    echo "[$(sed 's/.*/{"id": "&", "type": "password"}/' "$FAKE_STATE/credentials" | paste -sd, -)]" ;;
  "get users/person-id/sessions "*)
    if [ -e "$FAKE_STATE/keycloak-session" ]; then echo '[{"id": "session-id"}]'; else echo '[]'; fi
    if [ "${FAKE_DROP_CONFIG_AT:-}" = heal ] && [ ! -e "$FAKE_STATE/config-dropped" ]; then
      touch "$FAKE_STATE/config-dropped"; rm -f "$FAKE_STATE/signed-in"; log_event "kubectl: config dropped"
    fi ;;
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
    rm -f "$FAKE_STATE/keycloak-session" "$FAKE_STATE"/session-*
    log_event "kubectl: keycloak-logout" ;;
  *) echo "fake kubectl: unexpected $call" >&2; exit 1 ;;
esac
FAKE

# The apps' routes (the lines of FAKE_APPS) and Keycloak's login form. The form accepts the password the realm model
# recorded and only for an enabled person with a credential and no required action; FAKE_SIGNIN=refused makes it answer
# the page again; FAKE_LOGOUT_STATUS sets an app's sign-out answer, which ends the session only when it is 200 unless
# FAKE_LOGOUT_ENDS_SESSION is set and never when FAKE_LOGOUT_KEEPS_SESSION is (the app clears its cookie only);
# FAKE_JAR_GARBAGE=true adds a jar line of the app's host that no cookie format reads; FAKE_TRANSPORT_FAILS=start makes the request to an app's start fail the way curl's
# timeout does (exit 28); FAKE_TERM_AT=login-page sends TERM to the command's own process, through the timeout that runs
# it, while this request is open.
cat >"$fake_bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
scan_arguments_and_environment curl "$@"
format="" jar="" cookie_file="" url="" origin_header="" data_given=false password_stdin=false
while [ $# -gt 0 ]; do
  case "$1" in
    --silent | --show-error) ;;
    --max-time | --output) shift ;;
    --cookie) cookie_file="$2"; shift ;;
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
jar_has_session() { [ -s "$cookie_file" ] && grep -q "$FAKE_COOKIE_VALUE" "$cookie_file"; }
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
}
app_matched=false
while read -r app_name app_origin app_callback app_start app_account app_logout _ app_decoy; do
  case "$url" in "$app_origin"/*) app_matched=true; break ;; esac
done <"$FAKE_APPS"
if [ "$app_matched" = true ]; then
  case "$url" in
    "$app_origin$app_start")
      log_event "curl: start"
      [ "${FAKE_TRANSPORT_FAILS:-}" != start ] || exit 28
      code=303 redirect="$FAKE_KEYCLOAK_ORIGIN/realms/$FAKE_REALM/protocol/openid-connect/auth?client_id=$app_name&state=fake-state" ;;
    "$app_callback?"*)
      log_event "curl: callback"
      touch "$FAKE_STATE/session-$app_name"
      printf '#HttpOnly_%s\tFALSE\t/\tTRUE\t0\tsession\t%s\n%s\tFALSE\t/\tFALSE\t4102444800\ttheme\tdark\n' "${app_origin#*//}" "$FAKE_COOKIE_VALUE" "${app_origin#*//}" >>"$jar"
      [ "${FAKE_JAR_GARBAGE:-}" != true ] || printf '#HttpOnly_%s\tFALSE\t/\tTRUE\t0\tsession\t%s\textra\n' "${app_origin#*//}" "$FAKE_COOKIE_VALUE" >>"$jar"
      code=303 redirect="$app_origin/" ;;
    "$app_origin$app_account")
      log_event "curl: account"
      if [ -e "$FAKE_STATE/session-$app_name" ] && jar_has_session; then code=200; else code=401; fi ;;
    "$app_origin$app_logout")
      if [ -n "$jar" ]; then log_event "curl: logout writable"; else log_event "curl: logout read-only"; fi
      log_event "curl: logout"
      [ "$origin_header" = "Origin: $app_origin" ] || violate "curl: a sign-out without $app_name's own Origin"
      code="${FAKE_LOGOUT_STATUS:-200}"
      if { [ "$code" = 200 ] || [ -n "${FAKE_LOGOUT_ENDS_SESSION:-}" ]; } && [ -z "${FAKE_LOGOUT_KEEPS_SESSION:-}" ]; then rm -f "$FAKE_STATE/session-$app_name"; fi
      if [ "$code" = 200 ] && [ -n "$jar" ]; then : >"$jar"; fi ;;
    "$app_origin$app_decoy") code=200 ;;
    *) echo "fake curl: unexpected request" >&2; exit 1 ;;
  esac
else
  case "$url" in
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
        printf '%s\tFALSE\t/realms/\tTRUE\t0\tKEYCLOAK_SESSION\t%s\n' "${FAKE_KEYCLOAK_ORIGIN#*//}" "$FAKE_KEYCLOAK_COOKIE_VALUE" >>"$jar"
        code=302 redirect="$FAKE_CALLBACK_URL?code=FAKECODE2&state=fake-state"
      fi ;;
    *) echo "fake curl: unexpected request" >&2; exit 1 ;;
  esac
fi
format="${format//'%{http_code}'/$code}"
printf '%s%s' "$body" "${format//'%{redirect_url}'/$redirect}"
FAKE
# The gate and the scope. probe-run runs the command it wraps (its arguments after -k K CAP) and passes a TERM on to it
# once, or, with FAKE_GATE_STATUS, answers that status without running it. systemd-run keeps scope-<unit> (the pid of the
# command it runs) while the command lives; systemctl's stop ends that command and returns when the scope is gone;
# FAKE_FAIL=scope makes the trial scope fail and FAKE_FAIL=manager makes the user manager unreachable. systemctl lists the
# scopes that live as active, an earlier inactive and an earlier failed one, and stops the units it is given;
# FAKE_FAIL=scope-stays leaves each stopped scope listed as deactivating.
cat >"$fake_bin/probe-run" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
scan_arguments_and_environment probe-run "$@"
log_event "probe-run: $*"
[ -z "${FAKE_GATE_STATUS:-}" ] || exit "$FAKE_GATE_STATUS"
[ "$1" = -k ] || { violate "probe-run: no -k K CAP before the command"; exit 2; }
shift 3
status=0
"$@" &
command_pid=$!
trap 'log_event "probe-run: term"; kill -TERM "$command_pid" 2>/dev/null || true' TERM INT
wait "$command_pid" || status=$?
while kill -0 "$command_pid" 2>/dev/null; do wait "$command_pid" && status=0 || status=$?; done
exit "$status"
FAKE
cat >"$fake_bin/systemd-run" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
scan_arguments_and_environment systemd-run "$@"
unit="" property=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user | --scope | --quiet | --collect) ;;
    --unit) unit="$2"; shift ;;
    --property) property="$2"; shift ;;
    --) shift; break ;;
    *) violate "systemd-run: unexpected argument"; exit 2 ;;
  esac
  shift
done
if [ -z "$unit" ]; then
  log_event "systemd-run: trial"
  [ "${FAKE_FAIL:-}" != scope ] || exit 1
  exec "$@"
fi
log_event "systemd-run: scope $unit $property"
trap 'rm -f "$FAKE_STATE/scope-$unit"' EXIT
status=0
"$@" &
echo $! >"$FAKE_STATE/scope-$unit"
wait $! || status=$?
# The command has ended and the scope lives while any process is in it, which a watcher outlives this call to say.
if [ -e "$FAKE_STATE/straggler" ] && kill -0 "$(<"$FAKE_STATE/straggler")" 2>/dev/null; then
  trap - EXIT
  (
    while kill -0 "$(<"$FAKE_STATE/straggler")" 2>/dev/null; do sleep 0.05; done
    rm -f "$FAKE_STATE/scope-$unit"
  ) >/dev/null 2>&1 &
fi
exit "$status"
FAKE
cat >"$fake_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
[ "$1" = --user ] || { violate "systemctl: not the user manager"; exit 1; }
case "$2" in
  list-units)
    log_event "systemctl: list"
    [ "${FAKE_FAIL:-}" != manager ] || { echo "Failed to connect to user scope bus" >&2; exit 1; }
    for scope_file in "$FAKE_STATE"/scope-live-check-journeys-*; do
      [ -e "$scope_file" ] || continue
      printf '%s.scope loaded active running Scope\n' "${scope_file##*/scope-}"
    done
    for stuck_file in "$FAKE_STATE"/stuck-live-check-journeys-*; do
      [ -e "$stuck_file" ] || continue
      printf '%s.scope loaded deactivating stop-sigterm Scope\n' "${stuck_file##*/stuck-}"
    done
    printf 'live-check-journeys-earlier.scope loaded inactive dead Scope\n'
    printf 'live-check-journeys-failed.scope loaded failed failed Scope\n' ;;
  stop)
    for unit in "${@:3}"; do
      unit="${unit%.scope}"
      file=absent
      ! compgen -G "$XDG_RUNTIME_DIR/live-check/storage-state-*" >/dev/null || file=present
      log_event "systemctl: stop $unit file=$file"
      if [ -e "$FAKE_STATE/scope-$unit" ]; then
        kill -TERM "$(<"$FAKE_STATE/scope-$unit")" 2>/dev/null || true
        [ ! -e "$FAKE_STATE/straggler" ] || kill -TERM "$(<"$FAKE_STATE/straggler")" 2>/dev/null || true
        for _ in $(seq 200); do [ -e "$FAKE_STATE/scope-$unit" ] || break; sleep 0.05; done
        [ "${FAKE_FAIL:-}" != scope-stays ] || touch "$FAKE_STATE/stuck-$unit"
      fi
    done ;;
  *) violate "systemctl: unexpected $2"; exit 1 ;;
esac
FAKE
# mise: `mise -C <checkout> ...` is the app's own mise, run by the command under env -i, which holds no FAKE_ variable,
# so it finds the case through the state-current link. `tasks ls` lists the checkout's mise.toml; `run live:journeys`
# is the drive, which records what it received, leaves one process behind in its scope and then ends as the case's drive-mode file says: exit:<n>, or
# signal:<name>:<outer|inner>, which sends that signal to the outermost or innermost live_check.sh above it and holds
# until the scope's stop ends it. Every other call is the real mise's.
cat >"$fake_bin/mise" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = -C ] || exec "__REAL_MISE__" "$@"
export FAKE_STATE
FAKE_STATE="$(readlink -f "__WORK__/state-current")"
source "__WORK__/fake_lib.sh"
checkout="$2"
shift 2
for name in KUBECONFIG XDG_RUNTIME_DIR; do
  [ -z "${!name:-}" ] || violate "mise: $name reaches the app's command"
done
if env | grep -q '^MISE_'; then violate "mise: a mise variable reaches the app's command"; fi
case "$*" in
  "tasks ls --name-only")
    log_event "mise: tasks of the checkout"
    "__YQ__" -p toml '.tasks // {} | keys | .[]' "$checkout/mise.toml" ;;
  "run live:journeys --origin "*" --storage-state "*)
    scan_arguments_and_environment drive "$@"
    origin="$4" state_file="$6"
    log_event "drive: started"
    # What the app's command prints stays out of the command's output.
    echo "the drive printed this"; echo "the drive printed this" >&2
    password="$(<"$FAKE_STATE/password")"
    ! grep -rqF -- "$password" "${state_file%/*}" || violate "drive: the password stands in a file of the run"
    {
      echo "origin $origin"
      echo "checkout $checkout"
      echo "environment $(tr '\0' '\n' </proc/$$/environ | cut -d= -f1 | sort | paste -sd' ' -)"
      echo "path $PATH"
      echo "mode $(stat -c %a "$state_file")"
      echo "cookies $("__YQ__" -p json '.cookies[] | [.name, .domain, .path, .expires, .httpOnly, .secure, .sameSite] | join(",")' "$state_file" | paste -sd' ' -)"
      echo "origins $("__YQ__" -p json '.origins | length' "$state_file")"
      echo "jar $(cut -f1 "${state_file%/*}"/cookies-* | paste -sd' ' -)"
      for descriptor in /proc/$$/fd/*; do
        [ "$(readlink "$descriptor")" != "${state_file%/*}/lock" ] || echo "lock inherited"
      done
    } >"$FAKE_STATE/drive-record"
    # A process the drive leaves behind in its scope, as a browser would.
    sleep 600 >/dev/null 2>&1 &
    echo $! >"$FAKE_STATE/straggler"
    mode="$(<"$FAKE_STATE/drive-mode")"
    case "$mode" in
      exit:*) exit "${mode#exit:}" ;;
    esac
    pid=$PPID outer="" inner=""
    while [ "$pid" -gt 1 ]; do
      arguments="$(ps -o args= -p "$pid")"
      if [[ "$arguments" =~ ^[^\ ]*bash\ [^\ ]*live_check\.sh\  ]]; then
        if [[ "$arguments" == *" inside-gate" ]]; then inner="$pid"; else outer="$pid"; fi
      fi
      pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
    done
    sleep 600 &
    sleeper=$!
    trap 'kill "$sleeper" 2>/dev/null; log_event "drive: terminated"; exit 143' TERM
    case "$mode" in
      signal:*:outer) IFS=: read -r _ signal _ <<<"$mode"; kill -"$signal" "$outer" ;;
      signal:*:inner) IFS=: read -r _ signal _ <<<"$mode"; kill -"$signal" "$inner" ;;
    esac
    wait "$sleeper" ;;
  *) violate "mise: unexpected call $*"; exit 1 ;;
esac
FAKE
sed -i "s|__WORK__|$work_directory|g; s|__REAL_MISE__|$(command -v mise)|; s|__YQ__|$(command -v yq)|g" "$fake_bin/mise"
chmod +x "$fake_bin"/*
# mise puts its own kubectl before PATH and the command falls back to the PC's kubeconfig, so neither may be reachable.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
for tool in kubectl curl probe-run systemd-run systemctl mise; do
  [ "$(command -v "$tool")" = "$fake_bin/$tool" ] || fail "$tool on PATH is not the fake"
done

# prepare_case <name> [start]: the state of the model before a run: the person as the realm file leaves it, or, for
# start=enabled, as an untrapped run left it (enabled, a credential, both sessions), or, for start=jar:<app>, with that
# app's cookie jar and session.
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
  printf '%s\n%s\n' "$cookie_value" "$keycloak_cookie_value" >"$state/cookie-values"
  echo exit:0 >"$state/drive-mode"
  ln -sfn "$state" "$work_directory/state-current"
  PERSON="$person" yq --output-format json --indent 0 '[(.users[] | select(.username == strenv(PERSON)) | .groups[]) | {"path": .}]' \
    "$realm_file" >"$state/groups"
  case "${2:-}" in
    enabled)
      echo true >"$state/enabled"
      echo credential-left >"$state/credentials"
      touch "$state/keycloak-session" "$state/session-$checked_app" ;;
    jar:*)
      mkdir -m 700 "$runtime/live-check"
      printf '#HttpOnly_%s\tFALSE\t/\tTRUE\t0\tsession\t%s\n' "$(app_host "${2#jar:}")" "$cookie_value" >"$runtime/live-check/cookies-${2#jar:}"
      touch "$state/session-${2#jar:}" ;;
  esac
}
cookie_value=SECRETCOOKIEVALUE
keycloak_cookie_value=KEYCLOAKCOOKIEVALUE
# app_host <app>: the host of the app's origin, which is the domain of its cookies.
app_host() { awk -v wanted="$1" '$1 == wanted { sub(/^https?:\/\//, "", $2); print $2 }' "$apps_file"; }
# The app the command checks, its argument; empty is no argument.
checked_app=hopin
# The arguments after the app: --tier and --checkout for a journeys run.
live_check_arguments=()
# run_command <name> <environment assignment>...: runs the command for checked_app; sets status.
run_command() {
  local name="$1" callback deployment
  shift
  # An app the table does not hold (no argument, an unknown one) has no callback or Deployment.
  read -r callback deployment < <(awk -v wanted="$checked_app" '$1 == wanted { print $3, $7 }' "$apps_file") || true
  status=0
  (cd "$repository_root" && env XDG_RUNTIME_DIR="$runtime" TMPDIR="$work_directory/tmp-$name" FAKE_STATE="$state" \
    FAKE_LIB="$work_directory/fake_lib.sh" FAKE_PERSON="$person" FAKE_REALM="$realm" FAKE_APPS="$apps_file" \
    FAKE_CALLBACK_URL="$callback" FAKE_DEPLOYMENT_REF="$deployment" FAKE_KEYCLOAK_ORIGIN="$keycloak_origin" \
    FAKE_COOKIE_VALUE="$cookie_value" FAKE_KEYCLOAK_COOKIE_VALUE="$keycloak_cookie_value" "$@" \
    mise run live:check ${checked_app:+"$checked_app"} "${live_check_arguments[@]}") >"$output_file" 2>&1 || status=$?
}
show_output() { sed 's/^/  /' "$output_file" >&2; }
refuse() { show_output; fail "$1"; }
# event_line <pattern>: the line number of the first event that matches.
event_line() { grep -n -m 1 -- "$1" "$state/log" | cut -d: -f1 || true; }
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
  ! grep -qE "$cookie_value|$keycloak_cookie_value|FAKECODE" "$output_file" || refuse "$name: a cookie or code is in the output"
  ! grep -q "Logging into" "$output_file" || refuse "$name: kcadm's sign-in notice is in the output"
}
# left_clean <case> [credential]: the person is disabled with no session and, unless a credential is named, no
# credential; the sign-in file is gone, no app's jar is left and the last event is its removal.
left_clean() {
  local name="$1"
  [ "$(<"$state/enabled")" = false ] || refuse "$name: the person is enabled"
  ! compgen -G "$state/session-*" >/dev/null && [ ! -e "$state/keycloak-session" ] || refuse "$name: a session remains"
  { [ "${2:-}" = credential ] || [ ! -s "$state/credentials" ]; } || refuse "$name: a credential remains"
  [ ! -e "$state/signed-in" ] || refuse "$name: kcadm's sign-in file remains"
  ! compgen -G "$runtime/live-check/cookies-*" >/dev/null || refuse "$name: a cookie jar remains"
  ! compgen -G "$runtime/live-check/storage-state-*" >/dev/null || refuse "$name: a storage state remains"
  ! compgen -G "$runtime/live-check/handed-over-*" >/dev/null || refuse "$name: a handed-over marker remains"
  ! compgen -G "$state/scope-*" >/dev/null || refuse "$name: a scope remains"
  [ "$(tail -n 1 "$state/log")" = "kubectl: config-removed" ] || refuse "$name: the sign-in file was not removed last"
}
expect_result() {
  local name="$1" expected_status="$2" result="$3"
  [ "$status" = "$expected_status" ] || refuse "$name: exit $status, not $expected_status"
  grep -qE "^live:check: $checked_app $result( |\$)" "$output_file" || refuse "$name: no result line '$result'"
}
# cleanup_order <case>: sign-out at the app, Keycloak's sessions, the credential, the disable, the removal of the file.
cleanup_order() { in_order "$1" 'curl: logout' 'keycloak-logout' 'credential-deleted' 'write enabled=false' 'config-removed'; }
