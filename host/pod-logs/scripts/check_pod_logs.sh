#!/usr/bin/env bash
# Check the 30-day bound on the kubelet's pod logs and name every breach. It prints only file names and times and never
# reads a log's contents. pod-logs-clean.service runs it after each clean; `mise run check:pod-logs` runs it by hand.
set -euo pipefail

pods_dir=/var/log/pods
timer=pod-logs-clean.timer
service=pod-logs-clean.service
# pod-logs.conf deletes a file 28 days after its creation and the timer runs daily, so an older file missed a clean.
max_file_age_seconds=$((29 * 24 * 3600))
# The daily timer starts the clean within the last day; the hour on top absorbs its run time.
max_clean_age_seconds=$((25 * 3600))

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
# Prints one NUL-terminated path per file under the pods directory.
list_files() { find "$pods_dir" -type f -print0; }
listing_failed() {
  echo "check-pod-logs: listing the files under $pods_dir failed, so the 30-day bound is unchecked" >&2
  exit 1
}
# Prints the creation time of a file in unix seconds, or nothing when the file vanished since the listing.
file_birth() {
  stat --printf='%W' -- "$1" 2>/dev/null || [ ! -e "$1" ] || listing_failed
}

pods_listing="$(mktemp)"
trap 'rm -f "$pods_listing"' EXIT
no_pod_logs_yet=""
if [ -d "$pods_dir" ]; then
  list_files >"$pods_listing" || listing_failed
elif [ -e "$pods_dir" ]; then
  listing_failed
else
  # k3s creates the directory with its first pod, after a first install has started the timer.
  no_pod_logs_yet=true
fi
while IFS= read -r -d '' file; do
  birth="$(file_birth "$file")"
  [ -n "$birth" ] || continue
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
done <"$pods_listing"

# The service's own start counts, whoever started it: the timer's last trigger stays empty after a manual run.
rerun_hint="sudo systemctl start $service, then mise run check:pod-logs"
last_run="$(unit_time "$service" InactiveExitTimestamp)"
if [ -z "$last_run" ]; then
  breach "$service has never run: $rerun_hint"
elif [ $((now - last_run)) -gt "$max_clean_age_seconds" ]; then
  breach "$service last ran at $(format_time "$last_run"), more than $((max_clean_age_seconds / 3600)) hours ago:"\
" $rerun_hint"
fi
result="$(systemctl show "$service" --property=Result --value)"
[ "$result" = success ] ||
  breach "the last run of $service ended with $result, which stays until the service runs again: $rerun_hint"

[ "$breaches" -eq 0 ] || {
  plural=breaches
  [ "$breaches" -ne 1 ] || plural=breach
  echo "check-pod-logs: $breaches $plural of the 30-day bound" >&2
  exit 1
}
oldest="no file"
[ -z "$oldest_file" ] || oldest="the oldest $oldest_file, created at $(format_time "$oldest_birth")"
# systemd schedules the next run only once the current one ends, so the clean's own check names none.
next_run="$(unit_time "$timer" NextElapseUSecRealtime)"
[ -z "$next_run" ] || next_run=" and runs next at $(format_time "$next_run")"
files_summary="$file_count files under $pods_dir, $oldest"
[ -z "$no_pod_logs_yet" ] || files_summary="no pod logs yet, $pods_dir does not exist"
echo "check-pod-logs: $files_summary;" \
  "$service last ran at $(format_time "$last_run")$next_run"
