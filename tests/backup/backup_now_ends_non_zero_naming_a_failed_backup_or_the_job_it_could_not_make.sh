#!/usr/bin/env bash
# Drive scripts/backup_now.sh, the script `mise run backup:now` runs, against a fake kubectl, for the outcome the cluster
# cannot arrange: a Backup that ends in a reason other than Succeeded, or does not complete within the wait, ends the task
# non-zero, names the Backup and its reason, and makes no restore test Job; and a Backup that succeeded followed by a Job
# that cannot be made names both; a Job that ends Failed after a Backup that Succeeded names both; and a namespace without
# exactly one Schedule named backup or postgres, or without the CronJob restore-test, is refused with no object made.
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
# outcome of the wait, the Backup's final reason and the creation of the Job, FAKE_SCHEDULES the names of the Schedules,
# FAKE_CRONJOB what the CronJob read prints and FAKE_JOB_STATE the conditions the made Job reports.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$FAKE_CALLS"
case "$*" in
  *"get schedules.k8up.io"*)
    printf '{"items":['
    separator=
    for name in $FAKE_SCHEDULES; do
      printf '%s{"metadata":{"name":"%s"},"spec":{"backend":{"rest":{"url":"rest:http://repository"}},"podConfigRef":{"name":"backup"}}}' "$separator" "$name"
      separator=,
    done
    printf ']}' ;;
  *"get cronjob restore-test"*) printf '%s' "$FAKE_CRONJOB" ;;
  *"get job "*) printf '%s' "$FAKE_JOB_STATE" ;;
  *"create --filename -"*) cat >/dev/null; echo backup.k8up.io/backup-now-fake ;;
  *" wait backup/"*) exit "$FAKE_WAIT_STATUS" ;;
  *"get backup backup-now-fake"*) printf '%s' "$FAKE_REASON" ;;
  *"create job"*) exit "$FAKE_JOB_STATUS" ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/kubectl"

# drive <wait status> <reason> <job status>: sets task_status and task_output; the Schedules, the CronJob and the made Job's
# state are one Schedule `backup`, the CronJob and a Complete Job unless the caller sets FAKE_SCHEDULES, FAKE_CRONJOB or
# FAKE_JOB_STATE.
task_status=0
task_output=
drive() {
  : >"$calls"
  task_status=0
  task_output="$(cd "$repository_root" && PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl KUBECONFIG=/nonexistent FAKE_CALLS="$calls" \
    FAKE_SCHEDULES="${FAKE_SCHEDULES-backup}" FAKE_CRONJOB="${FAKE_CRONJOB-cronjob.batch/restore-test}" FAKE_JOB_STATE="${FAKE_JOB_STATE:-Complete}" \
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

FAKE_JOB_STATE=Failed drive 0 Succeeded 0
{ [ "$task_status" = 1 ] && [[ $task_output == *"the restore test Job restore-test-now-fake of somewhere Failed"* ]] &&
  [[ $task_output == *"the Backup backup-now-fake Succeeded"* ]]; } ||
  fail "a restore test Job that Failed ended $task_status with '$task_output'"
echo "a restore test Job that Failed ends the task non-zero naming the Job and the Backup that Succeeded"

# refuses_with <text> <label>: the task ended 1, said <text> and created neither a Backup nor a Job.
refuses_with() {
  { [ "$task_status" = 1 ] && [[ $task_output == *"$1"* ]]; } || fail "$2 ended $task_status with '$task_output'"
  ! grep -q "create" "$calls" || fail "$2 still created an object"
  echo "$2 is refused with '$1' and creates nothing"
}

FAKE_SCHEDULES= drive 0 Succeeded 0
refuses_with "somewhere holds 0 k8up Schedules named backup or postgres" "a namespace without a Schedule"
FAKE_SCHEDULES="backup postgres" drive 0 Succeeded 0
refuses_with "somewhere holds 2 k8up Schedules named backup or postgres" "a namespace with a Schedule backup and a Schedule postgres"
FAKE_SCHEDULES="other" drive 0 Succeeded 0
refuses_with "somewhere holds 0 k8up Schedules named backup or postgres" "a namespace whose only Schedule has another name"
FAKE_CRONJOB= drive 0 Succeeded 0
refuses_with "somewhere holds no CronJob restore-test" "a namespace without the CronJob restore-test"
