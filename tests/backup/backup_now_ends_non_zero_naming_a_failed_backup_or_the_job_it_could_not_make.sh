#!/usr/bin/env bash
# Drive scripts/backup_now.sh, the script `mise run backup:now` runs, against a fake kubectl, for the outcome the cluster
# cannot arrange: a Backup that ends in a reason other than Succeeded, or does not complete within the wait, ends the task
# non-zero, names the Backup and its reason, and makes no restore test Job; and a Backup that succeeded followed by a Job
# that cannot be made names both; a Job that ends Failed after a Backup that Succeeded names both; a namespace without
# exactly one Schedule named backup or postgres, or without the CronJob restore-test, is refused with no object made; and
# where the layer has the PreBackupPod files, every end of the seed Pod that the cluster cannot arrange on demand names its
# sentence and makes no Backup.
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
# FAKE_CRONJOB what the CronJob read prints and FAKE_JOB_STATE the conditions the made Job reports. Without FAKE_PREBACKUP
# the layer has no PreBackupPod. Otherwise the first read of the Pod backup-seed prints FAKE_EARLIER (nothing: none) and the
# n'th later one the file $FAKE_POLLS/<n>.json, the last file once they run out; FAKE_CREATE_POD_STATUS and
# FAKE_DELETE_STATUS are the exit statuses of the creation and the deletion of that Pod.
cat >"$fake_bin/sleep" <<'FAKE'
#!/bin/sh
FAKE
chmod +x "$fake_bin/sleep"
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
  *"get prebackuppods.k8up.io"*)
    [ -z "${FAKE_PREBACKUP:-}" ] ||
      echo '{"spec":{"pod":{"spec":{"containers":[{"name":"postgres"},{"name":"stager"}],"volumes":[{"name":"password"},{"name":"scratch"}]}}}}' ;;
  *"get pod backup-seed"*)
    echo >>"$FAKE_COUNT"
    reads="$(wc -l <"$FAKE_COUNT")"
    if [ "$reads" = 1 ]; then
      printf '%s' "${FAKE_EARLIER:-}"
    else
      poll="$FAKE_POLLS/$((reads - 1)).json"
      [ -e "$poll" ] || poll="$(find "$FAKE_POLLS" -name '*.json' | sort -V | tail -n 1)"
      cat "$poll"
    fi ;;
  *"delete pod backup-seed"*) exit "${FAKE_DELETE_STATUS:-0}" ;;
  *"create --filename -"*)
    manifest="$(cat)"
    if [[ $manifest == *'"kind": "Pod"'* ]]; then
      [[ $manifest != *'"name": "postgres"'* && $manifest != *'"name": "password"'* && $manifest == *STAGE_SEED* ]] || exit 3
      echo "create-pod" >>"$FAKE_CALLS"
      exit "${FAKE_CREATE_POD_STATUS:-0}"
    fi
    echo "create-backup" >>"$FAKE_CALLS"
    echo backup.k8up.io/backup-now-fake ;;
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
  : >"$work_directory/count"
  task_output="$(cd "$repository_root" && PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl KUBECONFIG=/nonexistent FAKE_CALLS="$calls" \
    FAKE_COUNT="$work_directory/count" FAKE_POLLS="$work_directory/polls" \
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

# The seed Pod. poll <n> <phase> <reason> <stager> <copy> <age seconds> writes the n'th answer of the Pod read, where a
# container is "none", "running", "waiting" or "terminated:<exit>:<message>", and the Pod is <age> seconds old.
mkdir "$work_directory/polls"
container_status() {
  case "$2" in
    none) return 0 ;;
    running) printf '{"name":"%s","state":{"running":{}}}' "$1" ;;
    waiting) printf '{"name":"%s","state":{"waiting":{}}}' "$1" ;;
    terminated:*) IFS=: read -r _ code message <<<"$2"
      printf '{"name":"%s","state":{"terminated":{"exitCode":%s,"message":"%s"}}}' "$1" "$code" "$message" ;;
  esac
}
pod_json() {
  local statuses
  statuses="$(container_status stager "$3"),$(container_status copy "$4")"
  printf '{"metadata":{"creationTimestamp":"%s"},"status":{"phase":"%s","reason":"%s","containerStatuses":[%s]}}' \
    "$(date -u --date "$5 seconds ago" +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$(sed 's/^,//; s/,$//' <<<"$statuses")"
}
poll() { pod_json "${@:2}" >"$work_directory/polls/$1.json"; }
seeded=terminated:0:seeded

# seed_row <label> <sentence>: the seed ended the task 1 with the sentence, after the seed Pod was made and deleted, and no
# Backup was made.
seed_row() {
  { [ "$task_status" = 1 ] && [[ $task_output == *"$2"* ]] && [[ $task_output == *"no Backup was made"* ]]; } ||
    fail "$1 ended $task_status with '$task_output'"
  ! grep -q create-backup "$calls" || fail "$1 still made a Backup"
  grep -q create-pod "$calls" || fail "$1 made no seed Pod"
  echo "$1 ends the task non-zero with '$2' and makes no Backup"
}
export FAKE_PREBACKUP=1

rm -f "$work_directory"/polls/*.json
poll 1 Failed DeadlineExceeded "terminated:0:" running 100
drive 0 Succeeded 0
seed_row "a seed Pod cut by its backstop" "reached its 1-hour backstop before the copies were staged"

poll 1 Failed "" terminated:3:refused-room\ 10\ 20\ 30\ 5 none 100
drive 0 Succeeded 0
seed_row "a seed that refused for room" "the seed of somewhere refused: the copies need 10 bytes beside the kubelet's eviction margin of 5, and the staging volume has 20 of 30 bytes free; free disk space first (mise run disk shows what holds it)"
poll 1 Failed "" terminated:4:refused-held\ 2 none 100
drive 0 Succeeded 0
seed_row "a seed that the guard refused" "the seed of somewhere refused: 2 other pods mount the staging claim; wait until they end, then run it again"
poll 1 Failed Evicted running none 100
drive 0 Succeeded 0
seed_row "an evicted seed Pod" "ended Failed with reason Evicted"
poll 1 Failed "" terminated:1:failed\ pre-sync\ 23 none 100
drive 0 Succeeded 0
seed_row "a seed whose step failed with an exit" "the seed of somewhere failed at pre-sync with exit 23"
poll 1 Failed "" terminated:1:failed\ fit\ - none 100
drive 0 Succeeded 0
seed_row "a seed whose step failed without an exit" "the seed of somewhere failed at fit; no Backup"
poll 1 Succeeded "" terminated:0: none 100
drive 0 Succeeded 0
seed_row "a seed whose outcome is unreadable" "the seed's stager of somewhere ended with exit 0 and no outcome backup:now reads"
poll 1 Running "" running terminated:1: 100
drive 0 Succeeded 0
seed_row "a seed whose copy container ended non-zero" "the seed's copy container of somewhere ended with exit 1 before its step reported"
poll 1 Pending "" waiting none 301
drive 0 Succeeded 0
seed_row "a seed Pod whose stager never started" "did not start within 5 minutes"
poll 1 Running "" running none 4300
drive 0 Succeeded 0
seed_row "a seed Pod that does not end in its backstop and ten minutes" "did not end within 1 hours"
FAKE_CREATE_POD_STATUS=1 drive 0 Succeeded 0
{ [ "$task_status" = 1 ] && [[ $task_output == *"could not create the seed Pod backup-seed in somewhere; no Backup was made"* ]]; } &&
  ! grep -q create-backup "$calls" || fail "a seed Pod that could not be made ended $task_status with '$task_output'"
echo "a seed Pod that cannot be made ends the task non-zero naming it and makes no Backup"

# A copy container that ended 0 ends nothing; the stager's own outcome does, and then the Backup is made and proven.
poll 1 Running "" running terminated:0: 10
poll 2 Succeeded "" $seeded terminated:0: 20
drive 0 Succeeded 0
{ [ "$task_status" = 0 ] && [[ $task_output == *"the seed of somewhere staged its copies"* ]] && grep -q create-backup "$calls" &&
  grep -q "delete pod backup-seed" "$calls"; } ||
  fail "a seed that ended 0 beside a copy container that ended 0 exited $task_status with '$task_output'"
echo "a copy container that ended 0 ends nothing: the stager's seeded does, the seed Pod is deleted and the Backup is made"

# An earlier seed Pod: one that ended, or never started, is deleted and the run goes on; one that lives refuses.
for earlier in "Succeeded 100" "Failed 100" "Pending 301"; do
  poll 1 Succeeded "" $seeded none 10
  read -r earlier_phase earlier_age <<<"$earlier"
  FAKE_EARLIER="$(pod_json "$earlier_phase" "" none none "$earlier_age")" drive 0 Succeeded 0
  { [ "$task_status" = 0 ] && [[ $task_output == *"the earlier seed Pod backup-seed of somewhere "* ]] && grep -q create-backup "$calls"; } ||
    fail "an earlier seed Pod $earlier exited $task_status with '$task_output'"
  echo "an earlier seed Pod ($earlier) is deleted with its sentence and the run goes on to its seed and Backup"
done
FAKE_EARLIER="$(pod_json Running "" running none 100)" drive 0 Succeeded 0
{ [ "$task_status" = 1 ] && [[ $task_output == *"another run's seed Pod backup-seed of somewhere is still running"* ]] && [[ $task_output == *"nothing was made"* ]] &&
  ! grep -q "create\|delete" "$calls"; } || fail "a live seed Pod exited $task_status with '$task_output'"
echo "a live seed Pod of another run refuses, deleting and making nothing"
FAKE_DELETE_STATUS=1 FAKE_EARLIER="$(pod_json Failed "" none none 100)" drive 0 Succeeded 0
{ [ "$task_status" = 1 ] && [[ $task_output == *"did not go within 2 minutes; nothing was made"* ]] && ! grep -q "create" "$calls"; } ||
  fail "an earlier seed Pod that does not go exited $task_status with '$task_output'"
echo "an earlier seed Pod that does not go refuses, making nothing"
