#!/usr/bin/env bash
# Check the 30-day bound on the kubelet's pod logs and name every breach. It prints only file names and times and never
# reads a log's contents. pod-logs-clean.service runs it after each clean; `mise run check:pod-logs` runs it by hand.
set -euo pipefail

pods_dir=/var/log/pods
timer=pod-logs-clean.timer
service=pod-logs-clean.service
# pod-logs.conf deletes a file 28 days after its creation and the timer runs daily, so an older file missed a clean.
max_file_age_seconds=$((29 * 24 * 3600))
# A daily timer has fired within the last day; the hour on top absorbs its run time.
max_timer_age_seconds=$((25 * 3600))

now="$(date +%s)"
breaches=0
breach() {
  echo "check-pod-logs: $1" >&2
  breaches=$((breaches + 1))
}
format_time() { date --utc --date="@$1" +%Y-%m-%dT%H:%M:%SZ; }
# Prints the unix seconds of a timestamp property, or nothing when systemd records none.
unit_time() {
  local value
  value="$(systemctl show "$1" --property="$2" --value --timestamp=unix)"
  [[ $value =~ ^@([0-9]+)$ ]] && echo "${BASH_REMATCH[1]}" || true
}

file_count=0
oldest_file=""
oldest_birth=""
while IFS=' ' read -r -d '' birth file; do
  file_count=$((file_count + 1))
  case "$file" in
    *.gz) breach "$file is a compressed copy, created after its oldest line" ;;
    *.tmp) breach "$file is a copy the kubelet is compressing" ;;
  esac
  # stat reports 0 where the filesystem records no creation time, and the clean cannot judge such a file.
  if [ "$birth" -eq 0 ]; then
    breach "$file has no creation time"
    continue
  fi
  [ $((now - birth)) -le "$max_file_age_seconds" ] ||
    breach "$file was created at $(format_time "$birth"), more than $((max_file_age_seconds / 86400)) days ago"
  if [ -z "$oldest_birth" ] || [ "$birth" -lt "$oldest_birth" ]; then
    oldest_birth="$birth"
    oldest_file="$file"
  fi
done < <(find "$pods_dir" -type f -exec stat --printf='%W %n\0' {} +)

last_run="$(unit_time "$timer" LastTriggerUSec)"
if [ -z "$last_run" ]; then
  breach "$timer has never run"
elif [ $((now - last_run)) -gt "$max_timer_age_seconds" ]; then
  breach "$timer last ran at $(format_time "$last_run"), more than $((max_timer_age_seconds / 3600)) hours ago"
fi
result="$(systemctl show "$service" --property=Result --value)"
[ "$result" = success ] || breach "the last run of $service ended with $result"

[ "$breaches" -eq 0 ] || {
  echo "check-pod-logs: $breaches breaches of the 30-day bound" >&2
  exit 1
}
oldest="no file"
[ -z "$oldest_file" ] || oldest="the oldest $oldest_file, created at $(format_time "$oldest_birth")"
# systemd schedules the next run only once the current one ends, so the clean's own check names none.
next_run="$(unit_time "$timer" NextElapseUSecRealtime)"
[ -z "$next_run" ] || next_run=" and runs next at $(format_time "$next_run")"
echo "check-pod-logs: $file_count files under $pods_dir, $oldest;" \
  "$timer last ran at $(format_time "$last_run")$next_run"
