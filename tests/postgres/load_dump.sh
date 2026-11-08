#!/usr/bin/env bash
# Drive `mise run db:load-dump` and tests/postgres/interrupt_load.sh against fake kubectl, flux, pg_restore, pg_dump and
# mise on PATH: the outcomes the loader owes where a command fails, a signal arrives or a table is empty, none of which
# the cluster proofs can arrange on demand. The fakes run the remote commands locally, so the task's own awk compares
# the fake dump with the fake database.
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
  *"get kustomization"*"--output name"*)
    [ -z "${FAKE_NO_KUSTOMIZATION:-}" ] || exit 0
    echo "kustomization.kustomize.toolkit.fluxcd.io/x" ;;
  *"get kustomization"*)
    [ -z "${FAKE_READ_SUSPEND_FAILS:-}" ] || { echo "fake kubectl: the server is unreachable" >&2; exit 1; }
    printf '%s' "${FAKE_SUSPENDED:-}" ;;
  *pg_stat_activity*) echo 0 ;;
  *"get pods"*) echo "items: []" ;;
  *"get deployments"* | *"get jobs"* | *"delete job"* | *" scale "* | *"rollout status"* | *" wait "*) ;;
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
    [ -z "${FAKE_RESTORE_FAILS:-}" ] ;;
esac
FAKE
# FAKE_PG_DUMP_FAILS_AT names the call, counted from 1 in each cell, that fails.
cat >"$fake_bin/pg_dump" <<'FAKE'
#!/usr/bin/env bash
echo >>"$FAKE_DIR/pg_dump-calls"
[ "$(wc -l <"$FAKE_DIR/pg_dump-calls")" != "${FAKE_PG_DUMP_FAILS_AT:-}" ] || exit 1
cat "$FAKE_LOADED_SQL"
FAKE
cat >"$fake_bin/chmod" <<'FAKE'
#!/usr/bin/env bash
[ -z "${FAKE_DIR:-}" ] || echo "$(stat -c %a "$2")" >>"$FAKE_DIR/created-at"
exec /bin/chmod "$@"
FAKE
chmod +x "$fake_bin"/*
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
  cell=failed-resume-exits-nonzero-and-does-not-claim-nothing-changed
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
  export FAKE_DIR="$work_directory/state-$cell"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/flux.log"
  FAKE_VERIFY_HANGS=1 setsid mise run db:load-dump x "$dump" >"$FAKE_DIR/output" 2>&1 &
  loader=$!
  trap 'pkill -KILL --session "$loader" 2>/dev/null || true; wait "$loader" 2>/dev/null || true' EXIT
  for _ in $(seq 150); do [ -e "$FAKE_DIR/verifying" ] && break; sleep 0.2; done
  [ -e "$FAKE_DIR/verifying" ] || fail "the loader never reached its verification"
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

# Each cell runs in its own subshell, so one failed cell does not hide the next.
cells=(
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
)
failed=()
for name in "${cells[@]}"; do
  ("cell_${name//-/_}") || failed+=("$name")
done
[ "${#failed[@]}" = 0 ] || { echo "load_dump: failed cells: ${failed[*]}" >&2; exit 1; }
echo "load_dump: every cell held"
