#!/usr/bin/env bash
# Drive `mise run live:check <app>` against a fake kubectl, whose kcadm answers from a small model of the realm's test
# person, and a fake curl, which models each app's sign-in routes and Keycloak's login form, for what the live stack
# cannot arrange: that the per-run password stands in no argument, no output, no child's environment and no file of the
# run's runtime and temporary directories, and reaches kcadm and curl on stdin only; that no cookie, code or kcadm notice
# is printed; that the enable write clears the required actions and the brute-force clear comes before the sign-in; that
# for each app a success and a red sign-in, and for hopin a TERM during the sign-in, a failed write and a kcadm whose
# sign-in file is gone, each end with the person signed out, its credentials deleted and the person disabled, read back;
# that a failing sign-out or credential delete does not stop the steps after it and is named; that an undeclared
# person, live groups that differ from the file, a missing or unknown app, a held lock and a Deployment that is not
# Available are refused or skipped with no write; and that what an untrapped earlier run left, a jar of any app
# included, is cleaned up first.
# Usage: mise exec -- tests/keycloak/live_check_leaves_the_person_disabled_on_every_exit.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
# shellcheck source=live_check_fakes.sh
source "$repository_root/tests/keycloak/live_check_fakes.sh"


# ----------------------------------------------------------------------------------- a success and a refusal per app
for contract in "${contracts[@]}"; do
  checked_app="${contract%% *}"

  prepare_case "success-$checked_app"
  run_command "success-$checked_app"
  expect_result "success-$checked_app" 0 green
  kept_secret "success-$checked_app"
  left_clean "success-$checked_app"
  [ "$(<"$state/enable-required-actions")" = '[]' ] || refuse "success-$checked_app: the enable write left required actions"
  [ -e "$state/password-on-kcadm-stdin" ] && [ -e "$state/password-on-curl-stdin" ] ||
    refuse "success-$checked_app: the password did not reach kcadm and the form on stdin"
  in_order "success-$checked_app" 'brute-force-cleared' 'write enabled=true' 'password-set' 'curl: start' 'curl: login page' \
    'curl: sign-in form' 'curl: callback' 'curl: account'
  cleanup_order "success-$checked_app"
  grep -q 'account=200 sign-out=200 account-after=401' "$output_file" ||
    refuse "success-$checked_app: the output holds not the codes of the sign-in and sign-out"
  echo "$checked_app: a success signs in on stdin credentials only, clears the required actions, and leaves the person signed out, disabled, with no credential and no file"

  prepare_case "red-sign-in-$checked_app"
  run_command "red-sign-in-$checked_app" FAKE_SIGNIN=refused
  expect_result "red-sign-in-$checked_app" 1 red
  kept_secret "red-sign-in-$checked_app"
  left_clean "red-sign-in-$checked_app"
  cleanup_order "red-sign-in-$checked_app"
  grep -qE "^live:check: $checked_app red .* step=sign-in-form\$" "$output_file" || refuse "red-sign-in-$checked_app: the result line names not the failed step"
  echo "$checked_app: a refused sign-in is red, and the person is signed out and disabled"
done
checked_app=hopin

# ---------------------------------------------------------------------------- each exit that is not a success (hopin)
prepare_case term-during-sign-in
run_command term-during-sign-in FAKE_TERM_AT=login-page
[ "$status" = 1 ] || refuse "term-during-sign-in: exit $status, not 1"
grep -qE '^live:check: hopin red' "$output_file" || refuse "term-during-sign-in: no red result line"
kept_secret term-during-sign-in
left_clean term-during-sign-in
cleanup_order term-during-sign-in
echo "a TERM during the sign-in ends red, and the person is signed out and disabled"

prepare_case transport-fails
run_command transport-fails FAKE_TRANSPORT_FAILS=start
expect_result transport-fails 1 red
kept_secret transport-fails
left_clean transport-fails
cleanup_order transport-fails
echo "a request that fails in transport is red with exit 1 and not the status of curl, and the person is disabled"

prepare_case start-fails-at-the-app
run_command start-fails-at-the-app FAKE_TRANSPORT_FAILS=start
grep -qE '^live:check: hopin red .*step=start$' "$output_file" || refuse "start-fails-at-the-app: the result line names not the step start"
echo "a failed start is named as the step start on the result line"

prepare_case foreign-callback
run_command foreign-callback FAKE_CALLBACK_URL=https://foreign.example/callback
expect_result foreign-callback 1 red
grep -q "the sign-in form returns to https://foreign.example/callback, not the callback of hopin" "$output_file" ||
  refuse "foreign-callback: the output does not name the foreign callback and the app"
kept_secret foreign-callback
left_clean foreign-callback
cleanup_order foreign-callback
echo "a sign-in form that returns to another address than the app's callback is red and names both, and the person is disabled"

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

prepare_case config-removal-fails
run_command config-removal-fails FAKE_DROP_CONFIG_AT=enable FAKE_FAIL=remove-first-config
[ "$status" = 1 ] || refuse "config-removal-fails: exit $status, not 1"
grep -q "may remain: .*sign-in file /tmp/kcadm-.* of kcadm" "$output_file" || refuse "config-removal-fails: the output names no sign-in file"
kept_secret config-removal-fails
left_clean config-removal-fails
echo "a sign-in file of kcadm that cannot be removed before the new sign-in is named with its path"

prepare_case heal-config-removal-fails enabled
run_command heal-config-removal-fails FAKE_DROP_CONFIG_AT=heal FAKE_FAIL=remove-first-config
[ "$status" = 1 ] || refuse "heal-config-removal-fails: exit $status, not 1"
grep -q "may remain: .*sign-in file /tmp/kcadm-.* of kcadm" "$output_file" || refuse "heal-config-removal-fails: the output names no sign-in file"
kept_secret heal-config-removal-fails
left_clean heal-config-removal-fails
echo "a sign-in file of kcadm that cannot be removed during the first cleanup is still named after the run ends"

prepare_case hopin-sign-out-fails
run_command hopin-sign-out-fails FAKE_LOGOUT_STATUS=502
[ "$status" = 1 ] || refuse "hopin-sign-out-fails: exit $status, not 1"
grep -q "may remain: .*the person's hopin session" "$output_file" || refuse "hopin-sign-out-fails: the output names no hopin session"
kept_secret hopin-sign-out-fails
left_clean hopin-sign-out-fails
echo "a hopin sign-out that answers 502 is named, and the credential is still deleted and the person disabled"

prepare_case hopin-sign-out-fails-session-ends
run_command hopin-sign-out-fails-session-ends FAKE_LOGOUT_STATUS=502 FAKE_LOGOUT_ENDS_SESSION=true
[ "$status" = 1 ] || refuse "hopin-sign-out-fails-session-ends: exit $status, not 1"
grep -q "may remain: .*the person's hopin session" "$output_file" || refuse "hopin-sign-out-fails-session-ends: the output names no hopin session"
grep -q 'account-after=401' "$output_file" || refuse "hopin-sign-out-fails-session-ends: the account was not read back as signed out"
kept_secret hopin-sign-out-fails-session-ends
left_clean hopin-sign-out-fails-session-ends
echo "a hopin sign-out that answers 502 is named even when the account answers 401 after it"

prepare_case heal-sign-out-fails jar:skat
run_command heal-sign-out-fails FAKE_LOGOUT_STATUS=502
[ "$status" = 1 ] || refuse "heal-sign-out-fails: exit $status, not 1"
grep -q "may remain: .*the person's skat session" "$output_file" || refuse "heal-sign-out-fails: the output names no skat session"
[ "$(<"$state/enabled")" = false ] || refuse "heal-sign-out-fails: the person is enabled"
echo "a skat sign-out that fails during the first cleanup is still named after the run ends"

prepare_case credential-delete-fails
run_command credential-delete-fails FAKE_FAIL=delete-credential
[ "$status" = 1 ] || refuse "credential-delete-fails: exit $status, not 1"
grep -q "may remain: .*the person's password credential" "$output_file" || refuse "credential-delete-fails: the output names no credential"
kept_secret credential-delete-fails
left_clean credential-delete-fails credential
in_order credential-delete-fails 'keycloak-logout' 'write enabled=false' 'config-removed'
echo "a credential that cannot be deleted is named, and the person is still disabled"

# ------------------------------------------------------------------------------- what stops the run before a write
refused_before_any_call() {
  local case_name="$1" deletion="$2" refusal="$3" realm_without="$work_directory/realm-$1.yaml"
  yq "$deletion" "$realm_file" >"$realm_without"
  prepare_case "$case_name" enabled
  run_command "$case_name" REALM_FILE="$realm_without"
  [ "$status" = 1 ] || refuse "$case_name: exit $status, not 1"
  grep -q "$refusal" "$output_file" || refuse "$case_name: the refusal does not say: $refusal"
  [ ! -s "$state/log" ] || refuse "$case_name: the stack was called: $(paste -sd'|' "$state/log")"
  [ "$(<"$state/enabled")" = true ] || refuse "$case_name: a person was written"
}
refused_before_any_call undeclared-person 'del(.users[] | select(.serviceAccountClientId == null))' "declares no person"
echo "a person the realm file does not declare is refused before any call"
refused_before_any_call undeclared-client 'del(.clients[] | select(.clientId == "hopin"))' "declares no client"
echo "a client the realm file does not declare is refused before any call"

prepare_case lock-held enabled
mkdir -m 700 "$runtime/live-check"
exec {lock_descriptor}>"$runtime/live-check/lock"
flock --nonblock "$lock_descriptor"
run_command lock-held
exec {lock_descriptor}>&-
expect_result lock-held 4 refused
grep -q "another run holds" "$output_file" || refuse "lock-held: the refusal names no other run"
[ ! -s "$state/log" ] || refuse "lock-held: the stack was called: $(paste -sd'|' "$state/log")"
[ "$(<"$state/enabled")" = true ] || refuse "lock-held: a person was written"
echo "a second run is refused with exit 4 and the result refused, with no call and no write"

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
# A run for hopin finds a person left enabled, or a jar of hopin or of another app, and cleans up first; the codes of a
# jar left by a killed run name its app.
declare -A heal_codes=([enabled]='' [jar:hopin]='hopin-sign-out=200 hopin-account-after=401' [jar:skat]='skat-sign-out=200 skat-account-after=401')
declare -A first_cleanup_event=([enabled]='keycloak-logout' [jar:hopin]='curl: logout' [jar:skat]='curl: logout')
for start in enabled jar:hopin jar:skat; do
  case_name="heal-${start/:/-}"
  prepare_case "$case_name" "$start"
  run_command "$case_name"
  expect_result "$case_name" 0 green
  kept_secret "$case_name"
  left_clean "$case_name"
  grep -q "leftovers were cleaned up first" "$output_file" || refuse "$case_name: the output says nothing of the heal"
  if [[ $start == enabled ]]; then
    ! grep -q '[a-z]*-sign-out=' "$output_file" || refuse "$case_name: the heal printed an app's sign-out code"
  else
    grep -q -- "${heal_codes[$start]}" "$output_file" || refuse "$case_name: the output holds not the codes '${heal_codes[$start]}'"
  fi
  in_order "$case_name" "${first_cleanup_event[$start]}" 'write enabled=false' 'brute-force-cleared' 'write enabled=true' 'curl: callback'
  echo "a person left $start by an earlier run is cleaned up before the new run writes"
done

# ------------------------------------------------------------------------------------ what the command refuses to start
prepare_case other-group
echo '[{"path": "/apps/hopin"}, {"path": "/agent-owners"}]' >"$state/groups"
run_command other-group
[ "$status" = 1 ] || refuse "other-group: exit $status, not 1"
grep -q "remove the membership the file does not declare" "$output_file" || refuse "other-group: the refusal names no remedy"
grep -q '^live:check: hopin red' "$output_file" || refuse "other-group: no red result line"
no_event 'write\|brute-force\|password-set\|keycloak-logout\|deployment' || refuse "other-group: a write or a read past the refusal: $(paste -sd'|' "$state/log")"
[ "$(<"$state/enabled")" = false ] || refuse "other-group: the person was enabled"
echo "live groups that differ from the file are refused with no write, naming the remedy"

for unusable in "" nosuchapp; do
  checked_app="$unusable"
  prepare_case "usage-${unusable:-no-argument}"
  run_command "usage-${unusable:-no-argument}"
  [ "$status" = 1 ] || refuse "usage-${unusable:-no-argument}: exit $status, not 1"
  [ "$(sed -n 1p "$output_file")" = 'usage: mise run live:check <app>' ] || refuse "usage-${unusable:-no-argument}: not the plain usage"
  ! grep -q '^live:check: ' "$output_file" || refuse "usage-${unusable:-no-argument}: a result line"
  for contract in "${contracts[@]}"; do
    grep -q "^apps: .*\b${contract%% *}\b" "$output_file" || refuse "usage-${unusable:-no-argument}: the apps do not name ${contract%% *}"
  done
  [ ! -s "$state/log" ] || refuse "usage-${unusable:-no-argument}: the stack was called: $(paste -sd'|' "$state/log")"
done
checked_app=hopin
echo "no argument and an unknown app print the usage and the app names, with no stack call and no result line"
