# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # app, origin, checkout, cookie_jar, lock_directory, lock_descriptor, call_seconds, codes and fail belong to live_check.sh, which reads skipped and sign_in_step.
# Sourced by live_check.sh: the journeys tier of `mise run live:check <app> --tier journeys --checkout <dir>`. The command
# calls probe-run once for the whole run (its one load wait comes before the lock and the first write; the sign-in, the
# drive and the trapped cleanup run inside its cap), signs the test person in as the sign-in tier does, hands the app's
# `live:journeys` task of the checkout the origin and a storage-state file of the run's own cookies, and signs the
# handed-over session out again. The password never reaches the task. The drive's own session, the environment and the jar
# without Keycloak's cookies keep a cooperative task from overreaching; the boundary is the operator's account
# (docs/operations.md OPS-25).

# The drive's whole environment: the app's own mise supplies its tools.
journey_environment=(HOME="${HOME:?}" PATH=/usr/bin:/bin LANG="${LANG:-C.UTF-8}")
# The drive's stop: its process group gets a TERM, and what is left after drive_stop_seconds a KILL, which is read back for
# drive_kill_seconds.
drive_stop_seconds=30
drive_kill_seconds=10
# What one pass of the cleanup spends: its calls of call_seconds (15 at most: kcadm's file lost, one credential), the two
# listings of the processes that end the two waits of the drive's stop past their seconds, and those seconds. Every tier
# runs it, so mise.toml's timeout -k for the sign-in tier and the nightly unit's stop delay follow cleanup_seconds.
cleanup_calls=15
drive_reads=2
cleanup_seconds=$(((cleanup_calls + drive_reads) * call_seconds + drive_stop_seconds + drive_kill_seconds))
# probe-run bounds a run by CAP + K (its own rule). K is the cleanup's seconds; CAP is what remains.
gate_bound_seconds=1830
gate_kill_seconds=$cleanup_seconds
gate_cap_seconds=$((gate_bound_seconds - gate_kill_seconds))
journeys_drive_name="the processes of the journeys drive"
# The drive's process group, which is its pid: setsid gives it a session of its own, so that a stop reaches every process
# that stays in it. A process that leaves the group lives until the run's namespace ends, with probe-run's command.
drive_group=""

# tier_arguments_agree: the tier is known and the checkout comes with the journeys tier only.
tier_arguments_agree() {
  case "$tier" in
    sign-in) [ -z "$checkout" ] ;;
    journeys) [ -n "$checkout" ] ;;
    *) return 1 ;;
  esac
}

# --------------------------------------------------------------------------------------- the files and the drive of a run
storage_state_of() { printf '%s/storage-state-%s.json' "$lock_directory" "$1"; }
# The marker beside the jar says its cookies were handed over, so its sign-out leaves the jar as it is.
handed_over_of() { printf '%s/handed-over-%s' "$lock_directory" "$1"; }
delete_storage_state() {
  rm -f -- "$(storage_state_of "$1")"
  [ ! -e "$(storage_state_of "$1")" ]
}
# a_journeys_run_left_something: an earlier run's storage state, of any app.
a_journeys_run_left_something() {
  local name
  for name in $(app_names); do
    [ ! -e "$(storage_state_of "$name")" ] || return 0
  done
  return 1
}
# drive_processes: prints the live processes of the drive's group, one a line; fails when the listing cannot be read.
drive_processes() {
  local listing
  listing="$(timeout --foreground "$call_seconds" ps -e -o pgid=,stat=)" || return 1
  awk -v group="$drive_group" '$1 == group && $2 !~ /^Z/' <<<"$listing"
}
# wait_until_the_drive_is_gone <seconds>: polls for at most that long; fails when processes of the drive are left or
# the listing cannot be read, which proves none gone.
wait_until_the_drive_is_gone() {
  local deadline=$((SECONDS + $1)) remaining
  while :; do
    remaining="$(drive_processes)" || return 1
    [ -n "$remaining" ] || return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}
# stop_the_drive: TERM to the drive's group, KILL to what stays, and a read-back that nothing is left.
stop_the_drive() {
  [ -n "$drive_group" ] || return 0
  kill -TERM -- "-$drive_group" 2>/dev/null || true
  wait_until_the_drive_is_gone "$drive_stop_seconds" && return 0
  kill -KILL -- "-$drive_group" 2>/dev/null || true
  wait_until_the_drive_is_gone "$drive_kill_seconds"
}

# ----------------------------------------------------------------------------------------------- before the gate
# find_mise: sets mise_path, the mise the drive's environment runs.
find_mise() { mise_path="$(command -v mise)" || fail "mise is not on PATH"; }
# require_a_checkout_of_the_app: the checkout is the top of a git work tree whose origin names the app's repository and
# whose mise, under the drive's environment, lists live:journeys. The command only reads it; the cause of a red sits with
# the caller.
require_a_checkout_of_the_app() {
  local repository toplevel origin_url tasks
  repository="$(app_repository "$app")"
  sign_in_step=checkout
  toplevel="$(timeout --foreground "$call_seconds" git -C "$checkout" rev-parse --show-toplevel 2>/dev/null)" ||
    fail "$checkout is no git work tree"
  [ "$toplevel" = "$(realpath -- "$checkout")" ] || fail "$checkout is not the top of its work tree"
  origin_url="$(timeout --foreground "$call_seconds" git -C "$checkout" remote get-url origin 2>/dev/null)" ||
    fail "the checkout $checkout has no origin"
  case "${origin_url%.git}" in
    "https://github.com/$repository" | "git@github.com:$repository" | "ssh://git@github.com/$repository") ;;
    *) fail "the origin of $checkout is not $repository" ;;
  esac
  find_mise
  tasks="$(timeout --foreground "$call_seconds" env -i "${journey_environment[@]}" "$mise_path" -C "$checkout" tasks ls --name-only 2>/dev/null)" ||
    fail "mise cannot list the tasks of $checkout; is it trusted?"
  grep -qxF live:journeys <<<"$tasks" || fail "$checkout declares no task live:journeys"
  checkout="$toplevel"
  sign_in_step=""
}

# forward_signal_to_gate: one TERM to probe-run whatever the signal, then the command keeps waiting for its end.
forward_signal_to_gate() {
  [ "$signal_forwarded" = true ] || kill -TERM "$gate_pid" 2>/dev/null || true
  signal_forwarded=true
}
# run_the_gate: runs the whole run again as `probe-run -k K CAP live_check.sh <app> journeys <checkout> inside-gate`, whose
# own wait is the only one; the fourth argument is an aid for cooperative callers. Never returns: the inner run's exit
# 0, 1, 3 and 4 and its result line stand; 75 (the load stayed high) is skipped; any other status is red. The end of the
# run's namespace ends every process the drive left, the one the cap killed included.
run_the_gate() {
  local gate_status=0
  signal_forwarded=false
  trap - EXIT
  trap forward_signal_to_gate TERM INT
  probe-run -k "$gate_kill_seconds" "$gate_cap_seconds" "$live_check_command" "$app" journeys "$checkout" inside-gate &
  gate_pid=$!
  wait "$gate_pid" || gate_status=$?
  while kill -0 "$gate_pid" 2>/dev/null; do
    wait "$gate_pid" && gate_status=0 || gate_status=$?
  done
  case "$gate_status" in
    0 | 1 | 3 | 4) exit "$gate_status" ;;
    75)
      echo "live:check: $app skipped reason=load"
      exit 3 ;;
  esac
  echo "live:check: $app red (gate=$gate_status)"
  exit 1
}

# ------------------------------------------------------------------------------------------------- inside the gate
# keep_the_cookies_of_host <host>: the jar keeps the lines of that host, so that no Keycloak cookie stands in it during the
# drive; the cleanup needs none, since it signs out at the app.
keep_the_cookies_of_host() {
  awk -F'\t' -v host="$1" '{ domain = $1; sub(/^#HttpOnly_/, "", domain); sub(/^\./, "", domain) } domain == host' \
    "$cookie_jar" >"$cookie_jar.rewritten"
  mv -- "$cookie_jar.rewritten" "$cookie_jar"
}
# cookies_as_storage_state: the jar on stdin as Playwright's storage state on stdout; a line it cannot read ends it with
# 1 and nothing it printed is a result. Session cookies get expires -1 and sameSite is Lax, since curl's jar records neither.
cookies_as_storage_state() {
  awk -F'\t' '
    BEGIN { printf "{\"cookies\": [" }
    {
      domain = $1
      http_only = sub(/^#HttpOnly_/, "", domain) ? "true" : "false"
      if (NF != 7 || $0 ~ /["\\]/ || $0 ~ /[^ -~\t]/ || $5 !~ /^[0-9]+$/ || ($4 != "TRUE" && $4 != "FALSE") || $6 == "") {
        unreadable = 1
        exit 1
      }
      printf "%s{\"name\": \"%s\", \"value\": \"%s\", \"domain\": \"%s\", \"path\": \"%s\", \"expires\": %s, \"httpOnly\": %s, \"secure\": %s, \"sameSite\": \"Lax\"}",
        separator, $6, $7, domain, $3, ($5 == 0 ? -1 : $5), http_only, tolower($4)
      separator = ", "
    }
    END { if (unreadable) exit 1; print "], \"origins\": []}" }
  '
}
# hand_over_the_cookies: the storage state, 0600, then the marker.
hand_over_the_cookies() {
  local host="${origin#*://}" state_file
  state_file="$(storage_state_of "$app")"
  sign_in_step=storage-state
  host="${host%%/*}"
  keep_the_cookies_of_host "${host%%:*}"
  cookies_as_storage_state <"$cookie_jar" >"$state_file" 2>/dev/null || fail "the app's cookies cannot be written as a storage state"
  [ "$(stat -c %a -- "$state_file")" = 600 ] || fail "the storage state is not readable by its owner only"
  : >"$(handed_over_of "$app")"
}
# drive_the_journeys: the app's live:journeys task in a session of its own, its output kept out of the command's and the
# lock closed for it; the command waits for it in the background, so a TERM reaches the trap at once. Sets drive_status
# and drive_group.
drive_the_journeys() {
  drive_status=0
  find_mise
  sign_in_step=journeys
  setsid env -i "${journey_environment[@]}" "$mise_path" -C "$checkout" run live:journeys --origin "$origin" \
    --storage-state "$(storage_state_of "$app")" </dev/null >/dev/null 2>&1 {lock_descriptor}>&- &
  drive_group=$!
  wait "$drive_group" || drive_status=$?
}
# hand_over_to_the_journeys: after the sign-in; maps the app's exit 0, 1 and 3 to green, red and skipped. The cleanup of
# finish stops the drive, signs out with the handed-over cookies and deletes the file.
hand_over_to_the_journeys() {
  hand_over_the_cookies
  drive_the_journeys
  codes+=("journeys=$drive_status")
  case "$drive_status" in
    0) ;;
    3)
      skipped=true
      sign_in_step=""
      exit 3 ;;
    *) fail "the journeys ended with exit $drive_status" ;;
  esac
  sign_in_step=""
}
