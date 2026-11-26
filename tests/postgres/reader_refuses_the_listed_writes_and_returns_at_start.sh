#!/usr/bin/env bash
# Proves docs/personal-data.md PD-11, on the proof layer's Postgres through the real mise run db:read: that the role
# reader is refused each write, object, switch to read-write, sequence step, program and shell escape the cell lists,
# with the data unchanged and no file made; that a statement past the session's statement_timeout is cancelled; that a
# schema and table made later are readable; that a drifted role makes the next read refuse before its SQL and names the
# condition; that keep ends 0 and leaves a trace in the container's log while a lock holds the role, leaves a role it
# did not declare alone; and that the role is back at the next start after a drop. Needs PROOF_LAYER.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=loader_proof_setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/loader_proof_setup.sh"
# db:read runs as on the PC, against this cluster.
export KUBECONFIG="$HOME/.kube/config"
layer="$PROOF_LAYER"
escape_file=/tmp/reader-proof
lock_application=reader_proof_lock

in_postgres() { kubectl --namespace "$layer" exec postgres-0 --container postgres -- "$@"; }
# read_sql <sql>: the output of db:read on the SQL, whose status the caller reads.
read_sql() { mise run db:read "$layer" 2>&1 <<<"$1"; }
# hook: the command the StatefulSet runs after the container starts, read from it.
mapfile -t hook < <(kubectl --namespace "$layer" get statefulset postgres -o json |
  yq '.spec.template.spec.containers[] | select(.name == "postgres") | .lifecycle.postStart.exec.command[]')
[ "${#hook[@]}" -gt 0 ] || fail "the StatefulSet postgres in $layer declares no postStart command"

holder=""
cleanup() {
  [ -z "$holder" ] || kill "$holder" 2>/dev/null || true
  sql "$layer" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '$lock_application'" >/dev/null || true
  sql "$layer" 'DROP TABLE IF EXISTS reader_proof, created_by_reader; DROP SEQUENCE IF EXISTS reader_proof_sequence;
    DROP SCHEMA IF EXISTS reader_later CASCADE' >/dev/null || true
  sql "$layer" 'REVOKE CREATE ON SCHEMA public FROM reader' >/dev/null || true
  sql "$layer" 'REVOKE SELECT ON pg_authid FROM reader' >/dev/null || true
  in_postgres rm -f "$escape_file" || true
}
trap cleanup EXIT

sql "$layer" "CREATE TABLE reader_proof (token text); INSERT INTO reader_proof SELECT 'row-' || i FROM generate_series(1, 3) i;
  CREATE SEQUENCE reader_proof_sequence"
unchanged() {
  [ "$(sql "$layer" "SELECT count(*) = 3 AND count(*) FILTER (WHERE token ~ '^row-[1-3]\$') = 3 FROM reader_proof")" = t ] &&
    [ "$(sql "$layer" 'SELECT is_called FROM reader_proof_sequence')" = f ] &&
    [ "$(sql "$layer" "SELECT to_regclass('created_by_reader') IS NULL")" = t ] &&
    ! in_postgres test -e "$escape_file"
}
unchanged || fail "the proof data is not as the cell made it"
refused() {
  local description="$1" output
  if output="$(read_sql "$2")"; then fail "db:read let through: $description"; fi
  unchanged || fail "after $description, the data changed or $escape_file exists: $output"
  echo "refused: $description"
}
refused "an INSERT" "INSERT INTO reader_proof VALUES ('written')"
refused "an UPDATE" "UPDATE reader_proof SET token = 'written'"
refused "a DELETE" "DELETE FROM reader_proof"
refused "a TRUNCATE" "TRUNCATE reader_proof"
refused "a CREATE TABLE" "CREATE TABLE created_by_reader (value integer)"
refused "an INSERT after SET TRANSACTION READ WRITE" "SET TRANSACTION READ WRITE; INSERT INTO reader_proof VALUES ('written')"
refused "an INSERT after COMMIT and SET default_transaction_read_only = off" \
  "COMMIT; SET default_transaction_read_only = off; INSERT INTO reader_proof VALUES ('written')"
refused "nextval on a sequence" "SELECT nextval('reader_proof_sequence')"
refused "COPY TO PROGRAM" "COPY (SELECT 1) TO PROGRAM 'touch $escape_file'"
refused "a shell escape" "\\! touch $escape_file"

# A statement that outlasts the session's own statement_timeout, which the session reports, is cancelled.
statement_timeout="$(read_sql 'SHOW statement_timeout' | sed -n 3p | tr -d ' ')"
[[ $statement_timeout =~ ^[1-9][0-9]*s$ ]] || fail "the session's statement_timeout reads '$statement_timeout', not a whole number of seconds"
sleep_output="$(read_sql "SELECT pg_sleep($((${statement_timeout%s} + 5)))")" && fail "a statement past the statement_timeout of $statement_timeout was not cancelled"
grep -qF 'canceling statement due to statement timeout' <<<"$sleep_output" ||
  fail "the sleep past the statement_timeout of $statement_timeout ended otherwise: $sleep_output"
echo "refused: a statement past the statement_timeout of $statement_timeout"

# pg_read_all_data holds no list of tables: what the superuser makes after the role was declared is readable.
sql "$layer" 'CREATE SCHEMA reader_later; CREATE TABLE reader_later.made_later (value integer); INSERT INTO reader_later.made_later VALUES (1)'
[ "$(read_sql 'SELECT count(*) FROM reader_later.made_later' | sed -n 3p | tr -d ' ')" = 1 ] ||
  fail "db:read does not read a schema and table made after the start"
echo "a schema and table made after the start are readable"

# A drift makes the next read refuse before its SQL, naming the condition; keep, run as at a start, restores the role.
keep() { in_postgres "${hook[@]}"; }
# logged_lines <text>: how many lines of the container's log hold the text.
logged_lines() {
  local log
  log="$(kubectl --namespace "$layer" logs postgres-0 --container postgres)" || fail "kubectl logs of postgres-0 in $layer failed" >&2
  grep -cF "$1" <<<"$log" || true
}
refuses_naming() {
  local output
  if output="$(read_sql 'SELECT 1')"; then fail "db:read read as a drifted role: $1"; fi
  grep -qF "$1" <<<"$output" || fail "db:read refused the drifted role without naming '$1': $output"
}
read_sql "COMMIT; SET default_transaction_read_only = off; ALTER ROLE reader PASSWORD 'drifted'" >/dev/null || true
refuses_naming 'the role has a password'
keep
read_sql 'SELECT 1' >/dev/null || fail "db:read still refuses after keep restored the role"
sql "$layer" 'GRANT CREATE ON SCHEMA public TO reader'
refuses_naming 'the role can create in a schema'
sql "$layer" 'REVOKE CREATE ON SCHEMA public FROM reader'
read_sql 'SELECT 1' >/dev/null || fail "db:read still refuses after the superuser reverted the grant"
# With pg_read_all_data revoked the role cannot read pg_authid, so the check fails on its first query; the role keeps
# SELECT on pg_authid to reach the membership condition, which then finds no membership.
sql "$layer" 'GRANT SELECT ON pg_authid TO reader; REVOKE pg_read_all_data FROM reader'
refuses_naming 'the role is not a member of pg_read_all_data alone'
sql "$layer" 'REVOKE SELECT ON pg_authid FROM reader'
keep
read_sql 'SELECT 1' >/dev/null || fail "db:read still refuses after keep restored the membership"
echo "a password the role set, a CREATE the superuser granted and a membership the superuser revoked each made db:read refuse naming the condition, and each was undone"

# keep fails softly while a session holds a lock on the role: it ends 0, Postgres stays Ready, its line is in the log.
in_postgres env PGAPPNAME="$lock_application" psql --no-psqlrc --command='BEGIN; ALTER ROLE reader CONNECTION LIMIT 9; SELECT pg_sleep(120)' >/dev/null 2>&1 &
holder=$!
holding() { [ "$(sql "$layer" "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$lock_application' AND wait_event = 'PgSleep'")" = 1 ]; }
until_true 60 "a session holds an uncommitted ALTER ROLE reader" holding
failed_keep_line='reader_role.sh keep: declaring the role reader failed'
failed_keeps_before="$(logged_lines "$failed_keep_line")"
keep || fail "keep ended non-zero while a session held a lock on the role"
[ "$(logged_lines "$failed_keep_line")" -gt "$failed_keeps_before" ] ||
  fail "the log of postgres-0 holds no new line of the failed keep"
kubectl --namespace "$layer" wait pod/postgres-0 --for=condition=Ready --timeout=1m
sql "$layer" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '$lock_application'" >/dev/null
wait "$holder" || true
holder=""
echo "keep ended 0 beside a lock on the role, wrote its line to the log of postgres-0 and the Pod stayed Ready"

# A role reader that keep did not declare is left as it is, and db:read refuses it.
sql "$layer" 'DROP ROLE reader'
declared_connections="$(declared_reader_connections "$layer")"
sql "$layer" "CREATE ROLE reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT
  CONNECTION LIMIT $declared_connections; GRANT pg_read_all_data TO reader"
keep
[ "$(sql "$layer" "SELECT shobj_description(oid, 'pg_authid') IS NULL FROM pg_roles WHERE rolname = 'reader'")" = t ] ||
  fail "keep declared a role reader it had not made"
kubectl --namespace "$layer" logs postgres-0 --container postgres | grep -qF 'that this script did not declare exists' ||
  fail "the log of postgres-0 holds no line of keep leaving the foreign role alone"
refuses_naming 'the role carries no declaration'
echo "keep left a role reader it did not declare alone, named it in the log, and db:read refused it"

# Without the role, db:read fails; the next start declares it again.
sql "$layer" 'DROP ROLE reader'
if read_sql 'SELECT 1' >/dev/null; then fail "db:read read although the role reader was dropped"; fi
kubectl --namespace "$layer" delete pod postgres-0 --wait --timeout=3m
pod_exists() { kubectl --namespace "$layer" get pod postgres-0 >/dev/null 2>&1; }
until_true 120 "the StatefulSet makes postgres-0 again" pod_exists
kubectl --namespace "$layer" wait pod/postgres-0 --for=condition=Ready --timeout=5m
[ "$(read_sql 'SELECT count(*) FROM reader_proof' | sed -n 3p | tr -d ' ')" = 3 ] ||
  fail "db:read does not read the proof table after the Pod's new start"
echo "after the role was dropped db:read failed, and the next start of postgres-0 declared it again"
