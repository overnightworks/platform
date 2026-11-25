#!/usr/bin/env bash
# Proves docs/operations.md OPS-24: the unit that runs `live:report nightly` and the timer that starts it, read from
# mise.toml, so no value chosen there is restated here: the timer's calendar parses and names the UTC zone, the timer starts
# that one service, the service's stop delay exceeds the kill delay of live:check's own `timeout -k`, and its start limit
# stays below the timer's period, so a run ends before the next night starts.
# Usage: tests/live-check/nightly_timer_parses_in_utc_and_its_start_limit_stays_below_its_period.sh
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
command -v systemd-analyze >/dev/null || apt-get install --yes --no-install-recommends systemd >/dev/null
units=.bootstrap.linux.systemd.units
unit_value() { mise exec -- yq -p toml -oy "$units[\"$1\"].$2 // \"\"" mise.toml; }
seconds_of_timespan() { systemd-analyze timespan "$1" | awk '/^ *[^ ]+s: /{ print int($2 / 1000000) }'; }

service="$(mise exec -- yq -p toml -oy "$units | to_entries | .[] | select((.value.exec_start // \"\") | test(\"live:report nightly\$\")) | .key" mise.toml)"
[ "$(wc -l <<<"$service")" = 1 ] && [ -n "$service" ] || fail "mise.toml declares not exactly one service that runs live:report nightly: '$service'"
timers="$(mise exec -- yq -p toml -oy "$units | to_entries | .[] | select(.value.unit == \"$service\") | .key" mise.toml)"
[ "$(wc -l <<<"$timers")" = 1 ] && [ -n "$timers" ] || fail "mise.toml declares not exactly one timer for the service $service: '$timers'"
timer="$timers"
[ -n "$(unit_value "$timer" on_calendar)" ] || fail "the timer $timer sets no on_calendar"

# The calendar parses, names the zone that keeps its hour apart from the DST of the PC's own, and its elapses are one
# period apart.
calendar="$(unit_value "$timer" on_calendar)"
grep -qw UTC <<<"$calendar" || fail "the calendar '$calendar' names no UTC zone"
elapses="$(TZ=UTC systemd-analyze calendar --iterations=3 "$calendar")" || fail "systemd-analyze does not parse the calendar '$calendar'"
mapfile -t elapse_times < <(sed -n 's/^ *Next elapse: //p; s/^ *Iteration #[0-9]*: //p' <<<"$elapses" | while read -r line; do date -d "$line" +%s; done)
[ "${#elapse_times[@]}" = 3 ] || fail "the calendar '$calendar' yields ${#elapse_times[@]} elapses, not 3"
period=$((elapse_times[1] - elapse_times[0]))
[ "$period" -eq $((elapse_times[2] - elapse_times[1])) ] || fail "the elapses of '$calendar' are not evenly spaced"

# live:check ends its own attempt with `timeout -k <kill delay> <limit>`; a stop's cleanup must fit the stop delay.
check_run="$(mise exec -- yq -p toml -oy '.tasks["live:check"].run' mise.toml)"
kill_delay="$(sed -n 's/.*timeout -k \([0-9][0-9]*\) .*/\1/p' <<<"$check_run")"
[ -n "$kill_delay" ] || fail "the task live:check runs no 'timeout -k <seconds>': $check_run"
stop_seconds="$(seconds_of_timespan "$(unit_value "$service" timeout_stop_sec)")"
[ "$stop_seconds" -gt "$kill_delay" ] || fail "timeout_stop_sec is $stop_seconds seconds, not above live:check's kill delay of $kill_delay"

# A run cut by the start limit is over before the next elapse.
start_seconds="$(seconds_of_timespan "$(unit_value "$service" timeout_start_sec)")"
[ "$start_seconds" -gt 0 ] || fail "the service $service sets no timeout_start_sec"
[ "$start_seconds" -lt "$period" ] || fail "timeout_start_sec is $start_seconds seconds, not below the timer's period of $period"
echo "the timer $timer starts $service at '$calendar', every $period seconds, with a start limit of $start_seconds seconds and a stop delay of $stop_seconds above live:check's $kill_delay"
