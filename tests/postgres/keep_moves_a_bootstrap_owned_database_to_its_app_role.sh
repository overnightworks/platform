#!/usr/bin/env bash
# Proves docs/ARCHITECTURE.md's Trust, on throwaway servers inside the proof layer's Postgres container, each started
# as the image starts one, listening on the Pod's address on a port of its own: that app_role.sh keep moves a database
# that the bootstrap role owns, as the live servers hold theirs, to its app role without a superuser, and leaves the
# extension, the temporary objects of a superuser's session and a second run alone; that it reaches the same state on a
# fresh server, whose initdb objects it leaves; and that it refuses a kind of object it does not move, leaving the app
# role a superuser that logs in with the Secret's password. The database of the legacy server is the proof layer's own,
# dumped with its owners. Needs PROOF_LAYER.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=loader_proof_setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/loader_proof_setup.sh"
# shellcheck source=app_role_target.sh
source "$(dirname "${BASH_SOURCE[0]}")/app_role_target.sh"
export KUBECONFIG="$HOME/.kube/config"
layer="$PROOF_LAYER"
work=/tmp/keep-proof
legacy_port=5433 fresh_port=5434 refused_port=5435
holder=""

in_pod() { kubectl --namespace "$layer" exec postgres-0 --container postgres -- "$@"; }
# start_server <name> <port> <bootstrap role>: a server initialised and started as the image does: the bootstrap role with
# the Secret's password, initdb's trust for the container's loopback, the line that asks every other address for a
# password, and a database named like the layer.
start_server() {
  in_pod sh -c '
    set -eu
    mkdir -p "$1/$2"
    initdb --pgdata="$1/$2/data" --username="$4" --pwfile=/run/secrets/postgres/password >/dev/null
    echo "host all all all scram-sha-256" >>"$1/$2/data/pg_hba.conf"
    pg_ctl --pgdata="$1/$2/data" --log="$1/$2/log" --wait --silent \
      --options="-p $3 -c listen_addresses=* -c unix_socket_directories=$1/$2 -c shared_buffers=16MB" start
    PGHOST=127.0.0.1 PGPORT="$3" createdb --username="$4" "$PGDATABASE"' sh "$work" "$1" "$2" "$3"
}
stop_servers() {
  in_pod sh -c 'for server in "$1"/*/data; do [ ! -d "$server" ] || pg_ctl --pgdata="$server" --mode=immediate --silent stop || true; done
    rm -rf "$1"' sh "$work" || true
}
cleanup() {
  [ -z "$holder" ] || kill "$holder" 2>/dev/null || true
  stop_servers
}
trap cleanup EXIT
# as <port> <login> <sql>: the SQL on the throwaway server.
as() { server_psql "$layer" "$1" "$2" --command="$3"; }
# keep <port>: app_role.sh as the container's hook runs it, against the server on the port; the output is what it wrote.
keep() { in_pod env PGHOST=127.0.0.1 PGPORT="$1" sh /etc/postgres-roles/app_role.sh keep 2>&1; }
# state <port>: a digest of what keep decides: each role's attributes, the database's owner, the extensions with their
# owners and the owner of every object above the ones initdb made, which a second run leaves as it is.
state() {
  as "$1" postgres "SELECT md5(string_agg(line, E'\n' ORDER BY line)) FROM (
      SELECT format('role %s %s %s %s %s', rolname, rolsuper, rolcanlogin, rolcreatedb, rolcreaterole) AS line FROM pg_roles
        WHERE rolname !~ '^pg_'
      UNION ALL SELECT format('database %s %s', datname, pg_get_userbyid(datdba)) FROM pg_database
      UNION ALL SELECT format('extension %s %s', extname, pg_get_userbyid(extowner)) FROM pg_extension
      UNION ALL SELECT format('class %s %s', oid, pg_get_userbyid(relowner)) FROM pg_class WHERE oid >= 16384
      UNION ALL SELECT format('type %s %s', oid, pg_get_userbyid(typowner)) FROM pg_type WHERE oid >= 16384
      UNION ALL SELECT format('proc %s %s', oid, pg_get_userbyid(proowner)) FROM pg_proc WHERE oid >= 16384) lines"
}
no_failures() {
  local failures
  failures="$(app_role_failures "$layer" "$1")"
  [ -z "$failures" ] || fail "$2: $failures"
}

kubectl --namespace "$layer" wait pod/postgres-0 --for=condition=Ready --timeout=5m
key_table="$(kubectl --namespace "$layer" get configmap postgres -o jsonpath='{.data.key-tables}')"
key_table="${key_table%% *}"
first_table_exists() { [ "$(sql_of_the_pod "SELECT to_regclass('\"$key_table\"') IS NOT NULL")" = t ]; }
sql_of_the_pod() { server_psql "$layer" 5432 "$layer" --command="$1"; }
until_true 300 "the first key table $key_table of $layer exists" first_table_exists

# The legacy server: the bootstrap role is the app's role, the objects are its own and an extension is its creator's.
start_server legacy "$legacy_port" "$layer"
in_pod sh -c 'pg_dump --format=custom | PGHOST=127.0.0.1 PGPORT="$1" pg_restore --dbname="$PGDATABASE" --exit-on-error' sh "$legacy_port"
as "$legacy_port" "$layer" 'CREATE EXTENSION pageinspect'
owned_tables="$(as "$legacy_port" "$layer" "SELECT count(*) FROM pg_class WHERE relkind = 'r' AND relowner = 10 AND oid >= 16384")"
[ "$owned_tables" -gt 0 ] || fail "the dump of $layer holds no table, so the cell would move nothing"
echo "the legacy server: $layer is its bootstrap role and owns $owned_tables tables, with $(as "$legacy_port" "$layer" \
  "SELECT count(*) FROM pg_class WHERE relowner = 10 AND oid >= 16384 AND relkind IN ('v', 'S', 'i')") views, sequences and indexes besides"
as "$legacy_port" "$layer" 'CREATE ROLE app_role_transfer SUPERUSER LOGIN; CREATE ROLE temporary_holder SUPERUSER LOGIN'
kubectl --namespace "$layer" exec postgres-0 --container postgres -- env PGHOST=127.0.0.1 PGPORT="$legacy_port" \
  psql --no-psqlrc --username=temporary_holder --command='CREATE TEMPORARY TABLE held (token text)' \
  --command='INSERT INTO held VALUES (repeat($$x$$, 4000))' --command='SELECT pg_sleep(300)' >/dev/null 2>&1 &
holder=$!
# held <login>: the superuser session is open, as the login sees it; only a superuser sees another role's state.
held() { [ "$(as "$legacy_port" "$1" "SELECT count(*) FROM pg_stat_activity WHERE usename = 'temporary_holder' AND state = 'active'")" = 1 ]; }
until_true 60 "a superuser session holds a used temporary table" held "$layer"

output="$(keep "$legacy_port")" || fail "keep ended non-zero: $output"
[ -z "$output" ] || fail "keep wrote on the legacy server: $output"
no_failures "$legacy_port" "after keep on the legacy server"
[ "$(as "$legacy_port" postgres "SELECT pg_get_userbyid(extowner) FROM pg_extension WHERE extname = 'pageinspect'")" = postgres ] ||
  fail "pageinspect is not the superuser's after keep"
held postgres || fail "the superuser session with a temporary table did not stay open through keep"
echo "keep on the legacy server: planted app_role_transfer dropped, $layer moved and demoted, pageinspect the superuser's, the temporary table's session open"
before="$(state "$legacy_port")"
output="$(keep "$legacy_port")" || fail "keep ended non-zero: $output"
[ -z "$output" ] || fail "the second keep wrote: $output"
[ "$(state "$legacy_port")" = "$before" ] || fail "the second keep changed the server"
no_failures "$legacy_port" "after the second keep"
echo "a second keep left the roles, the owners and the extension as they were"

# A fresh server: the bootstrap role is postgres, and initdb's own objects stay its.
start_server fresh "$fresh_port" postgres
output="$(keep "$fresh_port")" || fail "keep ended non-zero: $output"
[ -z "$output" ] || fail "keep wrote on the fresh server: $output"
no_failures "$fresh_port" "after keep on the fresh server"
echo "keep on the fresh server created $layer, owner of its database, and left initdb's objects"

# A kind that keep does not move refuses the switch, whole.
start_server refused "$refused_port" "$layer"
as "$refused_port" "$layer" 'CREATE TEXT SEARCH CONFIGURATION public.owner_proof (COPY = pg_catalog.english)'
output="$(keep "$refused_port")" || fail "keep ended non-zero: $output"
grep -qF 'text search configuration' <<<"$output" || fail "keep did not name the kind it refused: $output"
[ "$(as "$refused_port" postgres "SELECT rolsuper FROM pg_roles WHERE rolname = '$layer'")" = t ] ||
  fail "keep demoted $layer although it refused the switch"
[ "$(over_the_pod_address "$layer" "$refused_port" "$layer" with)" = "$layer" ] ||
  fail "$layer does not log in over the Pod's address with the Secret's password after the refusal"
for password in with without; do
  if over_the_pod_address "$layer" "$refused_port" postgres "$password" >/dev/null 2>&1; then
    fail "postgres logged in over the Pod's address $password a password after the refusal"
  fi
done
echo "keep refused a text search configuration, left $layer a superuser that logs in with the Secret's password, and wrote: ${output//$'\n'/ | }"
