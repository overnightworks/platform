#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=staging_cell.sh
source "$(dirname "${BASH_SOURCE[0]}")/staging_cell.sh"
# `mise run db:load-dump` puts songmaker's database, its audio claim and its bucket back to one staging snapshot: after a
# Backup and `backup:fetch`, a load without the flag into an emptied bucket leaves all three equal to the snapshot, a load
# without the flag into a bucket that holds objects refuses with all three unchanged, a dump of no snapshot refuses before
# anything is suspended, the flag makes all three equal again, and a hard kill during rclone's copy, the claim's restore
# or pg_restore leaves Flux suspended with the writers at 0 until the same command, with the flag, converges. No output
# holds the marker that every file name, file content and key of the cell carries, and no loader Pod outlives a load that
# ended. It needs APP_MANIFEST (the web's manifest, which the client Pod that reads and fills the bucket is furnished
# from). Prints names, counts and verdicts.
export KUBECONFIG="$HOME/.kube/config"
namespace="$SONGMAKER_NAMESPACE"
export APP_NAMESPACE="$namespace"
# shellcheck source=../objectstore/client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../objectstore/client_pod.sh"
claim="$(kubectl --namespace "$namespace" get configmap postgres --output jsonpath='{.data.backup-claim}')"
reading_uid="$(kubectl --namespace "$namespace" get deployment web --output jsonpath='{.spec.template.spec.securityContext.runAsUser}')"
[ -n "$claim" ] && [ -n "$reading_uid" ] || fail "the layer $namespace declares no claim or the web no runAsUser"

scratch="$(mktemp -d)"
shim="$scratch/shim"
dump="$scratch/dump"
fresh_dump="$scratch/fresh-dump"
output="$scratch/output"
mkdir "$shim"
marker="load-marker-$(openssl rand -hex 4)"
cell_directory="load-cell"
holder="claim-holder"
loader_pid=
sql() { kubectl --namespace "$namespace" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="$1"; }
on_claim() { kubectl --namespace "$namespace" exec "$holder" --container holder -- sh -c "$1"; }
cleanup() {
  local cell_status=$?
  [ -z "$loader_pid" ] || pkill -KILL --session "$loader_pid" 2>/dev/null || true
  on_claim "rm -rf '/claim/$cell_directory'" || deletion_failures=$((deletion_failures + 1))
  (run_client clear-planted-objects "$credentials_secret" clear "$bucket_variable") ||
    { delete_object --namespace "$namespace" delete pod clear-planted-objects --ignore-not-found --wait --timeout=2m; deletion_failures=$((deletion_failures + 1)); }
  delete_object --namespace "$namespace" delete pod "$holder" db-load-snapshot db-load-source --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$namespace" delete pod --selector cell=object-store --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$namespace" delete configmap object-store-client --ignore-not-found
  flux resume kustomization "$namespace" >/dev/null || deletion_failures=$((deletion_failures + 1))
  sql 'DROP TABLE IF EXISTS load_marker' >/dev/null || deletion_failures=$((deletion_failures + 1))
  delete_backups
  delete_restic_objects
  rm -rf "$scratch"
  end_deletions "$cell_status"
}
trap cleanup EXIT

# A Pod at the reading uid that holds the claim, to plant and read files on it.
NAME="$holder" CLAIM="$claim" IMAGE="$PROBE_IMAGE" USER_ID="$reading_uid" yq --null-input --output-format json '
  {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
   "spec": {"automountServiceAccountToken": false, "enableServiceLinks": false,
     "securityContext": {"runAsNonRoot": true, "runAsUser": env(USER_ID), "seccompProfile": {"type": "RuntimeDefault"}},
     "containers": [{"name": "holder", "image": strenv(IMAGE), "command": ["sleep", "3600"],
       "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
       "volumeMounts": [{"name": "claim", "mountPath": "/claim"}]}],
     "volumes": [{"name": "claim", "persistentVolumeClaim": {"claimName": strenv(CLAIM)}}]}}' |
  kubectl --namespace "$namespace" create --filename - >/dev/null
kubectl --namespace "$namespace" wait "pod/$holder" --for=condition=Ready --timeout=5m >/dev/null

# The digest of every file's path and bytes on the claim, its listing as MANIFEST lists it (size, time, path), and the
# files that are not the reading uid's, which must be none.
claim_digest() {
  on_claim "cd /claim && find . -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum | cut -c1-64 &&
    find . -type f -exec stat -c '%s %Y %n' {} + | LC_ALL=C sort | sha256sum | cut -c1-64 &&
    echo foreign \$(find . ! -user '$reading_uid' ! -path . | wc -l)"
}
# The size, sha256 and key of every object, digested by bucket_listing.
bucket_digest() {
  client_output digests digests "$bucket_variable"
  bucket_listing "$client_log"
}
suspended() { kubectl --namespace flux-system get kustomization "$namespace" --output jsonpath='{.spec.suspend}'; }
writers_at_zero() {
  [ "$(kubectl --namespace "$namespace" get deployments --output jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' | grep -vc '^0$')" = 0 ]
}
held_back() { [ "$(suspended)" = true ] && writers_at_zero; }
no_loader_pods() { [ -z "$(kubectl --namespace "$namespace" get pod db-load-snapshot db-load-source --ignore-not-found --output name)" ]; }
# state: the three digests, one line each, of what the claim, the bucket and the database hold now.
state() { printf 'claim %s\nbucket %s\ndatabase %s\n' "$(claim_digest | tr '\n' ' ')" "$(bucket_digest)" "$(sql 'SELECT value FROM load_marker')"; }
# holds_no_marker: the output of the last run holds no file name, key, file content or row.
holds_no_marker() { ! grep -qF "$marker" "$output" || fail "a run printed a file name, a key, a file's content or a row"; }
# load <file> [flag]...: the load with --compare, bounded; its output is checked for the marker and printed.
load() {
  local file="$1" status=0
  shift
  timeout -k 10 1200 mise run db:load-dump --compare "$@" "$namespace" "$file" >"$output" 2>&1 || status=$?
  cat "$output"
  holds_no_marker
  return "$status"
}
# kill_during <tool> <pattern> <background>: starts the load of the dump with the flag with a wrapper of the tool that, at
# the call matching the pattern, sets a flag and then waits for the kill, running the call beside it when background is
# true (with the wrapper's stdin, which a background command otherwise loses); kills the load's whole session once the
# flag stands.
kill_during() {
  local tool="$1" pattern="$2" background="$3" real
  real="$(mise which "$tool" 2>/dev/null || command -v "$tool")"
  cat >"$shim/$tool" <<'WRAPPER'
#!/usr/bin/env bash
case "$*" in *"$SHIM_PATTERN"*)
  if [ "$SHIM_BACKGROUND" = true ]; then "$SHIM_REAL" "$@" <&0 & fi
  : >"$SHIM_FLAG"
  sleep 600 ;;
esac
exec "$SHIM_REAL" "$@"
WRAPPER
  chmod +x "$shim/$tool"
  rm -f "$scratch/started"
  SHIM_REAL="$real" SHIM_PATTERN="$pattern" SHIM_BACKGROUND="$background" SHIM_FLAG="$scratch/started" \
    PATH="$shim:$PATH" MISE_DISABLE_TOOLS=kubectl setsid mise run db:load-dump --compare --empty-bucket "$namespace" "$dump" \
    >"$output" 2>&1 &
  loader_pid=$!
  until_true 900 "the load reached $pattern" test -e "$scratch/started"
  pkill -KILL --session "$loader_pid" || true
  wait "$loader_pid" 2>/dev/null || true
  loader_pid=
  rm -f "$shim/$tool"
}
# change_claim_and_database: the claim loses a file and gains one, and the marker row changes.
change_claim_and_database() {
  on_claim "rm '/claim/$cell_directory/second $marker.ogg'; printf stray >/claim/$cell_directory/stray"
  sql "UPDATE load_marker SET value = 'changed'" >/dev/null
}

# The snapshot: files with a space and the marker in their names, a nested one, objects of the client's base set and one
# whose key carries the marker, and a table with the marker as its row.
sql "CREATE TABLE load_marker (value text); INSERT INTO load_marker VALUES ('$marker')" >/dev/null
on_claim "mkdir -p '/claim/$cell_directory/nested' &&
  printf 'first-$marker' >'/claim/$cell_directory/nested/first $marker.ogg' &&
  printf 'second-$marker' >'/claim/$cell_directory/second $marker.ogg'"
install_client
run_client plant-clear "$credentials_secret" clear "$bucket_variable"
run_client plant-base "$credentials_secret" plant "$bucket_variable" base
run_client plant-marker "$credentials_secret" put "$bucket_variable" "$marker.bin"
run_backup load-first
mise run backup:fetch "$namespace" "$dump"
snapshot_state="$(state)"
echo "the snapshot holds a claim of $(on_claim 'find /claim -type f | grep -c .') files and a bucket of $(bucket_digest | cut -d' ' -f2) objects"

# Case 1: the bucket emptied and the claim and the database changed; a load without the flag restores all three.
change_claim_and_database
run_client empty-bucket "$credentials_secret" clear "$bucket_variable"
load "$dump" || fail "the load into an emptied bucket exited non-zero"
[ "$(state)" = "$snapshot_state" ] || fail "after the load into an emptied bucket the claim, the bucket or the database differs from the snapshot"
grep -qF "the claim of $namespace equals the snapshot" "$output" && grep -qF "the bucket $namespace equals the snapshot" "$output" ||
  fail "the load did not report the claim and the bucket equal to the snapshot"
[ "$(suspended)" != true ] && no_loader_pods || fail "after the load Flux is suspended or a loader Pod remains"
echo "a load without the flag into an emptied bucket made claim, bucket and database equal to the snapshot"

# Case 2: all three changed; a load without the flag refuses and leaves them as they were, with Flux resumed.
change_claim_and_database
run_client plant-extra "$credentials_secret" put "$bucket_variable" "extra-$marker.bin"
changed_state="$(state)"
if load "$dump"; then fail "a load without the flag into a bucket that holds objects exited 0"; fi
grep -qF -- '--empty-bucket' "$output" || fail "the refusal did not name --empty-bucket"
[ "$(state)" = "$changed_state" ] || fail "the refused load changed the claim, the bucket or the database"
[ "$(suspended)" != true ] && no_loader_pods || fail "after the refused load Flux is suspended or a loader Pod remains"
echo "a load without the flag into a bucket that held objects refused and left all three unchanged, with Flux resumed"

# Case 3: a fresh dump is of no staging snapshot; the load refuses before it suspends anything or stops a writer.
kubectl --namespace "$namespace" exec postgres-0 --container postgres -- pg_dump --format=custom >"$fresh_dump"
if load "$fresh_dump" --empty-bucket; then fail "a load of a dump of no staging snapshot exited 0"; fi
grep -qF 'no staging snapshot' "$output" || fail "the refusal did not say that the dump is of no staging snapshot"
[ "$(state)" = "$changed_state" ] || fail "the load of a dump of no snapshot changed the claim, the bucket or the database"
[ "$(suspended)" != true ] && ! writers_at_zero && no_loader_pods || fail "the load of a dump of no snapshot suspended Flux, stopped a writer or left a Pod"
echo "a load of a dump of no staging snapshot refused before the suspension and changed nothing"

# Case 4: the flag empties the bucket first; all three equal the snapshot again and the load names the next Backup.
load "$dump" --empty-bucket || fail "the load with --empty-bucket exited non-zero"
[ "$(state)" = "$snapshot_state" ] || fail "after the load with --empty-bucket the claim, the bucket or the database differs from the snapshot"
grep -qF "mise run backup:now $namespace" "$output" || fail "the load did not name the Backup that follows"
[ "$(suspended)" != true ] && no_loader_pods || fail "after the load with --empty-bucket Flux is suspended or a loader Pod remains"
echo "a load with --empty-bucket made claim, bucket and database equal to the snapshot and named the next Backup"

# Cases 5 to 7: a hard kill at each step that changes data leaves Flux suspended and the writers at 0, --resume refuses
# and the same command with the flag converges.
for kill in "kubectl|rclone copy /restore/bucket|true|rclone's copy" "kubectl|restore-claim|true|the claim's restic restore" \
  "kubectl|pg_restore --clean|true|pg_restore"; do
  IFS='|' read -r tool pattern background description <<<"$kill"
  change_claim_and_database
  run_client plant-extra "$credentials_secret" put "$bucket_variable" "extra-$marker.bin"
  kill_during "$tool" "$pattern" "$background"
  holds_no_marker
  held_back || fail "a kill during $description left Flux resumed or a writer running"
  if mise run db:load-dump --resume "$namespace" >"$output" 2>&1; then fail "--resume of a claim layer exited 0 after a kill during $description"; fi
  holds_no_marker
  grep -qF 'same command again' "$output" || fail "--resume did not name the re-run after a kill during $description"
  load "$dump" --empty-bucket || fail "the re-run after a kill during $description exited non-zero"
  [ "$(state)" = "$snapshot_state" ] || fail "the re-run after a kill during $description did not make all three equal to the snapshot"
  [ "$(suspended)" != true ] && no_loader_pods || fail "after the re-run Flux is suspended or a loader Pod remains"
  echo "a kill during $description left Flux suspended and the writers at 0, --resume refused, and the same command with the flag converged"
done
