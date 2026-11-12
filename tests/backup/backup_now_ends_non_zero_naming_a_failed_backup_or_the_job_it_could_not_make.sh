#!/usr/bin/env bash
# Drive `mise run backup:now` against a fake kubectl, for the outcome the cluster cannot arrange: a Backup that ends in a
# reason other than Succeeded, or does not complete within the wait, ends the task non-zero, names the Backup and its
# reason, and makes no restore test Job; and a Backup that succeeded followed by a Job that cannot be made names both.
# Usage: mise exec -- tests/backup/backup_now_ends_non_zero_naming_a_failed_backup_or_the_job_it_could_not_make.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
calls="$work_directory/calls"

# The fake answers what the task reads and records every call; FAKE_WAIT_STATUS, FAKE_REASON and FAKE_JOB_STATUS choose the
# outcome of the wait, the Backup's final reason and the creation of the Job.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$FAKE_CALLS"
case "$*" in
  *"get schedules.k8up.io"*)
    printf '%s' '{"items":[{"metadata":{"name":"backup"},"spec":{"backend":{"rest":{"url":"rest:http://repository"}},"podConfigRef":{"name":"backup"}}}]}' ;;
  *"get cronjob restore-test"*) echo cronjob.batch/restore-test ;;
  *"create --filename -"*) cat >/dev/null; echo backup.k8up.io/backup-now-fake ;;
  *" wait backup/"*) exit "$FAKE_WAIT_STATUS" ;;
  *"get backup backup-now-fake"*) printf '%s' "$FAKE_REASON" ;;
  *"create job"*) exit "$FAKE_JOB_STATUS" ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/kubectl"

# drive <wait status> <reason> <job status>: sets task_status and task_output.
task_status=0
task_output=
drive() {
  : >"$calls"
  task_status=0
  task_output="$(cd "$repository_root" && PATH="$fake_bin:$PATH" KUBECONFIG=/nonexistent FAKE_CALLS="$calls" \
    FAKE_WAIT_STATUS="$1" FAKE_REASON="$2" FAKE_JOB_STATUS="$3" scripts/backup_now.sh somewhere 2>&1)" || task_status=$?
}
made_a_job() { grep -q "create job" "$calls"; }

drive 0 Failed 0
{ [ "$task_status" = 1 ] && [[ $task_output == *"Backup backup-now-fake of somewhere ended with reason Failed"* ]]; } ||
  fail "a Backup that Failed ended $task_status with '$task_output'"
! made_a_job || fail "a restore test Job was made after a Backup that Failed"
echo "a Backup that Failed ends the task non-zero naming the Backup and the reason, and makes no restore test Job"

drive 1 "" 0
{ [ "$task_status" = 1 ] && [[ $task_output == *"Backup backup-now-fake of somewhere did not complete"* ]]; } ||
  fail "a Backup that did not complete ended $task_status with '$task_output'"
! made_a_job || fail "a restore test Job was made after a Backup that did not complete"
echo "a Backup that does not complete ends the task non-zero naming the Backup, and makes no restore test Job"

drive 0 Succeeded 1
{ [ "$task_status" = 1 ] && [[ $task_output == *"Backup backup-now-fake of somewhere Succeeded"* ]] &&
  [[ $task_output == *"could not create the Job restore-test-now-fake"* ]]; } ||
  fail "a Job that could not be made ended $task_status with '$task_output'"
echo "a restore test Job that cannot be made ends the task non-zero naming the Job and the Backup that Succeeded"
