#!/usr/bin/env bash
# Proves docs/commands.md PODLOGS-1, PODLOGS-2.
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# systemd does not run in this container, so a fake systemctl answers for the timer and its service. The timer
# has not fired, as after a first install or a manual start, unless FAKE_LAST_TRIGGER sets its last trigger;
# the service's start time is FAKE_LAST_RUN.
fake_bin="$RUNNER_TEMP/fake-systemctl"
mkdir -p "$fake_bin"
cat >"$fake_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *LastTriggerUSec*) echo "${FAKE_LAST_TRIGGER:-n/a}" ;;
  *InactiveExitTimestamp*) echo "$FAKE_LAST_RUN" ;;
  *NextElapseUSecRealtime*) echo "@$(($(date +%s) + 3600))" ;;
  *Result*) echo "$FAKE_RESULT" ;;
  *) echo "fake systemctl: unexpected $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/systemctl"
# A fake stat answers with the creation time in FAKE_BIRTH, fails when FAKE_STAT_FAIL is set, deletes its
# file before failing when FAKE_STAT_VANISH is set, and else is stat.
cat >"$fake_bin/stat" <<'FAKE'
#!/usr/bin/env bash
[ -z "${FAKE_STAT_FAIL:-}" ] || { echo "fake stat: failed" >&2; exit 1; }
[ -z "${FAKE_STAT_VANISH:-}" ] || { rm -f "${@: -1}"; echo "fake stat: vanished" >&2; exit 1; }
[ -n "${FAKE_BIRTH:-}" ] || exec /usr/bin/stat "$@"
printf '%s' "$FAKE_BIRTH"
FAKE
chmod +x "$fake_bin/stat"
# A fake find fails when FAKE_FIND_FAIL is set, as an unreadable directory does, and else is find.
cat >"$fake_bin/find" <<'FAKE'
#!/usr/bin/env bash
[ -z "${FAKE_FIND_FAIL:-}" ] || { echo "fake find: failed" >&2; exit 1; }
exec /usr/bin/find "$@"
FAKE
chmod +x "$fake_bin/find"
check() { PATH="$fake_bin:$PATH" host/pod-logs/scripts/check_pod_logs.sh 2>&1; }
# A breach the check must name: the case, the fake service's last start and result, and the text naming it.
expect_breach() {
  local case_name="$1" last_run="$2" result="$3" named="$4" output
  output="$(FAKE_LAST_RUN="$last_run" FAKE_RESULT="$result" check)" &&
    fail "the check passed $case_name: $output"
  grep -q -- "$named" <<<"$output" || fail "the check did not name $case_name: $output"
  echo "the check fails on $case_name: $(grep -- "$named" <<<"$output")"
}
pods_dir=/var/log/pods
mkdir -p "$pods_dir/ns_pod_1/app"
echo line >"$pods_dir/ns_pod_1/app/0.log"
recent="@$(($(date +%s) - 60))"
output="$(FAKE_LAST_RUN="$recent" FAKE_RESULT=success check)" || fail "the check failed fresh logs: $output"
grep -q "ns_pod_1/app/0.log" <<<"$output" || fail "the check did not name the oldest file: $output"
echo "the check passes fresh logs while the timer has not fired: $output"
output="$(FAKE_LAST_TRIGGER="$recent" FAKE_LAST_RUN=n/a FAKE_RESULT=success check)" ||
  fail "the check failed a timer that fired after a reboot lost the service's start: $output"
echo "the check passes a clean the timer started before a reboot: $output"
expect_breach "a clean that never ran" n/a success \
  "has never run: sudo systemctl start pod-logs-clean.service"
expect_breach "a run 26 hours ago" "@$(($(date +%s) - 26 * 3600))" success "hours ago"
expect_breach "a failed run" "$recent" exit-code "ended with exit-code"
FAKE_FIND_FAIL=1 expect_breach "a listing that failed" "$recent" success \
  "listing the files under $pods_dir failed"
FAKE_STAT_FAIL=1 expect_breach "a stat that failed on a file that stays" "$recent" success \
  "listing the files under $pods_dir failed, so the 30-day bound is unchecked: fake stat: failed"
expect_breach "a failed run with one breach" "$recent" exit-code "1 breach of the 30-day bound"
output="$(FAKE_LAST_RUN=n/a FAKE_RESULT=exit-code check)" && fail "the check passed two breaches"
grep -q "2 breaches of the 30-day bound" <<<"$output" || fail "the check did not count two breaches: $output"
grep -q "sudo systemctl start pod-logs-clean.service, then mise run check:pod-logs" <<<"$output" ||
  fail "the check did not name the rerun of a failed clean: $output"
output="$(FAKE_STAT_VANISH=1 FAKE_LAST_RUN="$recent" FAKE_RESULT=success check)" ||
  fail "the check failed files that vanished before their stat: $output"
grep -q "0 files under $pods_dir" <<<"$output" || fail "the check counted files that vanished: $output"
echo "the check skips files that vanished before their stat: $output"
echo line >"$pods_dir/ns_pod_1/app/0.log"
now="$(date +%s)"
# The check keeps a file up to 29 days old; a minute either side of the boundary stays clear of the clock.
FAKE_BIRTH=$((now - 29 * 86400 + 60)) FAKE_LAST_RUN="$recent" FAKE_RESULT=success check >/dev/null ||
  fail "the check failed a file a minute short of 29 days old"
FAKE_BIRTH=$((now - 29 * 86400 - 60)) expect_breach "a file a minute over 29 days old" "$recent" success \
  "days ago"
FAKE_BIRTH=0 expect_breach "a file without a creation time" "$recent" success "has no creation time"
touch "$pods_dir/ns_pod_1/app/0.log.20261101-000000.gz" "$pods_dir/ns_pod_1/app/0.log.20261101-000000.tmp"
expect_breach "a compressed copy" "$recent" success "0.log.20261101-000000.gz is a compressed copy"
expect_breach "a copy in compression" "$recent" success "0.log.20261101-000000.tmp is a copy"
rm -r "$pods_dir"
output="$(FAKE_LAST_RUN="$recent" FAKE_RESULT=success check)" ||
  fail "the check failed a missing $pods_dir: $output"
[ "$(wc -l <<<"$output")" -eq 1 ] || fail "the check did not pass a missing $pods_dir with one line: $output"
echo "the check passes a missing $pods_dir: $output"
touch "$pods_dir"
expect_breach "a file in place of $pods_dir" "$recent" success \
  "unchecked: $pods_dir is not a directory"
rm "$pods_dir"
