#!/bin/sh
# check-key-tables.sh [--counts-only]: for each table the file key-tables beside it names, the table's row count in the
# database libpq's PG* settings name and, from the custom-format dump on stdin, its COPY data lines and whether both are
# equal; exits 1 when one differs. --counts-only reads no dump. It prints names and counts, never a row.
set -euo pipefail
tables="$(cat "$(dirname "$0")/key-tables")"
dump_lines=""
# A data block ends only at a line \. alone, which COPY's text format never holds inside a row.
[ "${1-}" = --counts-only ] || dump_lines="$(pg_restore --data-only --file=- | awk '
  table == "" && /^COPY / { table = $2; sub(/^public[.]/, "", table); gsub(/"/, "", table); lines[table] += 0; next }
  table != "" && /^\\[.]$/ { table = ""; next }
  table != "" { lines[table]++ }
  END { for (table in lines) print table, lines[table] }')"
status=0
for table in $tables; do
  rows="$(psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="SELECT count(*) FROM \"$table\"")"
  if [ "${1-}" = --counts-only ]; then echo "$table: $rows rows" && continue; fi
  lines="$(printf '%s\n' "$dump_lines" | awk -v table="$table" '$1 == table { print $2 }')"
  verdict=equal
  [ "$rows" = "${lines:-0}" ] || { verdict=DIFFERS && status=1; }
  echo "$table: $rows rows, ${lines:-0} COPY lines in the dump, $verdict"
done
exit "$status"
