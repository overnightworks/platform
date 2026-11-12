#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=stand_in.sh
source "$(dirname "${BASH_SOURCE[0]}")/stand_in.sh"
# `backup:now` on the stand-in layer of presentator: a namespace with no Schedule `backup` or `postgres`, one with a Schedule
# and no CronJob restore-test, and one with both Schedules each end non-zero with a refusal that says what to do and make
# no Backup and no Job; and on a key table with no row, the Backup succeeds and the restore test Job fails, both named.
# It runs in the part presentator-backup, after backup_streams_a_consistent_copy_that_fetch_and_load_restore.sh, whose
# repository it adds a snapshot to. Prints names, counts and verdicts, never a row.
export KUBECONFIG="$HOME/.kube/config"
namespace=presentator
bare_namespace=presentator-backup-now-bare
made_backups=()
made_jobs=()
cleanup() {
  local cell_status=$?
  delete_object delete namespace "$bare_namespace" --ignore-not-found --wait --timeout=2m
  [ "${#made_backups[@]}" = 0 ] ||
    delete_object --namespace "$namespace" delete backup.k8up.io "${made_backups[@]}" --ignore-not-found --wait --timeout=2m
  [ "${#made_jobs[@]}" = 0 ] ||
    delete_object --namespace "$namespace" delete job "${made_jobs[@]}" --ignore-not-found --cascade=foreground --wait --timeout=2m
  remove_stand_in
  end_deletions "$cell_status"
}
trap cleanup EXIT

apply_stand_in
key_table="$(kubectl --namespace "$namespace" get configmap sqlite --output jsonpath='{.data.key-table}')"
[ -n "$key_table" ] || fail "the ConfigMap sqlite in $namespace names no key table"

# backup_now <namespace>: the task under test; sets now_status and now_output, and the names of the objects it made in
# presentator for the exit trap to delete.
now_status=0
now_output=
backup_now() {
  now_status=0
  now_output="$(mise run backup:now "$1" 2>&1)" || now_status=$?
  echo "$now_output"
  if [ "$1" = "$namespace" ]; then
    mapfile -t -O "${#made_backups[@]}" made_backups < <(grep -oE 'backup-now-[a-z0-9]+' <<<"$now_output" | sort -u)
    mapfile -t -O "${#made_jobs[@]}" made_jobs < <(grep -oE 'restore-test-now-[a-z0-9]+' <<<"$now_output" | sort -u)
  fi
}

# --- the refusals, each in a namespace the cell made ---
refuses_with() {
  backup_now "$bare_namespace"
  [ "$now_status" != 0 ] && [[ $now_output == *"$1"* ]] || fail "backup:now in $bare_namespace exited $now_status, not a refusal that says '$1'"
  [ -z "$(kubectl --namespace "$bare_namespace" get backups.k8up.io,jobs --output name)" ] ||
    fail "the refusal in $bare_namespace left a Backup or a Job"
}
schedule_copy() {
  kubectl --namespace "$namespace" get schedule backup --output json | NAME="$1" yq --input-format json --output-format json \
    '{ "apiVersion": .apiVersion, "kind": .kind, "metadata": { "name": strenv(NAME) }, "spec": .spec }' |
    kubectl --namespace "$bare_namespace" create --filename - >/dev/null
}
kubectl create namespace "$bare_namespace" >/dev/null
refuses_with "holds 0 k8up Schedules"
schedule_copy backup
refuses_with "holds no CronJob restore-test"
schedule_copy postgres
refuses_with "holds 2 k8up Schedules"
echo "backup:now refuses a namespace with no Schedule, one without the CronJob and one with both Schedules, and makes no object"

# --- an empty key table ---
web_exec=(kubectl --namespace "$namespace" exec deployment/web --container web -- env TABLE="$key_table")
read -r -d '' empty_table_script <<'PYTHON' || true
import os, sqlite3
live, table = os.environ["PRESENTATOR_DATABASE"], os.environ["TABLE"]
for suffix in ("", "-wal", "-shm", "-journal"):
    if os.path.exists(live + suffix):
        os.remove(live + suffix)
connection = sqlite3.connect(live, isolation_level=None)
connection.execute("PRAGMA journal_mode=WAL")
connection.execute(f'CREATE TABLE "{table}" (name TEXT)')
connection.close()
PYTHON
"${web_exec[@]}" python3 -I -c "$empty_table_script"
backup_now "$namespace"
{ [ "$now_status" != 0 ] && [[ $now_output =~ Backup\ backup-now-[a-z0-9]+\ of\ $namespace\ Succeeded ]] &&
  [[ $now_output =~ restore\ test\ Job\ restore-test-now-[a-z0-9]+\ of\ $namespace\ Failed ]]; } ||
  fail "backup:now on an empty key table exited $now_status, not a succeeded Backup and a failed restore test"
echo "backup:now fails naming the restore test Job on an empty key table, after a Backup that succeeded"
