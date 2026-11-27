#!/usr/bin/env bash
# shellcheck disable=SC2154 # person_id and unreadable are set by keycloak_kcadm.sh.
# The command behind `mise run live:check <app> [--tier journeys --checkout <dir>]`: signs the one test person of
# realm.yaml in to the app through the app's own page on the live stack, the way a browser does, and leaves the person
# disabled; the journeys tier (live_check_journeys.sh) also runs the app's live journeys in the middle. Exit 0 is green,
# 1 red (a failed sign-in, an unreadable stack, a refusal, or a step of the cleanup that may have left something), 3
# skipped (the app's Deployment is not Available, or for the journeys tier the load gate's timeout or the app's exit 3),
# 4 refused (another run holds the lock; nothing was read or written). Output is the app, the result and HTTP codes or
# counts, never a password, a cookie, a code or a page.
#
# The password is made per run, lives in this process's memory and reaches Keycloak and the sign-in form on stdin only.
# On every exit the command can trap (success, error, TERM, INT) one EXIT trap signs out at every app whose cookie jar
# exists, ends the person's Keycloak sessions, deletes its password credentials, disables it and reads each back; a step
# that fails does not stop the next, and the run names what may remain. A run that was killed untrapped leaves the person
# enabled: the next run, for any app, finds that first and runs the same cleanup.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
export LC_ALL=C

realm_file="${REALM_FILE:-infrastructure/keycloak/realm.yaml}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# shellcheck disable=SC2034 # keycloak_kcadm.sh names the task in its messages.
task_name=live:check
person=live-check
# Each call of the cluster or the app ends past this bound, as a hung one would hold the cleanup, which mise.toml's
# timeout -k covers with its calls: 15 at most (kcadm's file lost, one credential), the two reads of the journeys scopes
# and their one stop, which is cleanup_seconds (live_check_journeys.sh), the whole budget of one pass. A cleanup pass
# meets at most one cookie jar, of hopin, skat, presentator or songmaker: a run makes its own only after a heal that
# deleted every leftover, and a heal with leftovers ends the run.
call_seconds=20

cleaning=false
healing=false
holds_lock=false
person_touched=false
skipped=false
refused=false
# The step of the sign-in under way, named on a red result line when it did not finish: start, login-page,
# sign-in-form, callback, account or sign-out. A red without one failed at Keycloak or the stack.
sign_in_step=""
leftovers=()
# The sign-in files of kcadm that could not be removed when kcadm signed in again; every pass of the cleanup retries them.
stranded_config_files=()
codes=()
# fail <what>: ends the run red; a step of the cleanup only reports and returns 1.
fail() {
  echo "live:check: $1" >&2
  [ "$cleaning" = false ] || return 1
  exit 1
}

# shellcheck source=keycloak_kcadm.sh
source "$(dirname "${BASH_SOURCE[0]}")/keycloak_kcadm.sh"
# shellcheck source=keycloak_login_form.sh
source "$(dirname "${BASH_SOURCE[0]}")/keycloak_login_form.sh"
keycloak_exec() { timeout --foreground "$call_seconds" kubectl --namespace keycloak exec "$@"; }
exec {kcadm_diagnostics_fd}>/dev/null
kcadm_update_output_fd=$kcadm_diagnostics_fd

# cookie_jar_of <app>: the app's own cookie jar, so a jar left by a killed run is signed out at the app that made it.
cookie_jar_of() { printf '%s/cookies-%s' "$lock_directory" "$1"; }
# load_app <app>: sets the app's Deployment and routes from its row, its origin and callback from its client in
# realm.yaml, and its cookie jar; says why and returns 1 when the client is missing.
load_app() {
  local client_entry
  read -r _ deployment_namespace deployment start_path account_path logout_path < <(app_row "$1")
  client_entry="$(CLIENT="$1" yq --exit-status --output-format json '.clients[] | select(.clientId == strenv(CLIENT))' "$realm_file")" || {
    echo "live:check: $realm_file declares no client $1" >&2
    return 1
  }
  origin="$(yq -p json -r '.baseUrl' <<<"$client_entry")"
  origin="${origin%/}"
  callback_url="$(yq -p json -r '.redirectUris[0]' <<<"$client_entry")"
  cookie_jar="$(cookie_jar_of "$1")"
  handed_over_marker="$(handed_over_of "$1")"
}

# shellcheck source=live_check_apps.sh
source "$(dirname "${BASH_SOURCE[0]}")/live_check_apps.sh"
# shellcheck source=live_check_journeys.sh
source "$(dirname "${BASH_SOURCE[0]}")/live_check_journeys.sh"
app="${1:-}"
tier="${2:-sign-in}"
# shellcheck disable=SC2034 # live_check_journeys.sh reads checkout and live_check_command.
checkout="${3:-}"
# The fourth argument is the gate's own call of the command for the journeys tier.
inside_gate="${4:-}"
# shellcheck disable=SC2034 # read by live_check_journeys.sh.
live_check_command="$(realpath -- "$0")"
if [ -z "$(app_row "$app")" ] || ! tier_arguments_agree; then
  echo "usage: mise run live:check <app> [--tier journeys --checkout <dir>]" >&2
  echo "apps: $(app_names | paste -sd ' ' -)" >&2
  exit 1
fi

# What the run does at the end, and what it says: the one place that reads the exit status.
# attempt <what> <command>...: runs the step; a failing one is named once in leftovers, which a second pass of the cleanup
# (the first cleanup's, then the trap's) keeps.
attempt() {
  local what="$1" named
  shift
  "$@" && return 0
  for named in "${leftovers[@]}"; do
    [ "$named" != "$what" ] || return 0
  done
  leftovers+=("$what")
}
finish() {
  local exit_status=$?
  set +e
  trap '' TERM INT
  cleaning=true
  if [ "$holds_lock" = true ]; then
    [ "$person_touched" = false ] || clean_up_person
    attempt "the sign-in file of kcadm in Keycloak's container" delete_config_file
  fi
  local stranded_file
  for stranded_file in "${stranded_config_files[@]}"; do
    leftovers+=("the sign-in file $stranded_file of kcadm in Keycloak's container")
  done
  local result=red
  [ "$exit_status" != 0 ] || result=green
  [ "$skipped" = false ] || [ "$exit_status" != 3 ] || result=skipped
  if [ "${#leftovers[@]}" != 0 ]; then
    result=red
    echo "live:check: may remain: $(printf '%s; ' "${leftovers[@]}")run again to clean up" >&2
  fi
  [ "$refused" = false ] || result=refused
  [ "$result" != red ] || exit_status=1
  echo "live:check: $app $result${codes[*]:+ (${codes[*]})}${sign_in_step:+ step=$sign_in_step}"
  exit "$exit_status"
}
trap finish EXIT
trap 'exit 143' TERM INT

# The refusals that need no cluster: nothing is read or written before them.
realm="$(yq '.realm' "$realm_file")"
PERSON="$person" yq --exit-status '.users[] | select(.username == strenv(PERSON) and .serviceAccountClientId == null)' \
  "$realm_file" >/dev/null 2>&1 || fail "$realm_file declares no person $person"
[ -n "${XDG_RUNTIME_DIR:-}" ] || fail "XDG_RUNTIME_DIR is unset, so the run has no private directory for its lock and cookie jars"
lock_directory="$XDG_RUNTIME_DIR/live-check"
load_app "$app" || exit 1
if [ "$tier" = journeys ] && [ -z "$inside_gate" ]; then
  require_a_checkout_of_the_app
  run_the_gate
fi

# One run at a time; a second is refused before it reads or writes anything.
[ -d "$lock_directory" ] || mkdir -m 700 -- "$lock_directory"
exec {lock_descriptor}>"$lock_directory/lock"
if ! flock --nonblock "$lock_descriptor"; then
  echo "live:check: another run holds $lock_directory/lock; nothing was changed" >&2
  refused=true
  exit 4
fi
holds_lock=true
[ "$tier" != journeys ] || the_scope_can_start

# ------------------------------------------------------------------------------------------ the person's state
person_json() { kcadm get "users/$person_id" --target-realm "$realm"; }
# enabled_state: prints true or false.
enabled_state() {
  local user
  user="$(person_json)" || return 1
  yq -p json '.enabled' <<<"$user"
}
# password_credential_ids: prints the id of each password credential, one per line.
password_credential_ids() {
  local credentials
  credentials="$(kcadm get "users/$person_id/credentials" --target-realm "$realm")" || return 1
  yq -p json -r '.[] | select(.type == "password") | .id' <<<"$credentials"
}
session_count() {
  local sessions
  sessions="$(kcadm get "users/$person_id/sessions" --target-realm "$realm")" || return 1
  yq -p json 'length' <<<"$sessions"
}
# set_enabled <true|false>: the whole representation goes back with the required actions cleared, which config-cli's
# first create filled with the realm's default.
set_enabled() {
  person_json | ENABLED="$1" yq -p json -o json '.enabled = (strenv(ENABLED) == "true") | .requiredActions = []' |
    kcadm update "users/$person_id" --target-realm "$realm" --file - --no-merge >&"$kcadm_update_output_fd"
}
person_needs_cleaning() {
  local enabled credential_ids sessions
  enabled="$(enabled_state)" || fail "$unreadable"
  credential_ids="$(password_credential_ids)" || fail "$unreadable"
  sessions="$(session_count)" || fail "$unreadable"
  [ "$enabled" = true ] || [ -n "$credential_ids" ] || [ "$sessions" != 0 ] || a_cookie_jar_is_left || a_journeys_run_left_something
}
a_cookie_jar_is_left() {
  local name
  for name in $(app_names); do
    [ ! -e "$(cookie_jar_of "$name")" ] || return 0
  done
  return 1
}

# visit <path or url> <curl argument>...: one request with the jar; sets answer to "<status> <redirect address>".
visit() {
  local target="$1"
  shift
  case "$target" in /*) target="$origin$target" ;; esac
  # A jar whose cookies were handed over is only read, so the read-back sends the very cookies the journeys had.
  local jar_arguments=(--cookie "$cookie_jar")
  [ -e "$handed_over_marker" ] || jar_arguments+=(--cookie-jar "$cookie_jar")
  answer="$(curl --silent --show-error --max-time "$call_seconds" --output /dev/null --write-out '%{http_code} %{redirect_url}' \
    "${jar_arguments[@]}" "$@" --config <(curl_url "$target"))"
}

# ------------------------------------------------------------------------------------------------- the cleanup
# The steps below return 1 and say nothing; clean_up_person runs every one whatever an earlier one did, none of them
# through fail, exit or errexit, and names each that failed in leftovers.
# app_request <path> <curl argument>...: prints the status the app answers.
app_request() {
  visit "$@" || return 1
  printf '%s' "${answer%% *}"
}
keycloak_is_reachable_by_kcadm() { kcadm get "users/$person_id" --target-realm "$realm" >/dev/null; }
sign_in_kcadm_again() {
  local previous_config_file="$config_file"
  keycloak_is_reachable_by_kcadm && return 0
  delete_config_file || stranded_config_files+=("$previous_config_file")
  sign_in_kcadm
}
delete_stranded_config_files() {
  local file remaining=()
  for file in "${stranded_config_files[@]}"; do
    delete_config_file "$file" || remaining+=("$file")
  done
  stranded_config_files=("${remaining[@]}")
}
# sign_out_of_app <app>: with the app's jar, its own sign-out route and Origin, read back by its account route answering
# 401; for a jar whose cookies were handed over, that proves the session ended at the app, not that the jar was cleared.
# The codes of a jar that is not this run's own, or of the first cleanup's, carry the app's name, so the result line
# holds no key twice.
sign_out_of_app() {
  local name="$1" code_prefix="" logout_status account_status
  local deployment_namespace deployment start_path account_path logout_path origin callback_url cookie_jar handed_over_marker
  [ -e "$(cookie_jar_of "$name")" ] || return 0
  load_app "$name" || return 1
  { [ "$name" != "$app" ] || [ "$healing" = true ]; } && code_prefix="$name-"
  logout_status="$(app_request "$logout_path" --header "Origin: $origin" --data '')" || logout_status=none
  account_status="$(app_request "$account_path")" || account_status=none
  codes+=("${code_prefix}sign-out=$logout_status" "${code_prefix}account-after=$account_status")
  [[ "$logout_status" == [23]?? ]] && [ "$account_status" = 401 ] && return 0
  [ "$name" != "$app" ] || [ "$healing" = true ] || [ -n "$sign_in_step" ] || sign_in_step=sign-out
  return 1
}
end_keycloak_sessions() {
  kcadm create "users/$person_id/logout" --target-realm "$realm" --set "realm=$realm" >&"$kcadm_update_output_fd" || return 1
  [ "$(session_count)" = 0 ]
}
delete_password_credentials() {
  local credential_id ids remaining
  ids="$(password_credential_ids)" || return 1
  for credential_id in $ids; do
    kcadm delete "users/$person_id/credentials/$credential_id" --target-realm "$realm" || return 1
  done
  remaining="$(password_credential_ids)" || return 1
  [ -z "$remaining" ]
}
disable_person() {
  set_enabled false || return 1
  [ "$(enabled_state)" = false ]
}
delete_cookie_jar() {
  rm -f -- "$(cookie_jar_of "$1")" "$(cookie_jar_of "$1").rewritten" "$(handed_over_of "$1")"
  [ ! -e "$(cookie_jar_of "$1")" ] && [ ! -e "$(handed_over_of "$1")" ]
}
clean_up_person() {
  local name
  attempt "$journeys_scopes_name" stop_journeys_scopes
  attempt "kcadm's sign-in to Keycloak" sign_in_kcadm_again
  for name in $(app_names); do
    attempt "the person's $name session" sign_out_of_app "$name"
  done
  for name in $(app_names); do
    attempt "the storage state $(storage_state_of "$name")" delete_storage_state "$name"
  done
  attempt "the person's Keycloak sessions" end_keycloak_sessions
  attempt "the person's password credential" delete_password_credentials
  attempt "the person, who may be enabled" disable_person
  for name in $(app_names); do
    attempt "the cookie jar $(cookie_jar_of "$name")" delete_cookie_jar "$name"
  done
  delete_stranded_config_files
}

# ----------------------------------------------------------------------------------------------------- the run
sign_in_kcadm
find_person "$person"

# A person found enabled, with a credential or a session, or a leftover jar is what an untrapped run left.
if person_needs_cleaning; then
  person_touched=true
  healing=true
  clean_up_person
  healing=false
  [ "${#leftovers[@]}" = 0 ] && [ "${#stranded_config_files[@]}" = 0 ] ||
    fail "an earlier run left something that could not be cleaned"
  person_touched=false
  echo "live:check: an earlier run's leftovers were cleaned up first"
fi

# The person belongs to the groups the file declares and no others, so that no agent-owner membership or realm not yet
# applied reaches the sign-in.
declared_groups="$(PERSON="$person" yq '(.users[] | select(.username == strenv(PERSON)) | .groups // [])[]' "$realm_file" | sort)"
live_groups="$(kcadm get "users/$person_id/groups" --target-realm "$realm")" || fail "$unreadable"
live_groups="$(yq -p json -r '.[].path' <<<"$live_groups" | sort)"
[ "$live_groups" = "$declared_groups" ] ||
  fail "$person is in $(paste -sd ' ' - <<<"$live_groups"), the file declares $(paste -sd ' ' - <<<"$declared_groups"); nothing was written. Wait for config-cli's apply of the file, or remove the membership the file does not declare"

available="$(timeout --foreground "$call_seconds" kubectl --namespace "$deployment_namespace" get deployment "$deployment" \
  --output jsonpath='{.status.conditions[?(@.type=="Available")].status}')" || fail "the Deployment $deployment cannot be read"
if [ "$available" != True ]; then
  skipped=true
  echo "live:check: the Deployment $deployment is not Available" >&2
  exit 3
fi

# The first write: from here every exit runs the whole cleanup.
person_touched=true
kcadm delete "attack-detection/brute-force/users/$person_id" --target-realm "$realm" >&"$kcadm_update_output_fd" ||
  fail "the person's failed sign-ins could not be cleared"
set_enabled true || fail "the person could not be enabled"
password="$(openssl rand -hex 24)"
printf '{"type": "password", "value": "%s", "temporary": false}' "$password" |
  kcadm update "users/$person_id/reset-password" --target-realm "$realm" --file - --no-merge >&"$kcadm_update_output_fd" ||
  fail "the person's password could not be set"

# fetch_page <url>: sets page and page_status.
fetch_page() {
  local reply
  reply="$(curl --silent --show-error --max-time "$call_seconds" --write-out $'\n%{http_code}' --cookie "$cookie_jar" \
    --cookie-jar "$cookie_jar" --config <(curl_url "$1"))"
  page_status="${reply##*$'\n'}"
  page="${reply%$'\n'*}"
}
expect_status() {
  codes+=("$1=${answer%% *}")
  [ "${answer%% *}" = "$2" ] || fail "$1 answered ${answer%% *}, not $2"
}

: >"$cookie_jar"
sign_in_step=start
visit "$start_path"
expect_status start 303
login_url="${answer#* }"
sign_in_step=login-page
fetch_page "$login_url"
codes+=("login-page=$page_status")
[ "$page_status" = 200 ] || fail "the login page answered $page_status, not 200"
sign_in_step=sign-in-form
answer="$(printf '%s' "$password" | post_form <(printf '%s' "$page") "${login_url%%/realms/*}" \
  --data-urlencode "username=$person" --data-urlencode password@-)"
expect_status sign-in-form 302
return_url="${answer#* }"
[ "${return_url%%\?*}" = "$callback_url" ] || fail "the sign-in form returns to ${return_url%%\?*}, not the callback of $app"
sign_in_step=callback
visit "$return_url"
expect_status callback 303
sign_in_step=account
visit "$account_path"
expect_status account 200
sign_in_step=""
[ "$tier" != journeys ] || hand_over_to_the_journeys
