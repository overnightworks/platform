#!/bin/sh
# restore_test.sh <dump>: restores the dump into a throwaway server under /tmp and fails unless the namespace's first
# key table holds a row and every key table holds as many rows as the dump. It prints names and counts, never a row:
# an error of pg_restore or of the server quotes the row it failed on, so both stay silent and pg_restore's messages go
# to a file under the server's directory, which only the pod's own user reads and which dies with the pod.
# shellcheck disable=SC3040 # busybox ash, this image's sh, sets pipefail.
set -euo pipefail
dump="$1"
checks=/etc/postgres-checks
server=/tmp/restore-test
umask 077
export PGHOST="$server"
mkdir -p "$server"
initdb --pgdata="$server/data" --username="$PGUSER" --auth=trust --no-sync >/dev/null
pg_ctl --pgdata="$server/data" --wait --silent --log="$server/server.log" \
  --options="-c listen_addresses='' -c unix_socket_directories=$server -c fsync=off -c log_min_messages=panic -c log_min_error_statement=panic" start
trap 'pg_ctl --pgdata="$server/data" --mode=immediate --silent stop' EXIT
createdb "$PGDATABASE"
restore_status=0
PGOPTIONS='-c log_min_messages=panic -c log_min_error_statement=panic' \
  pg_restore --exit-on-error --no-owner --dbname="$PGDATABASE" "$dump" 2>"$server/restore.log" || restore_status=$?
if [ "$restore_status" != 0 ]; then
  echo "restore-test: pg_restore exited $restore_status with $(grep -c . "$server/restore.log" || true) message lines"
  exit 1
fi
counts="$(sh "$checks/check-key-tables.sh" --counts-only)"
first_table="$(printf '%s\n' "$counts" | head -n 1)"
case "$first_table" in
  *": 0 rows") echo "restore-test: the first key table is empty: $first_table"; exit 1 ;;
esac
sh "$checks/check-key-tables.sh" <"$dump"
echo "restore-test: the dump restored and its key tables are verified"
