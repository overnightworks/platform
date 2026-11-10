#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
# shellcheck source=stand_in.sh
source "$(dirname "${BASH_SOURCE[0]}")/stand_in.sh"
# shellcheck source=../backup/restic_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../backup/restic_pod.sh"
# presentator's restore test on the stand-in layer and its own repository on the rest-server: it reads with the k8up
# operator's image at the Postgres restore test's schedule; it fails without a snapshot, on a latest copy whose key table
# is empty or missing and on one with a damaged page, and passes on a good copy written after the damaged one, printing
# its count; presentator's credentials reach only its own repository, and a namespace without one reaches the server not.
# Each copy is built on the runner and written into the repository by a restic Pod. Prints names, counts and verdicts,
# never a row.
export KUBECONFIG="$HOME/.kube/config"
namespace=presentator

scratch="$(mktemp -d)"
marker="row-$(openssl rand -hex 4)"
good_rows=3
cleanup() {
  local cell_status=$?
  delete_restic_objects
  remove_stand_in
  rm -rf "$scratch"
  end_deletions "$cell_status"
}
trap cleanup EXIT

apply_stand_in
key_table="$(kubectl --namespace "$namespace" get configmap sqlite --output jsonpath='{.data.key-table}')"
repository="$(kubectl --namespace "$namespace" get configmap sqlite --output jsonpath='{.data.backup-repository}')"
[ -n "$key_table" ] && [ -n "$repository" ] || fail "the ConfigMap sqlite in $namespace names no key table or repository"

# The restic that reads presentator's repository is the one the operator's Job pods write with, and the test runs when
# every Postgres namespace's does.
operator_image="$(kubectl --namespace k8up-system get deployment k8up --output jsonpath='{.spec.template.spec.containers[0].image}')"
restore_test="$(kubectl --namespace "$namespace" get cronjob restore-test --output json)"
dump_image="$(yq '.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "restic-dump") | .image' <<<"$restore_test")"
[ "$dump_image" = "$operator_image" ] || fail "presentator's restore test reads with $dump_image, the operator runs $operator_image"
postgres_namespace="${BACKUP_NAMESPACES%% *}"
when='.spec.schedule + " " + .spec.timeZone'
schedule="$(yq "$when" <<<"$restore_test")"
postgres_schedule="$(kubectl --namespace "$postgres_namespace" get cronjob restore-test --output json | yq "$when")"
[ "$schedule" = "$postgres_schedule" ] ||
  fail "presentator's restore test runs at '$schedule', the one of $postgres_namespace at '$postgres_schedule'"
echo "the restore test reads with the operator's own image at the Postgres restore test's schedule ($schedule)"

init_restic_repository "$namespace"
echo "$restic_output"

# make_copy <kind>: a SQLite file of the kind in the scratch directory, built by the runner's Python; prints its path.
make_copy() {
  local copy="$scratch/$1.sqlite3"
  COPY="$copy" KIND="$1" TABLE="$key_table" MARKER="$marker" GOOD_ROWS="$good_rows" python3 -I - <<'PYTHON'
import contextlib, os, sqlite3
path, kind, table = os.environ["COPY"], os.environ["KIND"], os.environ["TABLE"]
quoted = '"' + table.replace('"', '""') + '"'
rows = {"good": [f"{os.environ['MARKER']}-{number}" for number in range(int(os.environ["GOOD_ROWS"]))],
        "damaged": [f"{os.environ['MARKER']}-{number:04d}-" + "x" * 100 for number in range(300)]}.get(kind, [])
with contextlib.closing(sqlite3.connect(path, isolation_level=None)) as connection:
    connection.execute("PRAGMA page_size=4096")
    connection.execute(f"CREATE TABLE {quoted if kind != 'missing-table' else 'other'} (name TEXT)")
    if rows:
        connection.executemany(f"INSERT INTO {quoted} VALUES (?)", [(row,) for row in rows])
if kind == "damaged":
    content = bytearray(open(path, "rb").read())
    content[4096 * 2 : 4096 * 3] = b"\xff" * 4096
    open(path, "wb").write(content)
PYTHON
  echo "$copy"
}

# write_snapshot <kind>: the copy written into the repository as the restore test's snapshot file, one new snapshot;
# restic stages its packs in TMPDIR, and the Pod's one writable path is its emptyDir.
write_snapshot() {
  local copy
  copy="$(base64 --wrap=0 "$(make_copy "$1")")"
  run_restic "$namespace" snapshot-writer "printf '%s' '$copy' | base64 -d |
    TMPDIR=/restore restic --no-cache backup --quiet --stdin --stdin-filename \"\$SNAPSHOT_FILE\""
  [ "$restic_exit" = 0 ] || fail "restic did not write the $1 copy into presentator's repository (exit $restic_exit)"
}

# run_test <job>: the CronJob run as a Job to its end; sets outcome to "<passed|failed> dump <exit> check <exit>" and
# check_output to what the check printed.
run_test() {
  run_restore_test "$namespace" "$1"
  outcome="$status $restore_exits"
  check_output="$restore_log"
  [[ $check_output != *"$marker"* ]] || fail "the restore test $1 printed a row"
}

run_test no-snapshot
[[ $outcome == "failed dump "[1-9]*" check none" ]] || fail "without a snapshot the restore test ended '$outcome'"
echo "without a snapshot the restore test fails at the dump: $outcome"

# The check's verdict that the copy fails; any other exit, CPython's own 1 included, is a crash.
verdict_exit="$(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import sqlite_copy; print(sqlite_copy.VERDICT_EXIT)' \
  "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/sqlite/scripts")"
for kind in empty-table missing-table damaged; do
  write_snapshot "$kind"
  run_test "$kind"
  [ "$outcome" = "failed dump 0 check $verdict_exit" ] || fail "on a latest copy with $kind the restore test ended '$outcome'"
  echo "on a latest copy with $kind the restore test fails at the check: $outcome"
done

write_snapshot good
run_test good
[ "$outcome" = "passed dump 0 check 0" ] && [ "$check_output" = "$good_rows" ] ||
  fail "on a good copy written after the damaged one the restore test ended '$outcome', printing '$check_output'"
echo "on a good copy written after the damaged one the restore test passes, printing the count $check_output"

# presentator's user reaches its own repository and no other: --private-repos admits a user only to the path of its name.
# The ConfigMap's URL ends in a slash, which the rest-server would answer with a redirect before the path.
own="${repository%/}"
rest_base="$(dirname "$own")"
foreign="$postgres_namespace"
run_restic "$namespace" isolation-check "
status() {
  printf 'user = \"%s:%s\"\n' \"\$RESTIC_REST_USERNAME\" \"\$RESTIC_REST_PASSWORD\" |
    curl --silent --output /dev/null --write-out '%{http_code}\n' --retry 5 --retry-connrefused --retry-delay 2 \
      --retry-max-time 30 --config - \"\$@\"
}
status '$own/config'
status '$rest_base/$foreign/config'
status --request DELETE '$rest_base/$foreign/config'"
mapfile -t statuses <<<"$restic_output"
[ "${statuses[0]}" = 200 ] || fail "presentator's credentials got ${statuses[0]} at its own repository, not 200"
[[ ${statuses[1]} == 40[13] ]] || fail "presentator's credentials got ${statuses[1]} under /$foreign/, not 401 or 403"
[[ ${statuses[2]} == 40[13] ]] || fail "presentator's credentials got ${statuses[2]} deleting /$foreign/config, not 401 or 403"
echo "presentator's credentials read its own repository (200) and are refused at $foreign's (${statuses[1]}, ${statuses[2]})"

request "$OUTSIDE_NAMESPACE" outside-namespace "$UNROUTED_HOST" "$own/config" --retry 0
[ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; } ||
  fail "a pod in $OUTSIDE_NAMESPACE reached the rest-server (status '$status', curl exit $exit_code)"
echo "a pod in $OUTSIDE_NAMESPACE gets no answer from the rest-server"
