#!/usr/bin/env bash
# Drive `mise run db:load-dump` and tests/postgres/interrupt_load.sh against fake kubectl, flux, pg_restore, pg_dump and
# mise on PATH: the outcomes the loader owes where a command fails, a signal arrives or a table is empty, none of which
# the cluster proofs can arrange on demand. The fakes run the remote commands locally, with the ConfigMap postgres's
# table-digests.sh, so the task compares the fake dump with the fake database as in the container.
# Usage: mise exec -- tests/postgres/load_dump.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
fail() { echo "load_dump: $1" >&2; exit 1; }

cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  # The loader's steps: sh -c <script> <step> <argument>..., one call each, answered by FAKE_* variables.
  *" exec db-load-"*)
    while [ "$1" != -- ]; do shift; done
    shift 4
    step="$1"
    echo "$step" >>"$FAKE_DIR/steps"
    [ "${FAKE_STEP_FAILS:-}" != "$step" ] || exit 1
    case "$step" in
      source)
        [ -z "${FAKE_SOURCE_UNREADABLE:-}" ] || exit 2
        [ -z "${FAKE_NO_SNAPSHOT:-}" ] || exit 3
        echo "snapshot fake-snapshot"
        echo "bucket 2 1000 1"
        echo "claim 3 300 1"
        echo "filesystem ${FAKE_FREE_BYTES:-100000000000} 200000000000" ;;
      restore-bucket | restore-claim | check) echo "3 300 $([ "${FAKE_DIFFERS:-}" = "$step" ] && echo 5 || echo 0)" ;;
      count) echo "${FAKE_BUCKET_OBJECTS:-0} ${FAKE_BUCKET_BYTES:-0}" ;;
    esac ;;
  *"get cronjob"*) cat "$FAKE_CRONJOB" ;;
  *"get --raw"*)
    [ -z "${FAKE_CONFIGZ_FAILS:-}" ] || exit 1
    default_configz='{"kubeletconfig":{"evictionHard":{"nodefs.available":"10%","imagefs.available":"15%"}}}'
    echo "${FAKE_CONFIGZ:-$default_configz}" ;;
  *"get pod "*nodeName*) echo fake-node ;;
  *"get pod "*status.reason*) printf '%s' "${FAKE_POD_REASON:-}" ;;
  *"get kustomization"*"--output name"*)
    [ -z "${FAKE_NO_KUSTOMIZATION:-}" ] || exit 0
    echo "kustomization.kustomize.toolkit.fluxcd.io/x" ;;
  *"get kustomization"*)
    [ -z "${FAKE_READ_SUSPEND_FAILS:-}" ] || { echo "fake kubectl: the server is unreachable" >&2; exit 1; }
    printf '%s' "${FAKE_SUSPENDED:-}" ;;
  *pg_stat_activity*)
    # FAKE_SESSION_STAYS: another session that never leaves.
    [ -z "${FAKE_SESSION_STAYS:-}" ] || { echo 1; exit 0; }
    # FAKE_SESSION_AFTER_LOAD: another session that joins once the restore has run.
    [ -z "${FAKE_SESSION_AFTER_LOAD:-}" ] || [ ! -e "$FAKE_DIR/restored" ] || { echo 1; exit 0; }
    # A lingering restore's backend: seen once, then its commit is done.
    if [ -e "$FAKE_DIR/committing" ]; then
      rm "$FAKE_DIR/committing"
      : >"$FAKE_DIR/committed"
      echo 1
    else echo 0; fi ;;
  *relkind*) echo "${FAKE_UNFINGERPRINTED:-0}" ;;
  */proc/*)
    # FAKE_RESTORE_LINGERS: the restore's process outlives the load's status by two listings and ends while its
    # backend still commits.
    [ -n "${FAKE_RESTORE_LINGERS:-}" ] && [ -e "$FAKE_DIR/restored" ] || exit 0
    echo >>"$FAKE_DIR/listings"
    listings="$(wc -l <"$FAKE_DIR/listings")"
    [ "$listings" -gt 2 ] || exit 1
    [ "$listings" != 3 ] || : >"$FAKE_DIR/committing" ;;
  *"get configmap"*)
    # The ConfigMap postgres's backup-claim; FAKE_CLAIM names the claim a layer with files declares.
    [ -z "${FAKE_CLAIM_READ_FAILS:-}" ] || { echo "fake kubectl: the server is unreachable" >&2; exit 1; }
    printf '%s' "${FAKE_CLAIM:-}" ;;
  *"get prebackuppod"*)
    # FAKE_BUCKET: the layer's PreBackupPod has the container bucket, with the backup's key file; FAKE_BUCKET_APPEARS:
    # it has it only from the second read on.
    bucket=
    echo >>"$FAKE_DIR/prebackuppod-reads"
    [ -z "${FAKE_BUCKET:-}" ] && { [ -z "${FAKE_BUCKET_APPEARS:-}" ] || [ "$(wc -l <"$FAKE_DIR/prebackuppod-reads")" -lt 2 ]; } ||
      bucket=',{"name":"bucket","image":"rclone-image","env":[{"name":"BUCKET","value":"x"},{"name":"AWS_SHARED_CREDENTIALS_FILE","value":"/backup/key"}],"securityContext":{"runAsGroup":1000}}'
    echo '{"spec":{"pod":{"spec":{"securityContext":{"runAsUser":1000},"containers":[{"name":"copy","image":"rsync-image"}'"$bucket"']}}}}' ;;
  *" create "*)
    manifest="$(cat)"
    name="$(yq --input-format json '.metadata.name' <<<"$manifest")"
    printf '%s' "$manifest" >"$FAKE_DIR/pod-$name.json"
    : >"$FAKE_DIR/started-$name" ;;
  *"delete pod"*)
    echo "$*" >>"$FAKE_DIR/deleted"
    [ ! -e "$FAKE_DIR/restored" ] || echo "$*" >>"$FAKE_DIR/deleted-after-load"
    [ -z "${FAKE_DELETE_FAILS:-}" ] || [ ! -e "$FAKE_DIR/started-db-load-snapshot" ] ;;
  *"get pods"*)
    # FAKE_PODS names a file holding the namespace's Pod list; without it the namespace has no Pod.
    if [ -n "${FAKE_PODS:-}" ]; then cat "$FAKE_PODS"; else echo "items: []"; fi ;;
  *" wait "*) echo "$*" >>"$FAKE_DIR/waited" ;;
  *"get deployments"* | *"get jobs"* | *"delete job"* | *" scale "* | *"rollout status"*) ;;
  *" exec "*)
    while [ "$1" != -- ]; do shift; done
    shift
    case "$*" in
      *check-key-tables.sh*)
        : >"$FAKE_DIR/verifying"
        [ -z "${FAKE_VERIFY_HANGS:-}" ] || sleep 60
        echo "key_table: 1 rows, 1 COPY lines in the dump, equal" ;;
      *)
        # The task's sh runs in the container as busybox ash, which has pipefail; the runner's sh may not.
        if [ "$1" = sh ]; then set -- bash "${@:2}"; fi
        set -- "${@//sh \/etc\/postgres-checks\//bash $FAKE_CHECKS/}"
        "$@" ;;
    esac ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 1 ;;
esac
FAKE
cat >"$fake_bin/flux" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >>"$FAKE_DIR/flux.log"
[ "$1" != resume ] || [ -z "${FAKE_RESUME_FAILS:-}" ]
FAKE
cat >"$fake_bin/pg_restore" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *--data-only*) cat "$FAKE_DUMP_SQL" ;;
  *)
    cat >/dev/null
    : >"$FAKE_DIR/restored"
    if [ -n "${FAKE_RESTORE_INTERRUPTED:-}" ]; then
      # Committed, then a Ctrl-C reaches the task's shell, the fake kubectl's parent, before the status does.
      : >"$FAKE_DIR/committed"
      kill -INT "$(ps -o ppid= -p "$PPID")"
    fi
    [ -z "${FAKE_RESTORE_FAILS:-}" ] ;;
esac
FAKE
# FAKE_PG_DUMP_FAILS_AT and FAKE_PG_DUMP_BLOCKS_AT name the call, counted from 1 in each cell, that fails or waits for
# the file release; a committed restore adds a row.
cat >"$fake_bin/pg_dump" <<'FAKE'
#!/usr/bin/env bash
echo >>"$FAKE_DIR/pg_dump-calls"
call="$(wc -l <"$FAKE_DIR/pg_dump-calls")"
[ "$call" != "${FAKE_PG_DUMP_FAILS_AT:-}" ] || exit 1
if [ "$call" = "${FAKE_PG_DUMP_BLOCKS_AT:-}" ]; then
  : >"$FAKE_DIR/dumping"
  until [ -e "$FAKE_DIR/release" ]; do sleep 0.1; done
fi
cat "$FAKE_LOADED_SQL"
[ ! -e "$FAKE_DIR/committed" ] || echo committed
FAKE
cat >"$fake_bin/chmod" <<'FAKE'
#!/usr/bin/env bash
[ -z "${FAKE_DIR:-}" ] || echo "$(stat -c %a "$2")" >>"$FAKE_DIR/created-at"
exec /bin/chmod "$@"
FAKE
chmod +x "$fake_bin"/*
export FAKE_CHECKS="$work_directory/postgres-checks" FAKE_CRONJOB="$work_directory/restore-test.json"
yq --output-format json 'select(.kind == "CronJob")' "$repository_root/infrastructure/postgres/backup/backup.yaml" >"$FAKE_CRONJOB"
mkdir "$FAKE_CHECKS"
yq 'select(.kind == "ConfigMap") | .data."table-digests.sh"' "$repository_root/infrastructure/postgres/postgres.yaml" \
  >"$FAKE_CHECKS/table-digests.sh"
# mise puts its own kubectl and flux before PATH, so the task must not load them.
# KUBECONFIG names no file, so a call that leaks to a real kubectl fails instead of reaching a cluster.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux2 KUBECONFIG="$work_directory/no-kubeconfig"
cd "$repository_root"

dump="$work_directory/dump"
printf 'dump' >"$dump"
# Runs mise run db:load-dump "$@" and sets status, output and flux_calls (the verbs the fake flux got).
run_loader() {
  export FAKE_DIR="$work_directory/state-$cell"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/flux.log"
  status=0
  output="$(mise run db:load-dump "$@" 2>&1)" || status=$?
  flux_calls="$(tr '\n' ' ' <"$FAKE_DIR/flux.log")"
}
# Starts mise run db:load-dump "$@" in a session of its own and returns once marker_test, a command that reads
# $FAKE_DIR, succeeds; it sets FAKE_DIR and loader, and the shell's EXIT kills the session. The cell ends the loader and
# waits for it.
start_loader_in_background() {
  local marker_test="$1" never_reached="$2"
  shift 2
  export FAKE_DIR="$work_directory/state-$cell"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/flux.log"
  setsid mise run db:load-dump "$@" >"$FAKE_DIR/output" 2>&1 &
  loader=$!
  trap 'pkill -KILL --session "$loader" 2>/dev/null || true; wait "$loader" 2>/dev/null || true' EXIT
  for _ in $(seq 150); do eval "$marker_test" && return; sleep 0.2; done
  fail "the loader never reached $never_reached"
}
sql_for() {
  local name
  for name; do
    printf 'COPY public.%s (id) FROM stdin;\n' "$name"
    [ "$name" = filled ] && printf '1\n2\n'
    printf '\\.\n\n'
  done
}
sql_for filled empty >"$work_directory/dump.sql"
sql_for filled empty >"$work_directory/same.sql"
sql_for filled empty extra_empty >"$work_directory/extra.sql"
export FAKE_DUMP_SQL="$work_directory/dump.sql" FAKE_LOADED_SQL="$work_directory/same.sql"

cell_failed_resume_exits_nonzero_and_does_not_claim_nothing_changed() {
  cell="failed-resume-exits-nonzero-and-does-not-claim-nothing-changed"
  FAKE_RESUME_FAILS=1 run_loader --resume x
  [ "$status" != 0 ] && [[ $flux_calls == *resume* ]] && [[ $output != *"nothing changed"* ]] ||
    fail "--resume that failed at flux resume exited $status with '$output' after flux $flux_calls"
}

cell_resume_of_missing_kustomization_stops_at_once() {
  cell=resume-of-missing-kustomization-stops-at-once
  FAKE_NO_KUSTOMIZATION=1 run_loader --resume x
  [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *"no Kustomization x in flux-system"* ]] ||
    fail "--resume of a missing Kustomization exited $status with '$output' after flux $flux_calls"
}

cell_unreadable_suspension_stops_before_suspend() {
  cell=unreadable-suspension-stops-before-suspend
  FAKE_READ_SUSPEND_FAILS=1 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *suspend* ]] ||
    fail "a load whose suspension state was unreadable exited $status after flux $flux_calls"
}

cell_foreign_suspension_refused_naming_resume() {
  cell=foreign-suspension-refused-naming-resume
  FAKE_SUSPENDED=true run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *suspend* ]] && [[ $output == *"--resume x"* ]] ||
    fail "a load on a foreign suspension exited $status after flux $flux_calls"
}

cell_load_log_created_at_0600() {
  cell=load-log-created-at-0600
  rm -f "$dump.load.log"
  umask 022
  FAKE_LOADED_SQL="$work_directory/same.sql" run_loader x "$dump"
  [ "$(head -n 1 "$FAKE_DIR/created-at")" = 600 ] || fail "the load log was at $(head -n 1 "$FAKE_DIR/created-at") when chmod ran"
}

cell_empty_table_compared_equal() {
  cell=empty-table-compared-equal
  FAKE_LOADED_SQL="$work_directory/same.sql" run_loader --compare x "$dump"
  [ "$status" = 0 ] && [[ $output == *"public.empty: 0 rows loaded, 0 in the dump, equal"* ]] && [[ $flux_calls == *resume* ]] ||
    fail "an equal load with an empty table exited $status with '$output'"
}

cell_table_only_in_database_differs_and_stays_suspended() {
  cell=table-only-in-database-differs-and-stays-suspended
  FAKE_LOADED_SQL="$work_directory/extra.sql" run_loader --compare x "$dump"
  [ "$status" != 0 ] && [[ $output == *"public.extra_empty: 0 rows loaded, 0 in the dump, DIFFERS"* ]] &&
    [[ $flux_calls != *resume* ]] || fail "a table only in the database exited $status with '$output' after flux $flux_calls"
}

cell_interrupt_during_verification_stays_suspended() {
  cell=interrupt-during-verification-stays-suspended
  FAKE_VERIFY_HANGS=1 start_loader_in_background '[ -e "$FAKE_DIR/verifying" ]' "its verification" x "$dump"
  pkill -INT --session "$loader"
  status=0
  wait "$loader" || status=$?
  [ "$status" != 0 ] && ! grep -q resume "$FAKE_DIR/flux.log" && grep -q -- "--resume x" "$FAKE_DIR/output" ||
    fail "an interrupt during verification exited $status after flux $(tr '\n' ' ' <"$FAKE_DIR/flux.log")"
}

cell_unreadable_database_before_load_loads_nothing_and_resumes() {
  cell=unreadable-database-before-load-loads-nothing-and-resumes
  FAKE_PG_DUMP_FAILS_AT=1 run_loader x "$dump"
  [ "$status" != 0 ] && [ ! -e "$FAKE_DIR/restored" ] && [[ $flux_calls == *resume* ]] &&
    [[ $output == *"nothing loaded"* ]] ||
    fail "a load whose database was unreadable before it exited $status with '$output' after flux $flux_calls"
}

cell_unreadable_database_after_failed_load_is_unknown_and_stays_suspended() {
  cell=unreadable-database-after-failed-load-is-unknown-and-stays-suspended
  FAKE_RESTORE_FAILS=1 FAKE_PG_DUMP_FAILS_AT=2 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"is unknown"* ]] &&
    [[ $output == *"--resume x"* ]] && [[ $output != *unchanged* ]] ||
    fail "a failed load on a database unreadable after it exited $status with '$output' after flux $flux_calls"
}

cell_materialized_view_after_failed_load_is_unknown_and_stays_suspended() {
  cell=materialized-view-after-failed-load-is-unknown-and-stays-suspended
  FAKE_RESTORE_FAILS=1 FAKE_UNFINGERPRINTED=1 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"is unknown"* ]] &&
    [[ $output != *unchanged* ]] ||
    fail "a failed load on a database with a relation pg_dump does not cover exited $status with '$output'"
}

# Writes the namespace's Pod list: one Pod per "name:phase[:detail]" argument, each owned by a ReplicaSet; a phase of "-"
# leaves the status without one. A detail adds what the Pod reports: "running" a running container, "init-running" a
# running init container, "terminated" a terminated container, "statefulset" a StatefulSet as owner instead.
pods_file() {
  local entry phase detail owner
  echo "items:"
  for entry; do
    phase="${entry#*:}"
    detail="${phase#*:}"
    [ "$detail" != "$phase" ] || detail=""
    phase="${phase%%:*}"
    owner=ReplicaSet
    [ "$detail" != statefulset ] || owner=StatefulSet
    printf -- '- metadata: {name: %s, ownerReferences: [{kind: %s}]}\n' "${entry%%:*}" "$owner"
    if [ "$phase" = - ]; then phase=""; else phase="phase: $phase"; fi
    case "$detail" in
      running) printf '  status: {%s, containerStatuses: [{state: {running: {startedAt: now}}}]}\n' "$phase" ;;
      init-running) printf '  status: {%s, initContainerStatuses: [{state: {running: {startedAt: now}}}]}\n' "$phase" ;;
      terminated) printf '  status: {%s, containerStatuses: [{state: {terminated: {exitCode: 137}}}], initContainerStatuses: [{state: {terminated: {exitCode: 0}}}]}\n' "$phase" ;;
      *) printf '  status: {%s}\n' "$phase" ;;
    esac
  done
}

cell_evicted_pod_beside_running_one_waits_only_for_the_running_one() {
  cell=evicted-pod-beside-running-one-waits-only-for-the-running-one
  pods_file evicted:Failed running:Running done:Succeeded pending:Pending unknown:- owned:Running:statefulset >"$work_directory/pods-$cell"
  FAKE_PODS="$work_directory/pods-$cell" run_loader x "$dump"
  [ "$status" = 0 ] && [ -e "$FAKE_DIR/restored" ] &&
    [ "$(sed 's/.*wait //; s/ --for.*//' "$FAKE_DIR/waited")" = "pod/running pod/pending pod/unknown" ] ||
    fail "a load beside an evicted Pod exited $status after waiting '$(cat "$FAKE_DIR/waited" 2>/dev/null)'"
}

cell_evicted_pod_alone_costs_no_wait() {
  cell=evicted-pod-alone-costs-no-wait
  pods_file evicted:Failed:terminated done:Succeeded bare:Failed >"$work_directory/pods-$cell"
  FAKE_PODS="$work_directory/pods-$cell" run_loader x "$dump"
  [ "$status" = 0 ] && [ -e "$FAKE_DIR/restored" ] && [ ! -e "$FAKE_DIR/waited" ] ||
    fail "a load with only an evicted Pod exited $status after waiting '$(cat "$FAKE_DIR/waited" 2>/dev/null)'"
}

cell_failed_pod_with_a_running_container_is_waited_for() {
  cell="failed-pod-with-a-running-container-is-waited-for"
  pods_file lost:Failed:running lost-init:Failed:init-running done:Succeeded:terminated >"$work_directory/pods-$cell"
  FAKE_PODS="$work_directory/pods-$cell" run_loader x "$dump"
  [ "$status" = 0 ] && [ -e "$FAKE_DIR/restored" ] &&
    [ "$(sed 's/.*wait //; s/ --for.*//' "$FAKE_DIR/waited")" = "pod/lost pod/lost-init" ] ||
    fail "a load beside a Failed Pod with a running container exited $status after waiting '$(cat "$FAKE_DIR/waited" 2>/dev/null)'"
}

cell_restore_that_outlives_its_status_is_awaited_through_its_commit() {
  cell=restore-that-outlives-its-status-is-awaited-through-its-commit
  FAKE_RESTORE_FAILS=1 FAKE_RESTORE_LINGERS=1 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"is unknown"* ]] &&
    [[ $output != *unchanged* ]] ||
    fail "a failed load whose restore committed after its status exited $status with '$output'"
}

cell_interrupt_after_commit_reports_unknown_to_the_operator_not_the_log() {
  cell=interrupt-after-commit-reports-unknown-to-the-operator-not-the-log
  FAKE_RESTORE_INTERRUPTED=1 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"is unknown"* ]] &&
    [[ $output == *"--resume x"* ]] && ! grep -q -e unknown -e --resume "$dump.load.log" ||
    fail "an INT after the commit exited $status with '$output' after flux $flux_calls"
}

cell_term_during_recovery_is_unknown_and_stays_suspended() {
  cell=term-during-recovery-is-unknown-and-stays-suspended
  FAKE_RESTORE_FAILS=1 FAKE_PG_DUMP_BLOCKS_AT=2 start_loader_in_background '[ -e "$FAKE_DIR/dumping" ]' \
    "the fingerprint after its failed load" x "$dump"
  # Only the task's shell, mise's child, gets the TERM; the fingerprint it waits for then ends equal to the one before.
  kill -TERM "$(pgrep --parent "$loader")"
  : >"$FAKE_DIR/release"
  status=0
  wait "$loader" || status=$?
  [ "$status" != 0 ] && ! grep -q resume "$FAKE_DIR/flux.log" && grep -q "is unknown" "$FAKE_DIR/output" &&
    grep -q -- "--resume x" "$FAKE_DIR/output" ||
    fail "a TERM during the recovery exited $status after flux $(tr '\n' ' ' <"$FAKE_DIR/flux.log")"
}

cell_interrupt_script_reaps() {
  cell=interrupt-script-reaps
  # A loader that refuses at once leaves nobody reading the FIFO; the dump the writer feeds exceeds the FIFO's buffer.
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in run) echo refused >&2; exit 1 ;; *) echo 0 ;; esac' \
    >"$work_directory/mise"
  chmod +x "$work_directory/mise"
  big_dump="$work_directory/big.dump"
  head -c 10000000 /dev/zero >"$big_dump"
  reaper_status=0
  PATH="$work_directory:$PATH" tests/postgres/interrupt_load.sh x "$big_dump" INT >/dev/null 2>&1 || reaper_status=$?
  [ "$reaper_status" != 0 ] || fail "interrupt_load.sh passed with a loader that refused at once"
  if pgrep -f "^head -c [0-9]+ $big_dump" >/dev/null; then
    pkill -KILL -f "^head -c [0-9]+ $big_dump"
    fail "interrupt_load.sh left its writer running after the loader refused"
  fi
}

cell_interrupt_script_checks_writers() {
  cell=interrupt-script-checks-writers
  # A loader that blocks without having stopped its writers: the Deployment still runs while a session blocks.
  mkdir "$work_directory/running"
  cat >"$work_directory/running/mise" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  run*) sleep 60 ;;
  *psql*) echo 1 ;;
  *"get deployments"*) echo "writer=1" ;;
esac
FAKE
  chmod +x "$work_directory/running/mise"
  checked_output="$(PATH="$work_directory/running:$PATH" tests/postgres/interrupt_load.sh x "$dump" INT 2>&1)" && checked_status=0 || checked_status=$?
  [ "$checked_status" != 0 ] && [[ $checked_output == *"a Deployment runs or a Flux Job exists"* ]] ||
    fail "interrupt_load.sh exited $checked_status with '$checked_output' for a writer that still ran"
}

cell_interrupt_script_fails_on_unreadable_writer_state() {
  cell=interrupt-script-fails-on-unreadable-writer-state
  # A loader that blocks while the Deployments cannot be read: the script must not take that for stopped writers.
  mkdir "$work_directory/unreadable"
  cat >"$work_directory/unreadable/mise" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  run*) sleep 60 ;;
  *psql*) echo 1 ;;
  *"get deployments"*)
    if [ -e "$FAKE_FIRST_READ" ]; then exit 1; fi
    : >"$FAKE_FIRST_READ"
    echo "writer=0" ;;
esac
FAKE
  chmod +x "$work_directory/unreadable/mise"
  unreadable_output="$(FAKE_FIRST_READ="$work_directory/first-read" PATH="$work_directory/unreadable:$PATH" \
    tests/postgres/interrupt_load.sh x "$dump" INT 2>&1)" && unreadable_status=0 || unreadable_status=$?
  [ "$unreadable_status" != 0 ] && [[ $unreadable_output == *"cannot read the Deployments of x"* ]] &&
    [[ $unreadable_output != *"sending INT"* ]] ||
    fail "interrupt_load.sh exited $unreadable_status with '$unreadable_output' for Deployments it could not read"
}

cell_interrupt_script_names_unreadable_suspension_after_kill() {
  cell=interrupt-script-names-unreadable-suspension-after-kill
  # A loader that blocks until killed, after which the suspension cannot be read.
  mkdir "$work_directory/killed"
  cat >"$work_directory/killed/mise" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  run*) umask 077; : >"$4.load.log"; sleep 60 ;;
  *psql*) echo 1 ;;
  *"get deployments"*) echo "writer=0" ;;
  *"get kustomization"*) exit 1 ;;
esac
FAKE
  chmod +x "$work_directory/killed/mise"
  killed_output="$(PATH="$work_directory/killed:$PATH" tests/postgres/interrupt_load.sh x "$dump" KILL 2>&1)" &&
    killed_status=0 || killed_status=$?
  [ "$killed_status" != 0 ] && [[ $killed_output == *"cannot read whether the Kustomization x is suspended"* ]] ||
    fail "interrupt_load.sh exited $killed_status with '$killed_output' for a suspension it could not read after KILL"
}

# A sleep of one second, the script's polling interval, shortened so a 300-probe timeout takes seconds.
fake_polling_sleep() {
  cat >"$1/sleep" <<'FAKE'
#!/usr/bin/env bash
[ "$1" != 1 ] || exec "$FAKE_REAL_SLEEP" 0.01
exec "$FAKE_REAL_SLEEP" "$@"
FAKE
  chmod +x "$1/sleep"
}

cell_interrupt_script_sends_its_signal_when_probes_disagree() {
  cell=interrupt-script-sends-its-signal-when-probes-disagree
  # A session inside its transaction waits for its client between two statements: successive probes answer 1 and 0.
  mkdir "$work_directory/alternating"
  cat >"$work_directory/alternating/mise" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  run*) umask 077; : >"$4.load.log"; sleep 60 ;;
  *psql*)
    echo x >>"$FAKE_PROBES"
    echo $(($(wc -l <"$FAKE_PROBES") % 2)) ;;
  *"get deployments"*) echo "writer=0" ;;
  *"get kustomization"*) exit 1 ;;
esac
FAKE
  chmod +x "$work_directory/alternating/mise"
  alternating_output="$(FAKE_PROBES="$work_directory/probes" PATH="$work_directory/alternating:$PATH" \
    tests/postgres/interrupt_load.sh x "$dump" KILL 2>&1)" && alternating_status=0 || alternating_status=$?
  [ "$alternating_status" != 0 ] && [[ $alternating_output == *"pg_restore blocks inside its transaction; sending KILL"* ]] ||
    fail "interrupt_load.sh exited $alternating_status with '$alternating_output' for probes that disagree"
}

cell_interrupt_script_prints_what_the_restore_did_on_timeout() {
  cell=interrupt-script-prints-what-the-restore-did-on-timeout
  # A loader that never blocks; a query or a row would show as the marker the fake prints for either.
  mkdir "$work_directory/never"
  cat >"$work_directory/never/mise" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  run*) sleep 60 ;;
  *query*) echo "ROW-MARKER" ;;
  *psql*) echo 0 ;;
esac
FAKE
  chmod +x "$work_directory/never/mise"
  fake_polling_sleep "$work_directory/never"
  never_output="$(FAKE_REAL_SLEEP="$(command -v sleep)" PATH="$work_directory/never:$PATH" \
    tests/postgres/interrupt_load.sh x "$dump" INT 2>&1)" && never_status=0 || never_status=$?
  [ "$never_status" != 0 ] && [[ $never_output == *"within 300 seconds"* ]] && [[ $never_output == *"writer finished:"* ]] &&
    [[ $never_output == *"database sessions"* ]] && [[ $never_output == *"container processes"* ]] &&
    [[ $never_output == *"loader processes"* ]] && [[ $never_output != *ROW-MARKER* ]] ||
    fail "interrupt_load.sh exited $never_status with '$never_output' for a restore that never blocked"
}

cell_claim_layer_refuses_a_resume_naming_the_rerun() {
  cell=claim-layer-refuses-a-resume-naming-the-rerun
  FAKE_CLAIM=audiofiles run_loader --resume x
  [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *"same command again"* ]] ||
    fail "--resume of a claim layer exited $status with '$output' after flux $flux_calls"
}

cell_unreadable_claim_declaration_is_refused_and_flux_untouched() {
  cell=unreadable-claim-declaration-is-refused-and-flux-untouched
  FAKE_CLAIM_READ_FAILS=1 run_loader x "$dump"
  [ "$status" != 0 ] && [ -z "$flux_calls" ] || fail "a load with an unreadable claim key exited $status after flux $flux_calls"
}

cell_empty_bucket_on_a_layer_without_a_bucket_is_refused_before_any_change() {
  cell=empty-bucket-on-a-layer-without-a-bucket-is-refused-before-any-change
  local layer
  for layer in "" audiofiles; do
    FAKE_CLAIM="$layer" run_loader --empty-bucket x "$dump"
    [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *"declares no bucket"* ]] && [ ! -e "$FAKE_DIR/steps" ] ||
      fail "--empty-bucket on a layer with claim '$layer' and no bucket exited $status with '$output' after flux $flux_calls"
  done
}

cell_dump_of_no_staging_snapshot_is_refused_before_the_suspension() {
  cell=dump-of-no-staging-snapshot-is-refused-before-the-suspension
  FAKE_CLAIM=audiofiles FAKE_NO_SNAPSHOT=1 run_loader x "$dump"
  [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *"no staging snapshot"* ]] && [[ $output == *"nothing changed"* ]] &&
    grep -q db-load-source "$FAKE_DIR/deleted" && [ ! -e "$FAKE_DIR/restored" ] ||
    fail "a dump of no staging snapshot exited $status with '$output' after flux $flux_calls"
}

cell_unreadable_repository_is_refused_before_the_suspension() {
  cell=unreadable-repository-is-refused-before-the-suspension
  FAKE_CLAIM=audiofiles FAKE_SOURCE_UNREADABLE=1 run_loader x "$dump"
  [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *"cannot read the staging snapshots"* ]] &&
    [[ $output == *"nothing changed"* ]] && grep -q db-load-source "$FAKE_DIR/deleted" ||
    fail "a repository that cannot be read exited $status with '$output' after flux $flux_calls"
}

# The node's free bytes against the load's need and kubelet's margin, which the cluster cannot arrange. The fake's
# 200 GB filesystem gives a margin of 30 GB (15 %); its bucket and claim need 67139836 bytes, so 30067139836 free bytes
# leave exactly the margin.
cell_node_without_room_for_the_load_is_refused_before_the_suspension() {
  cell=node-without-room-for-the-load-is-refused-before-the-suspension
  local free
  for free in 1000 30067139836; do
    FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_FREE_BYTES="$free" run_loader x "$dump"
    [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *"bytes free"* ]] && [[ $output == *"nothing changed"* ]] &&
      [[ $output != *fake-node* ]] && [ ! -e "$FAKE_DIR/restored" ] ||
      fail "a node with $free free bytes exited $status with '$output' after flux $flux_calls"
  done
}

cell_eviction_margin_that_cannot_be_read_is_refused_before_the_suspension() {
  cell=eviction-margin-that-cannot-be-read-is-refused-before-the-suspension
  local configz
  FAKE_CLAIM=audiofiles FAKE_CONFIGZ_FAILS=1 run_loader x "$dump"
  [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *"nothing changed"* ]] && [[ $output != *fake-node* ]] ||
    fail "a kubelet configuration that cannot be read exited $status with '$output' after flux $flux_calls"
  for configz in '{"kubeletconfig":{"evictionHard":{"nodefs.available":"10%"}}}' \
    '{"kubeletconfig":{"evictionHard":{"nodefs.available":"ten","imagefs.available":"15%"}}}'; do
    FAKE_CLAIM=audiofiles FAKE_CONFIGZ="$configz" run_loader x "$dump"
    [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *"nothing changed"* ]] && [[ $output != *fake-node* ]] ||
      fail "an eviction margin of '$configz' exited $status with '$output' after flux $flux_calls"
  done
}

cell_non_empty_bucket_without_the_flag_is_refused_and_flux_resumes() {
  cell=non-empty-bucket-without-the-flag-is-refused-and-flux-resumes
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_BUCKET_OBJECTS=3 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls == "suspend resume " ]] && [[ $output == *"holds 3 objects"* ]] &&
    [[ $output == *"nothing loaded"* ]] && [ ! -e "$FAKE_DIR/restored" ] && ! grep -qE '^(empty|copy|restore-claim)$' "$FAKE_DIR/steps" ||
    fail "a non-empty bucket without the flag exited $status with '$output' after flux $flux_calls"
}

cell_non_empty_bucket_on_an_earlier_suspension_is_refused_naming_the_flag_and_stays_suspended() {
  cell=non-empty-bucket-on-an-earlier-suspension-is-refused-naming-the-flag-and-stays-suspended
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_BUCKET_OBJECTS=3 FAKE_SUSPENDED=true run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"was suspended before this run"* ]] &&
    [[ $output == *"with --empty-bucket"* ]] && [ ! -e "$FAKE_DIR/restored" ] && grep -q db-load-snapshot "$FAKE_DIR/deleted" ||
    fail "a non-empty bucket on an earlier suspension exited $status with '$output' after flux $flux_calls"
}

# The loader's steps in the order the plan owes: the bucket is restored and counted before the database, the claim after.
cell_bucket_load_runs_its_steps_in_order_deletes_the_loader_and_names_the_backup() {
  cell=bucket-load-runs-its-steps-in-order-deletes-the-loader-and-names-the-backup
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_BUCKET_OBJECTS=3 run_loader --empty-bucket x "$dump"
  [ "$status" = 0 ] && [[ $flux_calls == "suspend resume " ]] && [ -e "$FAKE_DIR/restored" ] &&
    [ "$(tr '\n' ' ' <"$FAKE_DIR/steps")" = "source restore-bucket count restore-claim empty copy check " ] &&
    [[ $output == *"0 differing"* ]] && [[ $output == *"mise run backup:now x"* ]] && [[ $output != *fake-node* ]] &&
    [ "$(grep -c 'delete pod' "$FAKE_DIR/deleted")" -ge 3 ] || fail "a bucket load with the flag exited $status with '$output' after flux $flux_calls"
}

cell_load_into_an_empty_bucket_needs_no_flag_and_never_empties() {
  cell=load-into-an-empty-bucket-needs-no-flag-and-never-empties
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 run_loader x "$dump"
  [ "$status" = 0 ] && [ "$(tr '\n' ' ' <"$FAKE_DIR/steps")" = "source restore-bucket count restore-claim copy check " ] ||
    fail "a load into an empty bucket exited $status with '$output'"
}

cell_claim_only_layer_restores_its_claim_and_touches_no_bucket() {
  cell=claim-only-layer-restores-its-claim-and-touches-no-bucket
  FAKE_CLAIM=audiofiles run_loader x "$dump"
  [ "$status" = 0 ] && [ "$(tr '\n' ' ' <"$FAKE_DIR/steps")" = "source restore-claim " ] && [[ $output != *backup:now* ]] ||
    fail "a claim layer without a bucket exited $status with '$output'"
}

cell_restored_bucket_that_differs_refuses_with_nothing_loaded() {
  cell=restored-bucket-that-differs-refuses-with-nothing-loaded
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_DIFFERS=restore-bucket run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls == "suspend resume " ]] && [[ $output == *"nothing loaded"* ]] && [ ! -e "$FAKE_DIR/restored" ] ||
    fail "a restored bucket copy that differs exited $status with '$output' after flux $flux_calls"
}

cell_restored_claim_that_differs_stays_suspended_naming_the_rerun() {
  cell=restored-claim-that-differs-stays-suspended-naming-the-rerun
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_DIFFERS=restore-claim run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"same command again"* ]] &&
    [[ $output != *"with --empty-bucket"* ]] && ! grep -qE '^(empty|copy)$' "$FAKE_DIR/steps" && grep -q db-load-snapshot "$FAKE_DIR/deleted" ||
    fail "a restored claim that differs exited $status with '$output' after flux $flux_calls"
}

cell_checked_bucket_that_differs_stays_suspended_naming_the_flag() {
  cell=checked-bucket-that-differs-stays-suspended-naming-the-flag
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_DIFFERS=check run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"differs from the snapshot fake-snapshot in 5 entries"* ]] &&
    [[ $output == *"same command again with --empty-bucket"* ]] && grep -q db-load-snapshot "$FAKE_DIR/deleted-after-load" ||
    fail "a bucket that differs after the copy exited $status with '$output' after flux $flux_calls"
}

cell_failed_copy_stays_suspended_naming_the_flag() {
  cell=failed-copy-stays-suspended-naming-the-flag
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_STEP_FAILS=copy run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"same command again with --empty-bucket"* ]] &&
    grep -q db-load-snapshot "$FAKE_DIR/deleted" || fail "a failed copy exited $status with '$output' after flux $flux_calls"
}

cell_loader_cut_by_its_backstop_says_so_and_stays_suspended() {
  cell=loader-cut-by-its-backstop-says-so-and-stays-suspended
  FAKE_CLAIM=audiofiles FAKE_STEP_FAILS=restore-claim FAKE_POD_REASON=DeadlineExceeded run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"backstop during restore-claim"* ]] &&
    [[ $output == *"same command again"* ]] || fail "a loader cut by its backstop exited $status with '$output' after flux $flux_calls"
}

cell_failed_loader_delete_keeps_flux_suspended_and_says_so() {
  cell=failed-loader-delete-keeps-flux-suspended-and-says-so
  FAKE_CLAIM=audiofiles FAKE_DELETE_FAILS=1 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls == "suspend " ]] && [[ $output == *"could not be deleted"* ]] &&
    [[ $output == *"stays suspended"* ]] || fail "a loader that could not be deleted exited $status with '$output' after flux $flux_calls"
}

cell_database_that_stays_busy_after_the_load_deletes_the_loader_and_stays_suspended() {
  cell=database-that-stays-busy-after-the-load-deletes-the-loader-and-stays-suspended
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_SESSION_AFTER_LOAD=1 DB_LOAD_DUMP_ALONE_SECONDS=2 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *resume* ]] && [[ $output == *"still holds another session"* ]] &&
    grep -q db-load-snapshot "$FAKE_DIR/deleted-after-load" ||
    fail "a claim load beside a session that joined after it exited $status with '$output' after flux $flux_calls"
}

cell_term_while_the_resume_waits_deletes_the_loader_and_stays_suspended() {
  cell=term-while-the-resume-waits-deletes-the-loader-and-stays-suspended
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_SESSION_AFTER_LOAD=1 DB_LOAD_DUMP_ALONE_SECONDS=600 \
    start_loader_in_background 'grep -q "verified; resuming the Kustomization x" "$FAKE_DIR/output"' "its resume" x "$dump"
  # Only the task's shell, mise's child, gets the TERM, while the resume waits for the other session to leave.
  kill -TERM "$(pgrep --parent "$loader")"
  status=0
  wait "$loader" || status=$?
  [ "$status" != 0 ] && ! grep -q resume "$FAKE_DIR/flux.log" && grep -q db-load-snapshot "$FAKE_DIR/deleted-after-load" &&
    grep -q "stays suspended" "$FAKE_DIR/output" ||
    fail "a TERM while the resume waited exited $status after flux $(tr '\n' ' ' <"$FAKE_DIR/flux.log")"
}

cell_bucket_container_that_appears_after_the_plan_refuses_with_nothing_loaded() {
  cell=bucket-container-that-appears-after-the-plan-refuses-with-nothing-loaded
  FAKE_CLAIM=audiofiles FAKE_BUCKET_APPEARS=1 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $output == *"changed its bucket container since the plan was made; nothing loaded"* ]] &&
    [ ! -e "$FAKE_DIR/started-db-load-snapshot" ] && [[ $flux_calls == *resume* ]] ||
    fail "a bucket container that appeared after the plan exited $status with '$output' after flux $flux_calls"
}

cell_rerun_on_a_suspended_kustomization_runs_through() {
  cell=rerun-on-a-suspended-kustomization-runs-through
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 FAKE_SUSPENDED=true run_loader x "$dump"
  [ "$status" = 0 ] && [[ $flux_calls == *resume* ]] || fail "a re-run on a suspended Kustomization exited $status with '$output'"
}

# The key that may write reaches the loader's rclone container alone, and the Pod that finds the snapshot holds no Secret.
cell_only_the_rclone_container_mounts_the_app_s_key_and_the_source_pod_no_secret() {
  cell=only-the-rclone-container-mounts-the-app-s-key-and-the-source-pod-no-secret
  FAKE_CLAIM=audiofiles FAKE_BUCKET=1 run_loader x "$dump"
  local holders
  holders="$(jq --raw-output '[.spec.volumes[] | select(.secret) | .name] as $secrets |
    [.spec.containers[] | select(any(.volumeMounts[]?; .name | IN($secrets[]))) | .name] | join(" ")' \
    "$FAKE_DIR/pod-db-load-snapshot.json")"
  [ "$holders" = rclone ] || fail "the containers '$holders' of the loader mount a Secret, not rclone alone"
  [ "$(jq '[.spec.volumes[] | select(.secret)] | length' "$FAKE_DIR/pod-db-load-source.json")" = 0 ] ||
    fail "the Pod that finds the snapshot mounts a Secret"
}

cell_other_session_that_stays_ends_the_wait_after_the_seconds_set() {
  cell=other-session-that-stays-ends-the-wait-after-the-seconds-set
  local started=$SECONDS
  FAKE_SESSION_STAYS=1 DB_LOAD_DUMP_ALONE_SECONDS=2 run_loader x "$dump"
  [ $((SECONDS - started)) -lt 60 ] || fail "a wait of 2 seconds took $((SECONDS - started)) seconds, not under 60"
  [ "$status" != 0 ] && [ ! -e "$FAKE_DIR/restored" ] && [[ $flux_calls == *resume* ]] &&
    [[ $output == *"after 2 seconds; nothing loaded"* ]] && [ "$(grep -c 'still holds another session' <<<"$output")" = 1 ] ||
    fail "a load beside a session that stays exited $status with '$output' after flux $flux_calls"
}

cell_malformed_wait_is_refused_before_anything_is_suspended() {
  cell=malformed-wait-is-refused-before-anything-is-suspended
  local value
  for value in abc 0 -5 1.5 "2 3"; do
    DB_LOAD_DUMP_ALONE_SECONDS="$value" run_loader x "$dump"
    [ "$status" != 0 ] && [ -z "$flux_calls" ] && [[ $output == *DB_LOAD_DUMP_ALONE_SECONDS* ]] ||
      fail "a wait of '$value' exited $status with '$output' after flux $flux_calls"
  done
}

# Each cell runs in its own subshell, so one failed cell does not hide the next.
cells=(
  other-session-that-stays-ends-the-wait-after-the-seconds-set
  malformed-wait-is-refused-before-anything-is-suspended
  failed-resume-exits-nonzero-and-does-not-claim-nothing-changed
  resume-of-missing-kustomization-stops-at-once
  unreadable-suspension-stops-before-suspend
  foreign-suspension-refused-naming-resume
  load-log-created-at-0600
  empty-table-compared-equal
  table-only-in-database-differs-and-stays-suspended
  interrupt-during-verification-stays-suspended
  interrupt-script-reaps
  interrupt-script-checks-writers
  interrupt-script-fails-on-unreadable-writer-state
  unreadable-database-before-load-loads-nothing-and-resumes
  unreadable-database-after-failed-load-is-unknown-and-stays-suspended
  interrupt-script-names-unreadable-suspension-after-kill
  interrupt-script-sends-its-signal-when-probes-disagree
  interrupt-script-prints-what-the-restore-did-on-timeout
  materialized-view-after-failed-load-is-unknown-and-stays-suspended
  restore-that-outlives-its-status-is-awaited-through-its-commit
  evicted-pod-beside-running-one-waits-only-for-the-running-one
  evicted-pod-alone-costs-no-wait
  failed-pod-with-a-running-container-is-waited-for
  term-during-recovery-is-unknown-and-stays-suspended
  interrupt-after-commit-reports-unknown-to-the-operator-not-the-log
  claim-layer-refuses-a-resume-naming-the-rerun
  unreadable-claim-declaration-is-refused-and-flux-untouched
  empty-bucket-on-a-layer-without-a-bucket-is-refused-before-any-change
  dump-of-no-staging-snapshot-is-refused-before-the-suspension
  unreadable-repository-is-refused-before-the-suspension
  node-without-room-for-the-load-is-refused-before-the-suspension
  eviction-margin-that-cannot-be-read-is-refused-before-the-suspension
  non-empty-bucket-without-the-flag-is-refused-and-flux-resumes
  non-empty-bucket-on-an-earlier-suspension-is-refused-naming-the-flag-and-stays-suspended
  bucket-load-runs-its-steps-in-order-deletes-the-loader-and-names-the-backup
  load-into-an-empty-bucket-needs-no-flag-and-never-empties
  claim-only-layer-restores-its-claim-and-touches-no-bucket
  restored-bucket-that-differs-refuses-with-nothing-loaded
  restored-claim-that-differs-stays-suspended-naming-the-rerun
  checked-bucket-that-differs-stays-suspended-naming-the-flag
  failed-copy-stays-suspended-naming-the-flag
  loader-cut-by-its-backstop-says-so-and-stays-suspended
  failed-loader-delete-keeps-flux-suspended-and-says-so
  database-that-stays-busy-after-the-load-deletes-the-loader-and-stays-suspended
  term-while-the-resume-waits-deletes-the-loader-and-stays-suspended
  bucket-container-that-appears-after-the-plan-refuses-with-nothing-loaded
  rerun-on-a-suspended-kustomization-runs-through
  only-the-rclone-container-mounts-the-app-s-key-and-the-source-pod-no-secret
)
failed=()
for name in "${cells[@]}"; do
  ("cell_${name//-/_}") || failed+=("$name")
done
[ "${#failed[@]}" = 0 ] || { echo "load_dump: failed cells: ${failed[*]}" >&2; exit 1; }
echo "load_dump: every cell held"
