#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=stand_in.sh
source "$(dirname "${BASH_SOURCE[0]}")/stand_in.sh"
# shellcheck source=../backup/restic_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../backup/restic_pod.sh"
# presentator's backup path on the stand-in layer, driven once end to end through the platform's own commands: a Backup as
# the Schedule would start it, while a writer in the web commits one row and raises one counter in every transaction,
# leaves one snapshot of the one stream file, whose pod restricted admits, and the restore test passes on it; `backup:fetch`
# writes that copy at mode 0600 and refuses an existing file, and the copy holds whole transactions only; a latest
# snapshot of neither format is refused and its file deleted, and a second Backup supersedes it; `presentator:load-database`
# then loads the first copy through a loader that carries no label or annotation, and the live key table equals the copy.
# Every Backup here is `backup:now`, which also runs the restore test on it; that task refuses a namespace without exactly
# one Schedule or without the CronJob, and fails on an empty key table. It runs after restore_test_reads_the_latest_copy.sh
# in the same part and adds to its repository. Prints names, counts and verdicts, never a row.
export KUBECONFIG="$HOME/.kube/config"
namespace=presentator

scratch="$(mktemp -d)"
shim="$scratch/shim"
mkdir -p "$shim"
marker="row-$(openssl rand -hex 4)"
writer=
held_pid=
shape_namespace=presentator-backup-shape
bare_namespace=presentator-backup-now-bare
made_backups=()
made_jobs=()
cleanup() {
  local cell_status=$?
  [ -z "$writer" ] || kill "$writer" 2>/dev/null || true
  [ -z "$held_pid" ] || pkill -KILL --session "$held_pid" 2>/dev/null || true
  delete_restic_objects
  delete_object delete namespace "$shape_namespace" "$bare_namespace" --ignore-not-found --wait --timeout=2m
  [ "${#made_backups[@]}" = 0 ] ||
    delete_object --namespace "$namespace" delete backup.k8up.io "${made_backups[@]}" --ignore-not-found --wait --timeout=2m
  [ "${#made_jobs[@]}" = 0 ] ||
    delete_object --namespace "$namespace" delete job "${made_jobs[@]}" --ignore-not-found --cascade=foreground --wait --timeout=2m
  remove_stand_in
  rm -rf "$scratch"
  end_deletions "$cell_status"
}
trap cleanup EXIT

apply_stand_in
key_table="$(kubectl --namespace "$namespace" get configmap sqlite --output jsonpath='{.data.key-table}')"
snapshot_file="$(kubectl --namespace "$namespace" get configmap sqlite --output jsonpath='{.data.snapshot-file}')"
[ -n "$key_table" ] && [ -n "$snapshot_file" ] || fail "the ConfigMap sqlite in $namespace names no key table or snapshot file"

# The web is the one Pod that holds the live file open, so the live file is planted, written and read in its container.
# in_web <command>...: runs in the web's container, whose environment names the database.
web_exec=(kubectl --namespace "$namespace" exec deployment/web --container web -- env TABLE="$key_table" MARKER="$marker")
in_web() { "${web_exec[@]}" "$@"; }
read -r -d '' plant_script <<'PYTHON' || true
import os, sqlite3
live, table = os.environ["PRESENTATOR_DATABASE"], os.environ["TABLE"]
for suffix in ("", "-wal", "-shm", "-journal"):
    if os.path.exists(live + suffix):
        os.remove(live + suffix)
connection = sqlite3.connect(live, isolation_level=None)
connection.execute("PRAGMA journal_mode=WAL")
connection.execute(f'CREATE TABLE "{table}" (name TEXT)')
connection.execute("CREATE TABLE counter (n INTEGER)")
connection.execute("INSERT INTO counter VALUES (0)")
connection.close()
PYTHON
# Every transaction adds one row and raises the counter by one, so a copy that holds only whole transactions has as many
# rows as the counter says. It ends at the stop file or after 15 minutes.
read -r -d '' writer_script <<'PYTHON' || true
import os, pathlib, sqlite3, time
table = os.environ["TABLE"]
stop = pathlib.Path("/tmp/writer-stop")
stop.unlink(missing_ok=True)
deadline = time.monotonic() + 900
connection = sqlite3.connect(os.environ["PRESENTATOR_DATABASE"], isolation_level=None, timeout=30)
while not stop.exists() and time.monotonic() < deadline:
    connection.execute("BEGIN IMMEDIATE")
    connection.execute(f'INSERT INTO "{table}" VALUES (?)', (os.environ["MARKER"],))
    connection.execute("UPDATE counter SET n = n + 1")
    connection.execute("COMMIT")
    time.sleep(0.005)
PYTHON
# "<rows> <counter> <integrity_check>" of the database PRESENTATOR_DATABASE names, read in one transaction, never a row;
# SUFFIX adds URI parameters, so that a closed copy is opened without a -wal created beside it.
read -r -d '' report_script <<'PYTHON' || true
import os, sqlite3
path, table = os.environ["PRESENTATOR_DATABASE"], os.environ["TABLE"]
uri = f"file:{path}?mode=ro{os.environ.get('SUFFIX', '')}"
connection = sqlite3.connect(uri, uri=True, isolation_level=None)
connection.execute("BEGIN")
rows = connection.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
counter = connection.execute("SELECT n FROM counter").fetchone()[0]
print(rows, counter, connection.execute("PRAGMA integrity_check").fetchone()[0])
PYTHON
live_report() { in_web python3 -I -c "$report_script"; }
copy_report() { PRESENTATOR_DATABASE="$1" TABLE="$key_table" SUFFIX='&immutable=1' python3 -I -c "$report_script"; }

in_web python3 -I -c "$plant_script"
"${web_exec[@]}" python3 -I -c "$writer_script" >/dev/null &
writer=$!
writer_is_committing() { local rows; read -r rows _ <<<"$(live_report)"; [ "$rows" -ge 50 ]; }
until_true 120 "the writer in the web committed 50 transactions" writer_is_committing
echo "a writer in the web commits one row and one counter step per transaction"

# --- the Backup, as the Schedule would start it ---
# backup_now <namespace>: the task under test; sets now_status and now_output, which hold no row, and the names of the
# objects it made for the exit trap to delete.
now_status=0
now_output=
backup_now() {
  now_status=0
  now_output="$(mise run backup:now "$1" 2>&1)" || now_status=$?
  echo "$now_output"
  [[ $now_output != *"$marker"* ]] || fail "backup:now printed a row"
  if [ "$1" = "$namespace" ]; then
    mapfile -t -O "${#made_backups[@]}" made_backups < <(grep -oE 'backup-now-[a-z0-9]+' <<<"$now_output" | sort -u)
    mapfile -t -O "${#made_jobs[@]}" made_jobs < <(grep -oE 'restore-test-now-[a-z0-9]+' <<<"$now_output" | sort -u)
  fi
}
# run_backup: one Backup of presentator and its restore test, to their end; fails unless the Backup succeeded and the test completed.
run_backup() {
  backup_now "$namespace"
  [ "$now_status" = 0 ] || fail "backup:now exited $now_status"
}
# snapshots_script: the snapshots of the stream file and, one per line after the count, the files of the latest.
# shellcheck disable=SC2016 # the Pod's shell expands the variable
snapshots_script='
restic --no-cache snapshots --json --path "/$SNAPSHOT_FILE" 2>/dev/null | jq length
restic --no-cache ls --json --path "/$SNAPSHOT_FILE" latest 2>/dev/null | jq --raw-output "select(.type == \"file\") | .path"'

run_restic "$namespace" snapshots-before "$snapshots_script"
snapshots_before="$(head -n 1 <<<"$restic_output")"
read -r rows_before _ <<<"$(live_report)"
run_backup
read -r rows_after _ <<<"$(live_report)"
run_restic "$namespace" snapshots-after "$snapshots_script"
mapfile -t listing <<<"$restic_output"
[ "${listing[0]}" = "$((${snapshots_before:-0} + 1))" ] ||
  fail "the Backup left ${listing[0]} snapshots of /$snapshot_file after ${snapshots_before:-0}, not one more"
[ "${#listing[@]}" = 2 ] && [ "${listing[1]}" = "/$snapshot_file" ] ||
  fail "the latest snapshot holds ${listing[*]:1}, not the one file /$snapshot_file"
echo "one Backup under the writer left one snapshot of the stream file /$snapshot_file"

# k8up's Job pod: its logs hold no row, and its template is admitted by a Namespace that enforces restricted, which this
# Namespace does not; a privileged copy of it is refused there, so the admission is what judges.
job_logs="$(kubectl --namespace "$namespace" logs --selector k8upjob=true --all-pods --tail=-1)" ||
  fail "cannot read k8up's Job logs in $namespace"
[ -n "$job_logs" ] || fail "k8up's Job logs in $namespace are empty"
[[ $job_logs != *"$marker"* ]] || fail "k8up's Job log holds a row"
job_template="$(kubectl --namespace "$namespace" get jobs --selector k8upjob=true --output json | yq --input-format json '.items[0].spec.template')"
job_account="$(yq '.spec.serviceAccountName' <<<"$job_template")"
kubectl create namespace "$shape_namespace" >/dev/null
kubectl label namespace "$shape_namespace" pod-security.kubernetes.io/enforce=restricted >/dev/null
kubectl --namespace "$shape_namespace" wait serviceaccount/default --for=create --timeout=1m >/dev/null
kubectl --namespace "$shape_namespace" create serviceaccount "$job_account" >/dev/null
job_pod="$(yq '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "backup-shape"}, "spec": .spec}' <<<"$job_template")"
shape_output="$(kubectl --namespace "$shape_namespace" create --dry-run=server --filename - <<<"$job_pod" 2>&1)" ||
  fail "k8up's Job pod is refused at restricted: $shape_output"
privileged_output="$(yq '.spec.containers[0].securityContext.privileged = true' <<<"$job_pod" |
  kubectl --namespace "$shape_namespace" create --dry-run=server --filename - 2>&1)" &&
  fail "a privileged copy of k8up's Job pod is admitted at restricted, so the check proves nothing"
[[ $privileged_output == *privileged* ]] || fail "a privileged copy of k8up's Job pod is refused for another reason: $privileged_output"
echo "k8up's Backup pod is admitted at restricted, a privileged copy of it is refused, and its log holds no row"

# The backup wrote nothing to the claim but SQLite's own files.
# shellcheck disable=SC2016 # the container's shell expands the variable
database_name="$(in_web sh -c 'echo "${PRESENTATOR_DATABASE##*/}"')"
# shellcheck disable=SC2016 # the container's shell expands the variable
claim_files="$(in_web sh -c 'ls -A "${PRESENTATOR_DATABASE%/*}"')"
[ -z "$(grep -vxF -e "$database_name" -e "$database_name-wal" -e "$database_name-shm" <<<"$claim_files" || true)" ] ||
  fail "the claim holds a file besides the database, its -wal and its -shm"
echo "the claim holds the database and SQLite's own -wal and -shm alone"

# --- the restore test reads that copy ---
run_restore_test "$namespace" restore-after-backup
[ "$status $restore_exits" = "passed dump 0 check 0" ] || fail "the restore test on the Backup's copy ended '$status $restore_exits'"
[[ $restore_log =~ ^[0-9]+$ ]] || fail "the restore test printed '$restore_log', not a count"
restored_rows="$restore_log"
echo "the restore test passes on the Backup's copy and counts $restored_rows rows"

# --- backup:fetch ---
fetched="$scratch/fetched.sqlite3"
# run_fetch <file>: backup:fetch to a file; sets fetch_status and fetch_output, which never hold a row.
run_fetch() {
  fetch_status=0
  fetch_output="$(mise run backup:fetch "$namespace" "$1" 2>&1)" || fetch_status=$?
  echo "$fetch_output"
  [[ $fetch_output != *"$marker"* ]] || fail "backup:fetch printed a row"
}
run_fetch "$fetched"
[ "$fetch_status" = 0 ] || fail "backup:fetch exited $fetch_status"
[[ $fetch_output == *"SQLite copy"* ]] || fail "backup:fetch did not name the file a SQLite copy"
[ "$(stat --format=%a "$fetched")" = 600 ] || fail "backup:fetch wrote $fetched at mode $(stat --format=%a "$fetched"), not 600"
read -r copy_rows copy_counter copy_integrity <<<"$(copy_report "$fetched")"
[ "$copy_integrity" = ok ] || fail "the fetched copy's integrity_check answers '$copy_integrity'"
[ "$copy_rows" = "$copy_counter" ] || fail "the fetched copy holds $copy_rows rows and its counter says $copy_counter, so it holds a torn transaction"
[ "$copy_rows" = "$restored_rows" ] || fail "the fetched copy holds $copy_rows rows, the restore test counted $restored_rows"
{ [ "$copy_rows" -gt "$rows_before" ] && [ "$copy_rows" -lt "$rows_after" ]; } ||
  fail "the copy's $copy_rows rows are not between the $rows_before before the Backup and the $rows_after after it"
echo "backup:fetch wrote the copy at mode 0600; it is intact, holds $copy_rows rows as its counter says, between $rows_before and $rows_after taken while the writer ran"

fetched_digest="$(sha256sum <"$fetched")"
run_fetch "$fetched"
[ "$fetch_status" != 0 ] || fail "backup:fetch overwrote the existing file"
[ "$(sha256sum <"$fetched")" = "$fetched_digest" ] || fail "backup:fetch changed the existing file while refusing it"
echo "a second backup:fetch refused the existing file and left it unchanged"

# The writer ends at its stop file, cleanly.
in_web touch /tmp/writer-stop
writer_status=0
wait "$writer" || writer_status=$?
writer=
[ "$writer_status" = 0 ] || fail "the writer in the web ended with exit $writer_status"

# --- a latest snapshot of neither format, then a second Backup ---
# The header differs from SQLite's only in the byte that is a NUL there.
run_restic "$namespace" snapshot-writer "printf '%s' 'SQLite format 3x not a database' |
  TMPDIR=/restore restic --no-cache backup --quiet --stdin --stdin-filename \"\$SNAPSHOT_FILE\""
[ "$restic_exit" = 0 ] || fail "restic did not write the foreign snapshot (exit $restic_exit)"
run_fetch "$scratch/foreign.sqlite3"
{ [ "$fetch_status" != 0 ] && [ ! -e "$scratch/foreign.sqlite3" ]; } ||
  fail "backup:fetch of a latest snapshot of neither format exited $fetch_status and left the file '$(ls "$scratch")'"
echo "a latest snapshot whose header differs from SQLite's in one byte is refused and its file is deleted"

run_backup
echo "a second Backup superseded the foreign snapshot and the restore test completes on it: it reads the latest"

# --- presentator:load-database loads the first copy ---
real_kubectl="$(mise which kubectl 2>/dev/null || command -v kubectl)"
# A kubectl wrapper that holds the call starting `load` until the release file exists, so the loader can be read.
cat >"$shim/kubectl" <<'WRAPPER'
#!/usr/bin/env bash
case "$*" in *sqlite_copy.py*)
  : >"$SHIM_FLAG"
  until [ -e "$SHIM_RELEASE" ]; do sleep 1; done ;;
esac
exec "$SHIM_REAL" "$@"
WRAPPER
chmod +x "$shim/kubectl"
load_output="$scratch/load-output"
SHIM_REAL="$real_kubectl" SHIM_FLAG="$scratch/started" SHIM_RELEASE="$scratch/release" PATH="$shim:$PATH" \
  MISE_DISABLE_TOOLS=kubectl setsid mise run presentator:load-database "$fetched" >"$load_output" 2>&1 &
held_pid=$!
until_true 240 "presentator:load-database reached the call that starts the load" test -e "$scratch/started"

# The web's template carries the backup command; the loader, the one Pod here that no controller owns, carries no label or
# annotation, so no Backup streams from it.
carries_command="$(kubectl --namespace "$namespace" get deployment web --output json | yq --input-format json \
  '.spec.template.metadata.annotations | has("k8up.io/backupcommand")')"
[ "$carries_command" = true ] || fail "the web's template carries no k8up.io/backupcommand, so the loader proves nothing"
loader_pods="$(kubectl --namespace "$namespace" get pods --output json | yq --input-format json \
  '[.items[] | select(.metadata.ownerReferences == null and .metadata.deletionTimestamp == null)] | map(.metadata.name + ":" + ((.metadata.annotations // {}) | length | to_string) + ":" + ((.metadata.labels // {}) | length | to_string)) | join(" ")')"
one_bare_loader='^[^: ]+:0:0$'
[[ $loader_pods =~ $one_bare_loader ]] || fail "the Pods no controller owns, as name:annotations:labels, are '$loader_pods', not one loader with none"
echo "the loader carries no annotation and no label, although the web's template carries the backup command"

: >"$scratch/release"
load_status=0
wait "$held_pid" || load_status=$?
held_pid=
cat "$load_output"
[ "$load_status" = 0 ] || fail "presentator:load-database exited $load_status"
! grep -qF "$marker" "$load_output" || fail "presentator:load-database printed a row"
until_true 120 "the web answers again" in_web true
read -r live_rows live_counter live_integrity <<<"$(live_report)"
{ [ "$live_rows" = "$copy_rows" ] && [ "$live_counter" = "$copy_counter" ] && [ "$live_integrity" = ok ]; } ||
  fail "the live file holds $live_rows rows, counter $live_counter, integrity $live_integrity; the copy $copy_rows, $copy_counter"
echo "presentator:load-database made the live key table equal to the copy's $copy_rows rows, and the web is back"

# --- backup:now refuses what it cannot run and fails on an empty key table ---
# A namespace with no Schedule, then one Schedule without the CronJob, then two Schedules: each refusal makes no Backup.
refuses_with() {
  backup_now "$bare_namespace"
  [ "$now_status" != 0 ] && [[ $now_output == *"$1"* ]] || fail "backup:now in $bare_namespace exited $now_status, not a refusal that says '$1'"
  [ -z "$(kubectl --namespace "$bare_namespace" get backups.k8up.io,jobs --output name)" ] ||
    fail "the refusal in $bare_namespace left a Backup or a Job"
}
kubectl create namespace "$bare_namespace" >/dev/null
refuses_with "holds 0 k8up Schedules"
schedule_copy() {
  kubectl --namespace "$namespace" get schedule backup --output json | NAME="$1" yq --input-format json --output-format json \
    '{ "apiVersion": .apiVersion, "kind": .kind, "metadata": { "name": strenv(NAME) }, "spec": .spec }' |
    kubectl --namespace "$bare_namespace" create --filename - >/dev/null
}
schedule_copy backup
refuses_with "holds no CronJob restore-test"
schedule_copy backup-second
refuses_with "holds 2 k8up Schedules"
echo "backup:now refuses a namespace with no Schedule, one without the CronJob and one with two Schedules, and makes no object"

read -r -d '' empty_script <<'PYTHON' || true
import os, sqlite3
connection = sqlite3.connect(os.environ["PRESENTATOR_DATABASE"], isolation_level=None, timeout=30)
connection.execute('DELETE FROM "' + os.environ["TABLE"].replace('"', '""') + '"')
PYTHON
in_web python3 -I -c "$empty_script"
read -r live_rows _ <<<"$(live_report)"
[ "$live_rows" = 0 ] || fail "the key table of the live file holds $live_rows rows after it was emptied"
backup_now "$namespace"
{ [ "$now_status" != 0 ] && [[ $now_output =~ Backup\ backup-now-[a-z0-9]+\ of\ $namespace\ Succeeded ]] &&
  [[ $now_output =~ restore\ test\ Job\ restore-test-now-[a-z0-9]+\ of\ $namespace\ Failed ]]; } ||
  fail "backup:now on an empty key table exited $now_status, not a succeeded Backup and a failed restore test"
echo "backup:now fails naming the restore test Job on an empty key table, after a Backup that succeeded"
echo "the cell took $SECONDS seconds"
