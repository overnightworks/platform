#!/usr/bin/env bash
# Drive `mise run db:load-dump` and tests/postgres/interrupt_load.sh against fake kubectl, flux, pg_restore, pg_dump and
# mise on PATH: the outcomes the loader owes where a command fails, a signal arrives or a table is empty, none of which
# the cluster proofs can arrange on demand. The fakes run the remote commands locally, so the task's own awk compares
# the fake dump with the fake database.
# Usage: mise exec -- tests/postgres/load_dump.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_directory="$(mktemp -d)"
leftovers=()
trap 'for pid in "${leftovers[@]}"; do pkill -KILL --session "$pid" 2>/dev/null || true; done; rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
fail() { echo "load_dump: $1" >&2; exit 1; }

cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
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
      *) "$@" ;;
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
case "$*" in *--data-only*) cat "$FAKE_DUMP_SQL" ;; *) cat >/dev/null ;; esac
FAKE
cat >"$fake_bin/pg_dump" <<'FAKE'
#!/usr/bin/env bash
cat "$FAKE_LOADED_SQL"
FAKE
cat >"$fake_bin/chmod" <<'FAKE'
#!/usr/bin/env bash
[ -z "${FAKE_DIR:-}" ] || echo "$(stat -c %a "$2")" >>"$FAKE_DIR/created-at"
exec /bin/chmod "$@"
FAKE
chmod +x "$fake_bin"/*
# mise puts its own kubectl and flux before PATH, so the task must not load them.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux2
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
export FAKE_DUMP_SQL="$work_directory/dump.sql"

cell_resume_fails() {
  cell=resume-fails
  FAKE_RESUME_FAILS=1 run_loader --resume x
  [ "$status" != 0 ] && [[ $flux_calls == *resume* ]] && [[ $output != *"nothing changed"* ]] ||
    fail "--resume that failed at flux resume exited $status with '$output' after flux $flux_calls"
}

cell_suspension_unreadable() {
  cell=suspension-unreadable
  FAKE_READ_SUSPEND_FAILS=1 run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *suspend* ]] ||
    fail "a load whose suspension state was unreadable exited $status after flux $flux_calls"
}

cell_suspended_by_another() {
  cell=suspended-by-another
  FAKE_SUSPENDED=true run_loader x "$dump"
  [ "$status" != 0 ] && [[ $flux_calls != *suspend* ]] && [[ $output == *"--resume x"* ]] ||
    fail "a load on a foreign suspension exited $status after flux $flux_calls"
}

cell_log_mode() {
  cell=log-mode
  rm -f "$dump.load.log"
  umask 022
  FAKE_LOADED_SQL="$work_directory/same.sql" run_loader x "$dump"
  [ "$(head -n 1 "$FAKE_DIR/created-at")" = 600 ] || fail "the load log was at $(head -n 1 "$FAKE_DIR/created-at") when chmod ran"
}

# Each cell runs in its own subshell, so one failed cell does not hide the next.
failed=()
for name in resume-fails suspension-unreadable suspended-by-another log-mode; do
  ("cell_${name//-/_}") || failed+=("$name")
done
[ "${#failed[@]}" = 0 ] || { echo "load_dump: failed cells: ${failed[*]}" >&2; exit 1; }
echo "load_dump: every cell held"
