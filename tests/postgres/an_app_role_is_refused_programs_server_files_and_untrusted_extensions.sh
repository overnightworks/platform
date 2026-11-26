#!/usr/bin/env bash
# Proves docs/ARCHITECTURE.md's Trust, on the proof layer's Postgres: that the app's role is refused a program, a
# server file, an untrusted extension, a superuser attribute, a new role and a server role, with no file made, and
# that it still creates the temporary tables, tables and plpgsql functions an app's migration needs. Needs PROOF_LAYER.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=loader_proof_setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/loader_proof_setup.sh"
export KUBECONFIG="$HOME/.kube/config"
layer="$PROOF_LAYER"
escape_file=/tmp/owner-proof

in_postgres() { kubectl --namespace "$layer" exec postgres-0 --container postgres -- "$@"; }
cleanup() {
  sql "$layer" 'DROP TABLE IF EXISTS owner_proof_table; DROP FUNCTION IF EXISTS owner_proof_function()' >/dev/null || true
  in_postgres rm -f "$escape_file" || true
}
trap cleanup EXIT

[ "$(sql "$layer" "SELECT current_user || ':' || rolsuper FROM pg_roles WHERE rolname = current_user")" = "$layer:false" ] ||
  fail "the container's psql does not connect as the role $layer without superuser"
# refused <description> <sql>: the SQL as the app's role fails with the server's error and makes no file.
refused() {
  local output
  if output="$(sql "$layer" "$2" 2>&1)"; then fail "the role $layer was let through: $1"; fi
  grep -q 'ERROR:' <<<"$output" || fail "the SQL of '$1' ended without a server error: $output"
  ! in_postgres test -e "$escape_file" || fail "after '$1', $escape_file exists"
  echo "refused: $1"
}
refused "COPY TO PROGRAM" "COPY (SELECT 1) TO PROGRAM 'touch $escape_file'"
refused "COPY FROM a server file" 'CREATE TEMPORARY TABLE owner_proof_lines (line text); COPY owner_proof_lines FROM '"'/etc/passwd'"
refused "pg_read_file" "SELECT pg_read_file('/etc/passwd')"
refused "pg_ls_dir" "SELECT pg_ls_dir('/')"
refused "lo_import of a server file" "SELECT lo_import('/etc/passwd')"
refused "CREATE EXTENSION of an untrusted one" "CREATE EXTENSION pageinspect"
refused "ALTER ROLE SUPERUSER" "ALTER ROLE $layer SUPERUSER"
refused "CREATE ROLE" "CREATE ROLE owner_proof_role"
refused "GRANT of a server role" "GRANT pg_read_server_files TO $layer"

sql "$layer" 'CREATE TEMPORARY TABLE owner_proof_temporary (value integer); INSERT INTO owner_proof_temporary VALUES (1)' >/dev/null
sql "$layer" 'CREATE TABLE owner_proof_table (value integer);
  CREATE FUNCTION owner_proof_function() RETURNS integer LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END $$' >/dev/null
[ "$(sql "$layer" 'SELECT owner_proof_function()')" = 1 ] || fail "the plpgsql function the role made does not run"
echo "accepted: a temporary table, a table and a plpgsql function in public, dropped again"
