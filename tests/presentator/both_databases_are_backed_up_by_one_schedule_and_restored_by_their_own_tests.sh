#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=stand_in.sh
source "$(dirname "${BASH_SOURCE[0]}")/stand_in.sh"
# shellcheck source=../backup/restic_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../backup/restic_pod.sh"
# presentator's SQLite database and its Postgres in one namespace and one restic repository, on the stand-in layer: one
# Backup of the Schedule backup leaves one snapshot of each stream, and the restore test of each database, the SQLite
# one under restore-test and the Postgres one under postgres-restore-test, passes on it. Each reads its own stream by
# path, so a latest snapshot of the other stream's kind, written after the Backup, fails the other database's test
# alone: a snapshot of the dump's path that is no dump fails the Postgres test and leaves the SQLite one passing, and a
# snapshot of the SQLite file's path that is no database fails the SQLite test and leaves the Postgres one passing.
# Prints names, counts and verdicts, never a row. It leaves the repository's latest snapshots foreign, so no cell reads
# presentator's repository after it.
export KUBECONFIG="$HOME/.kube/config"
namespace=presentator

made_backups=()
made_jobs=()
cleanup() {
  local cell_status=$?
  delete_restic_objects
  [ "${#made_backups[@]}" = 0 ] ||
    delete_object --namespace "$namespace" delete backup.k8up.io "${made_backups[@]}" --ignore-not-found --wait --timeout=2m
  [ "${#made_jobs[@]}" = 0 ] ||
    delete_object --namespace "$namespace" delete job "${made_jobs[@]}" --ignore-not-found --cascade=foreground --wait --timeout=2m
  remove_stand_in
  end_deletions "$cell_status"
}
trap cleanup EXIT

apply_stand_in
kubectl --namespace "$namespace" wait pod/postgres-0 --for=condition=Ready --timeout=5m
kubectl --namespace "$namespace" rollout status deployment/web --timeout=5m
key_tables="$(kubectl --namespace "$namespace" get configmap postgres --output jsonpath='{.data.key-tables}')"
sqlite_table="$(kubectl --namespace "$namespace" get configmap sqlite --output jsonpath='{.data.key-table}')"
sqlite_file="$(kubectl --namespace "$namespace" get configmap sqlite --output jsonpath='{.data.snapshot-file}')"
[ -n "$key_tables" ] && [ -n "$sqlite_table" ] && [ -n "$sqlite_file" ] ||
  fail "the ConfigMaps postgres and sqlite in $namespace name no key tables, key table or snapshot file"
dump_file="$namespace-postgres.dump"
schedules="$(kubectl --namespace "$namespace" get schedules.k8up.io --output jsonpath='{.items[*].metadata.name}')"
[ "$schedules" = backup ] || fail "$namespace holds the k8up Schedules '$schedules', not the one Schedule backup"
echo "$namespace holds one k8up Schedule, backup, for both databases"

# Each database holds what its restore test needs: the SQLite key table a row, and the Postgres key tables the schema
# that the web's init container migrate made on the stand-in, the first one holding a row. The cell leaves that schema.
first_table="${key_tables%% *}"
postgres_rows="$(kubectl --namespace "$namespace" exec postgres-0 --container postgres -- psql --no-psqlrc \
  --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="SELECT count(*) FROM \"$first_table\"")" ||
  fail "the Postgres key table $first_table cannot be read, so migrate did not make the schema"
[ "${postgres_rows:-0}" -gt 0 ] || fail "the Postgres key table $first_table holds no row after migrate"
read -r -d '' plant_script <<'PYTHON' || true
import os, sqlite3
live, table = os.environ["PRESENTATOR_DATABASE"], os.environ["TABLE"]
for suffix in ("", "-wal", "-shm", "-journal"):
    if os.path.exists(live + suffix):
        os.remove(live + suffix)
connection = sqlite3.connect(live, isolation_level=None)
connection.execute(f'CREATE TABLE "{table}" (name TEXT)')
connection.execute(f'INSERT INTO "{table}" VALUES (?)', ("planted",))
connection.close()
PYTHON
kubectl --namespace "$namespace" exec deployment/web --container web -- env TABLE="$sqlite_table" python3 -I -c "$plant_script"

# snapshot_count <label> <file>: sets snapshots_found to the snapshots of the stream file in the repository.
snapshot_count() {
  run_restic "$namespace" "snapshots-$1" "restic --no-cache snapshots --json --path '/$2' 2>/dev/null | jq length"
  snapshots_found="${restic_output:-0}"
}
snapshot_count sqlite-before "$sqlite_file"
sqlite_before="$snapshots_found"
snapshot_count dump-before "$dump_file"
dump_before="$snapshots_found"

# run_backup: one Backup of the Schedule and the SQLite restore test on it, as backup:now runs them.
run_backup() {
  local output
  output="$(mise run backup:now "$namespace" 2>&1)" || fail "backup:now exited non-zero: $output"
  echo "$output"
  mapfile -t -O "${#made_backups[@]}" made_backups < <(grep -oE 'backup-now-[a-z0-9]+' <<<"$output" | sort -u)
  mapfile -t -O "${#made_jobs[@]}" made_jobs < <(grep -oE 'restore-test-now-[a-z0-9]+' <<<"$output" | sort -u)
}
run_backup
snapshot_count sqlite-after "$sqlite_file"
[ "$snapshots_found" = "$((sqlite_before + 1))" ] || fail "one Backup did not leave exactly one new snapshot of /$sqlite_file"
snapshot_count dump-after "$dump_file"
[ "$snapshots_found" = "$((dump_before + 1))" ] || fail "one Backup did not leave exactly one new snapshot of /$dump_file"
echo "one Backup left one new snapshot of /$sqlite_file and one of /$dump_file"

# The restore tests, each as a Job of its CronJob: sets status and restore_log.
postgres_test() { run_restore_test "$namespace" "$1" "" postgres-restore-test; }
sqlite_test() { run_restore_test "$namespace" "$1"; }
postgres_test_passes() {
  postgres_test "$1"
  [ "$status $restore_exits" = "passed dump 0 check 0" ] || fail "the Postgres restore test $1 ended '$status $restore_exits'"
  for table in $key_tables; do
    grep -qE "^$table: [0-9]+ rows, [0-9]+ COPY lines in the dump, equal\$" <<<"$restore_log" ||
      fail "the Postgres restore test $1 did not verify the key table $table equal to the dump"
  done
}

postgres_test_passes postgres-after-backup
echo "the Postgres restore test passes on the Backup's dump and verifies every key table: $key_tables"

# A latest snapshot of one stream's path that is no copy of it.
write_foreign_snapshot() {
  run_restic "$namespace" "foreign-$1" "printf '%s' 'not a copy' | TMPDIR=/restore restic --no-cache backup --quiet --stdin --stdin-filename '/$2'"
  [ "$restic_exit" = 0 ] || fail "restic did not write the foreign snapshot of /$2 (exit $restic_exit)"
}
write_foreign_snapshot dump "$dump_file"
sqlite_test sqlite-after-foreign-dump
[ "$status" = passed ] || fail "the SQLite restore test $status after a snapshot of /$dump_file, which is not its stream"
postgres_test postgres-after-foreign-dump
[ "$status" = failed ] || fail "the Postgres restore test $status on a latest snapshot of /$dump_file that is no dump"
echo "a latest snapshot of /$dump_file that is no dump fails the Postgres restore test and leaves the SQLite one passing"

run_backup
postgres_test_passes postgres-after-second-backup
echo "a second Backup supersedes it and the Postgres restore test passes again"

write_foreign_snapshot sqlite "$sqlite_file"
postgres_test_passes postgres-after-foreign-sqlite
sqlite_test sqlite-after-foreign-sqlite
[ "$status" = failed ] || fail "the SQLite restore test $status on a latest snapshot of /$sqlite_file that is no database"
echo "a latest snapshot of /$sqlite_file that is no database fails the SQLite restore test and leaves the Postgres one passing"
