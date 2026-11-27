#!/usr/bin/env bash
# Drive `mise run live:check <app> --tier journeys --checkout <dir>` against the fakes of tests/keycloak/live_check_fakes.sh
# (kubectl, curl, probe-run, systemd-run, systemctl and the app's own mise) and a real temporary git repository as the
# checkout, for what the live stack cannot arrange: that the app's command gets the origin and a 0600 storage state of
# the app's own cookies, never a Keycloak cookie or the password, in a minimal environment with no lock descriptor and
# no output of its own in the command's; that on every exit the command can trap the scope is stopped before the file is
# deleted and the handed-over session is signed out and read back with the very cookies handed over; that exit 0, 1 and
# 3 of the app are green, red and skipped and each status of the gate is mapped; that a TERM or INT reaches the gate once;
# that what a run killed untrapped left is cleaned up by the next run of any app; and that a checkout outside the app's
# repository, no work tree and one without the task are refused with no write, and are never changed.
# Usage: mise exec -- tests/live-check/journeys_get_the_apps_cookies_in_a_file_deleted_on_every_exit.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
# shellcheck source=../keycloak/live_check_fakes.sh
source "$repository_root/tests/keycloak/live_check_fakes.sh"

call_seconds="$(sed -n 's/^call_seconds=//p' "$repository_root/scripts/live_check.sh")"
scope_reads="$(sed -n 's/^scope_reads=//p' "$repository_root/scripts/live_check_journeys.sh")"
cleanup_seconds="$(call_seconds="$call_seconds" bash -c 'source "$1"; echo "$cleanup_seconds"' _ "$repository_root/scripts/live_check_journeys.sh")"
gate_bound_seconds=1830

# make_checkout <name> <repository> [tasks]: a git work tree whose origin names the GitHub repository and whose mise.toml
# declares live:journeys unless tasks is none; sets checkout.
make_checkout() {
  checkout="$work_directory/checkout-$1"
  mkdir "$checkout"
  git -C "$checkout" init --quiet
  git -C "$checkout" remote add origin "https://github.com/$2.git"
  if [ "${3:-}" != none ]; then
    printf '[tasks."live:journeys"]\nrun = "true"\n' >"$checkout/mise.toml"
  else
    printf '[tools]\n' >"$checkout/mise.toml"
  fi
  git -C "$checkout" add mise.toml
}
# fingerprint <directory>: every path, mode and content of the tree, its git state included.
fingerprint() { (cd "$1" && { find . -printf '%p %m\n' | sort; find . -type f -exec sha256sum {} + | sort; }) | sha256sum; }
# journeys_run <name> <drive mode> [environment assignment]...: runs the journeys tier for checked_app against a fresh
# checkout of its repository; sets checkout and, afterwards, status.
journeys_run() {
  local name="$1" mode="$2"
  shift 2
  prepare_case "$name"
  echo "$mode" >"$state/drive-mode"
  make_checkout "$name" "overnightworks/$checked_app"
  live_check_arguments=(--tier journeys --checkout "$checkout")
  checkout_before="$(fingerprint "$checkout")"
  run_command "$name" "$@"
  live_check_arguments=()
}
checkout_unchanged() { [ "$(fingerprint "$checkout")" = "$checkout_before" ] || refuse "$1: the checkout changed"; }
# record_line <key>: the drive's record of what it received.
record_line() { sed -n "s/^$1 //p" "$state/drive-record"; }
# leave_scope_of <app>: a scope of an earlier run that is still alive.
leave_scope_of() {
  FAKE_STATE="$state" FAKE_LIB="$work_directory/fake_lib.sh" XDG_RUNTIME_DIR="$runtime" systemd-run --user --scope --unit "live-check-journeys-$1" -- sleep 600 &
  until [ -e "$state/scope-live-check-journeys-$1" ]; do sleep 0.05; done
}
# leave_handed_over_run <app>: what a run killed during its drive leaves: the person enabled with a credential and
# sessions, the app's jar with its marker, the storage state and the scope.
leave_handed_over_run() {
  local left_app="$1" directory
  prepare_case "$2" enabled
  directory="$runtime/live-check"
  mkdir -m 700 "$directory"
  printf '#HttpOnly_%s\tFALSE\t/\tTRUE\t0\tsession\t%s\n' "$(app_host "$left_app")" "$cookie_value" >"$directory/cookies-$left_app"
  : >"$directory/handed-over-$left_app"
  echo '{"cookies": [], "origins": []}' >"$directory/storage-state-$left_app.json"
  touch "$state/session-$left_app"
  leave_scope_of "$left_app"
}
# stopped_before_deleting <case> <app>: the scope was stopped while the storage state still stood.
stopped_before_deleting() { in_order "$1" "systemctl: stop live-check-journeys-$2 file=present"; }

checked_app=hopin

# --------------------------------------------------------------------------------------------- what the drive receives
journeys_run green exit:0
expect_result green 0 green
kept_secret green
left_clean green
checkout_unchanged green
origin="$(awk -v wanted="$checked_app" '$1 == wanted { print $2 }' "$apps_file")"
host="$(app_host "$checked_app")"
[ "$(record_line origin)" = "$origin" ] || refuse "green: the drive got origin '$(record_line origin)', not $origin"
[ "$(record_line checkout)" = "$(realpath "$checkout")" ] || refuse "green: the drive ran in another checkout"
[ "$(record_line mode)" = 600 ] || refuse "green: the storage state is mode $(record_line mode), not 600"
[ "$(record_line cookies)" = "session,$host,/,-1,true,true,Lax theme,$host,/,4102444800,false,false,Lax" ] ||
  refuse "green: the storage state holds '$(record_line cookies)'"
[ "$(record_line origins)" = 0 ] || refuse "green: the storage state names origins"
[ "$(record_line jar)" = "#HttpOnly_$host $host" ] || refuse "green: the jar holds '$(record_line jar)' during the drive"
[ "$(record_line environment)" = "HOME LANG PATH" ] || refuse "green: the drive's environment is '$(record_line environment)'"
[ "$(record_line path)" = /usr/bin:/bin ] || refuse "green: the drive's PATH is '$(record_line path)'"
! grep -q '^lock inherited' "$state/drive-record" || refuse "green: the drive inherited the lock descriptor"
! grep -q 'the drive printed this' "$output_file" || refuse "green: the drive's output reached the command's"
grep -q 'account=200 journeys=0 sign-out=200 account-after=401' "$output_file" || refuse "green: the result line holds not the codes"
in_order green 'systemd-run: trial' 'kubectl: kcadm-signed-in' 'write enabled=true' 'systemd-run: scope live-check-journeys-hopin' \
  'drive: started' 'systemctl: stop live-check-journeys-hopin' 'curl: logout' 'keycloak-logout' 'write enabled=false' 'config-removed'
stopped_before_deleting green hopin
stop_seconds="$(sed -n 's/^systemd-run: scope live-check-journeys-hopin TimeoutStopSec=\([0-9][0-9]*\)$/\1/p' "$state/log")"
[ -n "$stop_seconds" ] || refuse "green: the scope sets no TimeoutStopSec"
grep -q 'curl: logout read-only' "$state/log" || refuse "green: the handed-over jar was rewritten by the sign-out"
gate_line="$(grep '^probe-run: ' "$state/log")"
[[ "$gate_line" =~ ^probe-run:\ -k\ ([0-9]+)\ ([0-9]+)\  ]] || refuse "green: the gate is not called as probe-run -k K CAP: $gate_line"
gate_kill="${BASH_REMATCH[1]}" gate_cap="${BASH_REMATCH[2]}"
[ $((gate_kill + gate_cap)) -le "$gate_bound_seconds" ] || refuse "green: K $gate_kill and CAP $gate_cap pass probe-run's bound of $gate_bound_seconds"
[ "$gate_kill" -ge "$cleanup_seconds" ] || refuse "green: K $gate_kill is below the cleanup's $cleanup_seconds seconds"
[ "$cleanup_seconds" -gt "$stop_seconds" ] || refuse "green: the cleanup's $cleanup_seconds seconds do not cover the scope's stop of $stop_seconds"
[ "$(sed -n '/^drive: started/,$p' "$state/log" | grep -c '^systemctl: list')" -le "$scope_reads" ] ||
  refuse "green: the cleanup read the user manager more than $scope_reads times: $(paste -sd'|' "$state/log")"
echo "a green journeys run hands the app its origin and a 0600 storage state of its own cookies in a minimal environment, stops the scope, signs out with the handed-over cookies and deletes the file"

# ------------------------------------------------------------------------------------------- the drive's own exit codes
declare -A drive_result=([exit:1]="1 red journeys=1" [exit:7]="1 red journeys=7" [exit:3]="3 skipped journeys=3")
for mode in exit:1 exit:7 exit:3; do
  read -r expected_status expected_result expected_code <<<"${drive_result[$mode]}"
  case_name="drive-${mode/:/-}"
  journeys_run "$case_name" "$mode"
  expect_result "$case_name" "$expected_status" "$expected_result"
  grep -q "$expected_code" "$output_file" || refuse "$case_name: the result line holds not $expected_code"
  if [ "$expected_result" = red ]; then
    grep -qE "^live:check: hopin red .*step=journeys\$" "$output_file" || refuse "$case_name: the result line names not the step journeys"
  else
    ! grep -q 'step=' "$output_file" || refuse "$case_name: a skipped result names a step"
  fi
  kept_secret "$case_name"
  left_clean "$case_name"
  stopped_before_deleting "$case_name" hopin
  checkout_unchanged "$case_name"
  echo "the app's exit ${mode#exit:} is $expected_result, and the person is signed out and disabled with the file deleted"
done

# ---------------------------------------------------------------------------------------- the read-back of the session
journeys_run keeps-session exit:0 FAKE_LOGOUT_KEEPS_SESSION=true
[ "$status" = 1 ] || refuse "keeps-session: exit $status, not 1"
grep -qE '^live:check: hopin red .*step=sign-out$' "$output_file" || refuse "keeps-session: the result line names not the step sign-out"
grep -q "may remain: .*the person's hopin session" "$output_file" || refuse "keeps-session: the output names no hopin session"
grep -q 'account-after=200' "$output_file" || refuse "keeps-session: the account was not read back with the handed-over cookies"
kept_secret keeps-session
[ "$(<"$state/enabled")" = false ] && [ ! -s "$state/credentials" ] || refuse "keeps-session: the person is enabled or holds a credential"
! compgen -G "$runtime/live-check/[chs]*" >/dev/null || refuse "keeps-session: a file of the run remains"
echo "an app that keeps its session after the sign-out makes the run red, names the session and still disables the person"

journeys_run unreadable-jar exit:0 FAKE_JAR_GARBAGE=true
expect_result unreadable-jar 1 red
grep -qE '^live:check: hopin red .*step=storage-state$' "$output_file" || refuse "unreadable-jar: the result line names not the step storage-state"
no_event 'drive: started' || refuse "unreadable-jar: the drive ran"
kept_secret unreadable-jar
left_clean unreadable-jar
echo "a jar line the conversion cannot read is red before the drive, with no cookie in the output"

# ---------------------------------------------------------------------------------------------------------- signals
for signal in TERM INT; do
  case_name="signal-$signal"
  journeys_run "$case_name" "signal:$signal:outer"
  expect_result "$case_name" 1 red
  [ "$(grep -c '^probe-run: term' "$state/log")" = 1 ] || refuse "$case_name: the gate did not get the signal once"
  [ "$(grep -c '^live:check: hopin ' "$output_file")" = 1 ] || refuse "$case_name: not exactly the inner run's result line"
  grep -q 'drive: terminated' "$state/log" || refuse "$case_name: the drive did not end"
  kept_secret "$case_name"
  left_clean "$case_name"
  stopped_before_deleting "$case_name" hopin
  checkout_unchanged "$case_name"
  echo "a $signal to the command is passed to the gate once, and the command returns after the inner run's result line, with the person disabled"
done

journeys_run kill-inner signal:KILL:inner
expect_result kill-inner 1 red
grep '^live:check: hopin ' "$output_file" | tail -n 1 | grep -qE '^live:check: hopin red \(gate=137\)$' || refuse "kill-inner: the last line is not the gate's red"
[ ! -e "$state/scope-live-check-journeys-hopin" ] || refuse "kill-inner: the outer command left the scope"
[ "$(<"$state/enabled")" = true ] && [ -e "$runtime/live-check/cookies-hopin" ] && [ -e "$runtime/live-check/storage-state-hopin.json" ] ||
  refuse "kill-inner: the killed run left no person, jar and file for the heal"
checked_app=skat
live_check_arguments=()
run_command kill-inner
expect_result kill-inner 0 green
grep -q "hopin-sign-out=200 hopin-account-after=401" "$output_file" || refuse "kill-inner: the heal did not read hopin's session back"
grep -q 'curl: logout read-only' "$state/log" || refuse "kill-inner: the heal rewrote the handed-over jar"
kept_secret kill-inner
left_clean kill-inner
checked_app=hopin
echo "a drive killed untrapped is stopped by the outer command, and the next run of another app signs the jar out and deletes the file"

# -------------------------------------------------------------------------------------- what an earlier run left behind
leave_handed_over_run hopin leftover-scope
checked_app=skat
run_command leftover-scope
expect_result leftover-scope 0 green
grep -q "leftovers were cleaned up first" "$output_file" || refuse "leftover-scope: the output says nothing of the heal"
in_order leftover-scope 'systemctl: stop live-check-journeys-hopin file=present' 'curl: logout read-only' 'write enabled=false' 'brute-force-cleared'
kept_secret leftover-scope
left_clean leftover-scope
checked_app=hopin
echo "a scope, a storage state and a handed-over jar of an earlier run are stopped, deleted and signed out first"

leave_handed_over_run hopin leftover-keeps-session
run_command leftover-keeps-session FAKE_LOGOUT_KEEPS_SESSION=true
[ "$status" = 1 ] || refuse "leftover-keeps-session: exit $status, not 1"
grep -q "may remain: .*the person's hopin session" "$output_file" || refuse "leftover-keeps-session: the output names no hopin session"
! compgen -G "$runtime/live-check/[chs]*" >/dev/null || refuse "leftover-keeps-session: a file of the run remains"
echo "the heal's read-back of a handed-over jar names a session the app kept"

# ------------------------------------------------------------------------------------------- the gate's own statuses
for gate_status in 75 2 69 130; do
  case_name="gate-$gate_status"
  prepare_case "$case_name"
  make_checkout "$case_name" "overnightworks/$checked_app"
  live_check_arguments=(--tier journeys --checkout "$checkout")
  run_command "$case_name" FAKE_GATE_STATUS="$gate_status"
  live_check_arguments=()
  if [ "$gate_status" = 75 ]; then
    expect_result "$case_name" 3 skipped
    grep -q "^live:check: hopin skipped reason=load\$" "$output_file" || refuse "$case_name: the line is not skipped reason=load"
  else
    expect_result "$case_name" 1 red
    grep -q "^live:check: hopin red (gate=$gate_status)\$" "$output_file" || refuse "$case_name: the line is not red (gate=$gate_status)"
  fi
  [ "$(grep -vc '^probe-run: \|^mise: tasks' "$state/log")" = 0 ] || refuse "$case_name: a call past the gate: $(paste -sd'|' "$state/log")"
  [ ! -e "$runtime/live-check" ] || refuse "$case_name: the run made its lock directory"
done
echo "the gate's load timeout is skipped and its other failures red, each with no lock, no stack call and no write"

prepare_case lock-held enabled
mkdir -m 700 "$runtime/live-check"
exec {lock_descriptor}>"$runtime/live-check/lock"
flock --nonblock "$lock_descriptor"
make_checkout lock-held overnightworks/hopin
live_check_arguments=(--tier journeys --checkout "$checkout")
run_command lock-held
live_check_arguments=()
exec {lock_descriptor}>&-
expect_result lock-held 4 refused
! grep -q 'gate=' "$output_file" || refuse "lock-held: the gate added a line to the inner run's refusal"
no_event 'kubectl\|systemd-run\|drive' || refuse "lock-held: the stack or the scope was called: $(paste -sd'|' "$state/log")"
[ "$(<"$state/enabled")" = true ] || refuse "lock-held: a person was written"
echo "a held lock gives the inner run's refused with exit 4 and nothing of the gate's"

prepare_case scope-trial-fails
make_checkout scope-trial-fails overnightworks/hopin
live_check_arguments=(--tier journeys --checkout "$checkout")
run_command scope-trial-fails FAKE_FAIL=scope
live_check_arguments=()
expect_result scope-trial-fails 1 red
grep -qE '^live:check: hopin red .*step=scope$' "$output_file" || refuse "scope-trial-fails: the result line names not the step scope"
no_event 'kubectl\|drive' || refuse "scope-trial-fails: the stack was called: $(paste -sd'|' "$state/log")"
[ "$(<"$state/enabled")" = false ] || refuse "scope-trial-fails: a person was written"
echo "a scope that cannot start is red at platform before anything is written"

journeys_run manager-unreachable exit:0 FAKE_FAIL=manager
expect_result manager-unreachable 1 red
grep -q 'may remain: .*a journeys scope' "$output_file" || refuse "manager-unreachable: the output names no journeys scope"
no_event 'drive' || refuse "manager-unreachable: the drive ran: $(paste -sd'|' "$state/log")"
[ "$(<"$state/enabled")" = false ] || refuse "manager-unreachable: a person was written"
echo "a user manager that cannot be read leaves the scopes unproven gone, so the run is red and names a scope"

# ----------------------------------------------------------------------------------------------------- the checkout
refused_checkout() {
  local name="$1"
  prepare_case "$name"
  live_check_arguments=(--tier journeys --checkout "$checkout")
  checkout_before="$(fingerprint "$checkout")"
  run_command "$name"
  live_check_arguments=()
  expect_result "$name" 1 red
  grep -qE "^live:check: hopin red step=checkout\$" "$output_file" || refuse "$name: the result line names not the step checkout"
  [ "$(grep -vc '^mise: tasks' "$state/log")" = 0 ] || refuse "$name: a call past the refusal: $(paste -sd'|' "$state/log")"
  [ ! -e "$runtime/live-check" ] || refuse "$name: the run made its lock directory"
  checkout_unchanged "$name"
}
make_checkout foreign-repository overnightworks/skat
refused_checkout foreign-repository
echo "a checkout of another app's repository is refused with no write"
checkout="$work_directory/no-work-tree"
mkdir "$checkout"
refused_checkout no-work-tree
echo "a directory that is no git work tree is refused with no write"
make_checkout no-task overnightworks/hopin none
refused_checkout no-task
echo "a checkout whose mise lists no live:journeys is refused with no write"

for usage_case in "unknown-tier --tier weekly" "checkout-without-tier --checkout $work_directory" "tier-without-checkout --tier journeys"; do
  case_name="${usage_case%% *}"
  prepare_case "usage-$case_name"
  # shellcheck disable=SC2206 # the case's words are plain
  live_check_arguments=(${usage_case#* })
  run_command "usage-$case_name"
  live_check_arguments=()
  [ "$status" = 1 ] || refuse "usage-$case_name: exit $status, not 1"
  [ "$(sed -n 1p "$output_file")" = 'usage: mise run live:check <app> [--tier journeys --checkout <dir>]' ] || refuse "usage-$case_name: not the usage"
  ! grep -q '^live:check: ' "$output_file" || refuse "usage-$case_name: a result line"
  [ ! -s "$state/log" ] || refuse "usage-$case_name: the stack was called: $(paste -sd'|' "$state/log")"
done
echo "an unknown tier, a checkout without the journeys tier and the journeys tier without a checkout are the usage refusal"

prepare_case sign-in-tier
live_check_arguments=(--tier sign-in)
run_command sign-in-tier
live_check_arguments=()
expect_result sign-in-tier 0 green
no_event 'probe-run\|systemd-run' || refuse "sign-in-tier: the gate or a scope was used: $(paste -sd'|' "$state/log")"
left_clean sign-in-tier
echo "the sign-in tier runs with no gate and no scope"
