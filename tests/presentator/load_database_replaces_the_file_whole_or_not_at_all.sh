#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=stand_in.sh
source "$(dirname "${BASH_SOURCE[0]}")/stand_in.sh"
# `mise run presentator:load-database` on the stand-in layer: a refusal changes nothing, a fresh load leaves the live
# file equal to the source, and a source that is damaged, of another page size, without its key table or with an empty
# one, a live file that is busy, a second run at once or a kill after the copy is staged leave the old database or
# converge on the same command. Prints names, counts and verdicts, never a row.
export KUBECONFIG="$HOME/.kube/config"
namespace=presentator
holder=database-holder
loader=presentator-load

scratch="$(mktemp -d)"
shim="$scratch/shim"
output="$scratch/output"
held_output="$scratch/held-output"
mkdir -p "$shim"
old_marker="old-$(openssl rand -hex 4)"
new_marker="new-$(openssl rand -hex 4)"
held_pid=
lock_client=
cleanup() {
  local cell_status=$?
  [ -z "$held_pid" ] || pkill -KILL --session "$held_pid" 2>/dev/null || true
  [ -z "$lock_client" ] || kill "$lock_client" 2>/dev/null || true
  remove_stand_in
  delete_object --namespace "$namespace" delete pod "$holder" "$loader" --ignore-not-found --wait --timeout=2m
  rm -rf "$scratch"
  end_deletions "$cell_status"
}
trap cleanup EXIT

apply_stand_in
key_table="$(kubectl --namespace "$namespace" get configmap sqlite --output jsonpath='{.data.key-table}')"
[ -n "$key_table" ] || fail "the ConfigMap sqlite in $namespace names no key table"

# A Pod beside the web in the web's image and at its user, holding the claim read-write, to plant and read the live file.
kubectl --namespace "$namespace" get deployment web --output json | NAME="$holder" yq --input-format json --output-format json '
  .spec.template.spec as $spec | $spec.containers[] | select(.name == "web") as $web |
  {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
   "spec": {"automountServiceAccountToken": false, "enableServiceLinks": false, "terminationGracePeriodSeconds": 1,
     "imagePullSecrets": $spec.imagePullSecrets, "securityContext": $spec.securityContext,
     "containers": [{"name": "holder", "image": $web.image, "command": ["sleep", "3600"], "env": $web.env,
       "securityContext": $web.securityContext,
       "volumeMounts": [($web.volumeMounts[] | select(.name == "database")), {"name": "scratch", "mountPath": "/scratch"}]}],
     "volumes": [($spec.volumes[] | select(.name == "database")), {"name": "scratch", "emptyDir": {}}]}}' |
  kubectl --namespace "$namespace" create --filename - >/dev/null
kubectl --namespace "$namespace" wait "pod/$holder" --for=condition=Ready --timeout=3m >/dev/null

in_holder() { kubectl --namespace "$namespace" exec --stdin "$holder" --container holder -- "$@"; }
# The live file in WAL mode with the old marker as the one row of the key table.
plant_live() {
  in_holder env OLD="$old_marker" TABLE="$key_table" python3 -I - <<'PYTHON'
import os, sqlite3
live = os.environ["PRESENTATOR_DATABASE"]
for suffix in ("", "-wal", "-shm", "-journal"):
    if os.path.exists(live + suffix):
        os.remove(live + suffix)
connection = sqlite3.connect(live, isolation_level=None)
connection.execute("PRAGMA journal_mode=WAL")
table = os.environ["TABLE"]
connection.execute(f'CREATE TABLE "{table}" (name TEXT)')
connection.execute(f'INSERT INTO "{table}" VALUES (?)', (os.environ["OLD"],))
connection.close()
PYTHON
  planted_digest="$(live_digest)"
}
live_digest() { in_holder sh -c 'sha256sum "$PRESENTATOR_DATABASE" | cut -c1-64'; }
# "<rows> <old marker present> <new marker present> <integrity_check>", never a row.
live_report() {
  in_holder env OLD="$old_marker" NEW="$new_marker" TABLE="$key_table" python3 -I - <<'PYTHON'
import os, sqlite3
connection = sqlite3.connect(os.environ["PRESENTATOR_DATABASE"])
names = [row[0] for row in connection.execute('SELECT name FROM "%s"' % os.environ["TABLE"])]
print(len(names), int(os.environ["OLD"] in names), int(os.environ["NEW"] in names), connection.execute("PRAGMA integrity_check").fetchone()[0])
connection.close()
PYTHON
}
claim_listing() { in_holder sh -c 'ls -A "${PRESENTATOR_DATABASE%/*}"'; }

# make_source <file> <page size> <table> [<value>...]: a closed SQLite file in WAL mode with the values as rows.
make_source() {
  python3 -I - "$@" <<'PYTHON'
import sqlite3, sys
path, page_size, table, *values = sys.argv[1:]
connection = sqlite3.connect(path, isolation_level=None)
connection.execute(f"PRAGMA page_size={page_size}")
connection.execute("PRAGMA journal_mode=WAL")
connection.execute(f'CREATE TABLE "{table}" (name TEXT)')
connection.executemany(f'INSERT INTO "{table}" VALUES (?)', [(value,) for value in values])
connection.close()
PYTHON
}
good="$scratch/good.sqlite3"
make_source "$good" 4096 "$key_table" "$new_marker" second third
many_values=()
for number in $(seq 300); do many_values+=("row-$number-$(printf 'x%.0s' $(seq 100))"); done
damaged="$scratch/damaged.sqlite3"
make_source "$damaged" 4096 "$key_table" "${many_values[@]}"
python3 -I - "$damaged" <<'PYTHON'
import sys
path = sys.argv[1]
content = bytearray(open(path, "rb").read())
content[4096 * 2 : 4096 * 3] = b"\xff" * 4096
open(path, "wb").write(content)
PYTHON
other_page_size="$scratch/other-page-size.sqlite3"
make_source "$other_page_size" 8192 "$key_table" "$new_marker" second
without_table="$scratch/without-table.sqlite3"
make_source "$without_table" 4096 accounts "$new_marker"
empty_table="$scratch/empty-table.sqlite3"
make_source "$empty_table" 4096 "$key_table"

suspended() { kubectl --namespace flux-system get kustomization presentator --output jsonpath='{.spec.suspend}'; }
web_replicas() { kubectl --namespace "$namespace" get deployment web --output jsonpath='{.spec.replicas}'; }
loader_exists() { kubectl --namespace "$namespace" get pod "$loader" >/dev/null 2>&1; }
# run_load <file>: the command's output goes to $output and to the log; it never holds a marker.
run_load() {
  load_status=0
  mise run presentator:load-database "$1" >"$output" 2>&1 || load_status=$?
  cat "$output"
  ! grep -qF -e "$old_marker" -e "$new_marker" "$output" || fail "the command printed a row"
}
# resumed_untouched: the live file is the planted one, Flux is not suspended, the web runs and no loader is left.
resumed_untouched() {
  [ "$(live_digest)" = "$planted_digest" ] || fail "$1: the live file changed"
  [ "$(suspended)" != true ] || fail "$1: Flux stayed suspended"
  [ "$(web_replicas)" = 1 ] || fail "$1: the web is not back at 1 replica"
  ! loader_exists || fail "$1: the loader Pod is left"
}
expect_refused() {
  run_load "$1"
  [ "$load_status" -ne 0 ] || fail "$2: the command exited 0"
  grep -qF "$3" "$output" || fail "$2: the output does not say '$3'"
}
converged_on_the_source() {
  [ "$load_status" = 0 ] || fail "$1: the command exited $load_status"
  [ "$(live_report)" = "3 0 1 ok" ] || fail "$1: the live key table differs from the source: $(live_report)"
  [ "$(suspended)" != true ] || fail "$1: Flux stayed suspended"
  [ "$(web_replicas)" = 1 ] || fail "$1: the web is not back at 1 replica"
  ! loader_exists || fail "$1: the loader Pod is left"
}

# kubectl wrapper that holds the call starting `load` until the release file exists.
real_kubectl="$(mise which kubectl 2>/dev/null || command -v kubectl)"
cat >"$shim/kubectl" <<'WRAPPER'
#!/usr/bin/env bash
case "$*" in *sqlite_copy.py*)
  : >"$SHIM_FLAG"
  until [ -e "$SHIM_RELEASE" ]; do sleep 1; done ;;
esac
exec "$SHIM_REAL" "$@"
WRAPPER
chmod +x "$shim/kubectl"
# hold_at_load <file>: the command runs in a session of its own and stops at the call that would start `load`.
hold_at_load() {
  rm -f "$scratch/started" "$scratch/release"
  SHIM_REAL="$real_kubectl" SHIM_FLAG="$scratch/started" SHIM_RELEASE="$scratch/release" PATH="$shim:$PATH" \
    MISE_DISABLE_TOOLS=kubectl setsid mise run presentator:load-database "$1" >"$held_output" 2>&1 &
  held_pid=$!
  until_true 240 "the command reached the call that starts load" test -e "$scratch/started"
}
end_hold() { pkill -KILL --session "$held_pid" 2>/dev/null || true; wait "$held_pid" 2>/dev/null || true; held_pid=; }

# 1: a missing file, a non-empty -wal and a non-empty -journal beside the source each refuse before any change.
plant_live
expect_refused "$scratch/absent.sqlite3" "a missing file" "nothing changed"
resumed_untouched "a missing file"
for sidecar in -wal -journal; do
  cp "$good" "$scratch/beside$sidecar.sqlite3"
  printf 'x' >"$scratch/beside$sidecar.sqlite3$sidecar"
  expect_refused "$scratch/beside$sidecar.sqlite3" "a $sidecar beside the source" "nothing changed"
  resumed_untouched "a $sidecar beside the source"
done
echo "a missing file, a -wal and a -journal beside the source each refused with nothing changed"

# 2: a fresh load.
plant_live
run_load "$good"
converged_on_the_source "the fresh load"
listing="$(claim_listing)"
allowed="$(in_holder sh -c 'echo "${PRESENTATOR_DATABASE##*/}"')"
[ -z "$(grep -vxF -e "$allowed" -e "$allowed-wal" -e "$allowed-shm" <<<"$listing" || true)" ] ||
  fail "the claim holds a file besides the database, its -wal and its -shm"
echo "a fresh load made the live key table equal to the source's three rows, resumed Flux and left only the database's files"

# 3: a source with a damaged page and one of another page size.
for refused in "$damaged" "$other_page_size"; do
  plant_live
  expect_refused "$refused" "${refused##*/}" "exited 7"
  resumed_untouched "${refused##*/}"
done
echo "a damaged page and another page size were each refused, the live file unchanged and Flux resumed"

# 4: a connection holding the write lock of the live file.
plant_live
in_holder rm -f /scratch/locked /scratch/release
in_holder python3 -I - <<'PYTHON' &
import os, pathlib, sqlite3, time
connection = sqlite3.connect(os.environ["PRESENTATOR_DATABASE"], isolation_level=None)
connection.execute("BEGIN IMMEDIATE")
pathlib.Path("/scratch/locked").touch()
deadline = time.monotonic() + 300
while not pathlib.Path("/scratch/release").exists() and time.monotonic() < deadline:
    time.sleep(0.2)
connection.execute("ROLLBACK")
PYTHON
lock_client=$!
until_true 120 "the holder took the write lock" in_holder test -e /scratch/locked
expect_refused "$good" "a busy live file" "exited 6"
in_holder touch /scratch/release
wait "$lock_client" || fail "the lock holder did not end cleanly"
lock_client=
resumed_untouched "a busy live file"
echo "a live file with another writer was refused as busy, unchanged, and Flux resumed"

# 5: a Kustomization suspended already converges and resumes on a good source and stays suspended on a damaged one.
plant_live
flux suspend kustomization presentator
run_load "$good"
converged_on_the_source "the suspended Kustomization"
grep -qF 'suspended already' "$output" || fail "the output does not name the earlier suspension"
plant_live
flux suspend kustomization presentator
expect_refused "$damaged" "a suspended Kustomization and a damaged source" "exited 7"
if [ "$(suspended)" != true ] || [ "$(web_replicas)" != 0 ] || [ "$(live_digest)" != "$planted_digest" ]; then
  fail "a refused load on a suspended Kustomization did not leave it suspended, the web at 0 and the file unchanged"
fi
flux resume kustomization presentator --wait
echo "a suspended Kustomization was resumed after a verified load and stayed suspended after a refusal"

# 6: a kill at the call that starts load, with the copy staged.
plant_live
hold_at_load "$good"
kubectl --namespace "$namespace" get pod "$loader" --output jsonpath='{.metadata.labels}{.metadata.annotations}' >"$scratch/metadata"
[ ! -s "$scratch/metadata" ] || fail "the loader Pod carries a label or an annotation"
[ "$(kubectl --namespace "$namespace" exec "$loader" --container loader -- sh -c 'sha256sum /staging/copy | cut -c1-64')" = "$(sha256sum "$good" | cut -c1-64)" ] ||
  fail "the copy is not staged in the loader Pod"
end_hold
if [ "$(suspended)" != true ] || [ "$(web_replicas)" != 0 ] || ! loader_exists; then
  fail "the killed run did not leave Flux suspended, the web at 0 and the loader Pod"
fi
[ "$(live_digest)" = "$planted_digest" ] || fail "the killed run changed the live file"
[ -z "$(grep -vxF -e "$allowed" -e "$allowed-wal" -e "$allowed-shm" <<<"$(claim_listing)" || true)" ] || fail "the claim holds a staged copy"
run_load "$good"
converged_on_the_source "the run after the kill"
echo "a kill after staging left Flux suspended, the web at 0 and the copy only in the unlabelled loader Pod, and the same command converged"

# 7: an intact source without the key table and one whose key table is empty.
for refused in "$without_table" "$empty_table"; do
  plant_live
  expect_refused "$refused" "${refused##*/}" "exited 7"
  resumed_untouched "${refused##*/}"
done
echo "a source without the key table and one with an empty key table were each refused, the live file unchanged"

# 8: a second run while the first holds its load call.
plant_live
hold_at_load "$good"
loader_uid="$(kubectl --namespace "$namespace" get pod "$loader" --output jsonpath='{.metadata.uid}')"
expect_refused "$good" "a second run at once" "nothing changed"
if [ "$(suspended)" != true ] || [ "$(kubectl --namespace "$namespace" get pod "$loader" --output jsonpath='{.metadata.uid}')" != "$loader_uid" ]; then
  fail "the second run touched the Kustomization or the loader Pod"
fi
: >"$scratch/release"
load_status=0
wait "$held_pid" || load_status=$?
held_pid=
cat "$held_output"
! grep -qF -e "$old_marker" -e "$new_marker" "$held_output" || fail "the first run printed a row"
converged_on_the_source "the first run"
echo "a second run at once was refused with nothing changed, and the first converged once released"
