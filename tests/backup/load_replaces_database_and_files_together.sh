#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# `db:load-dump --files` replaces songmaker's database and its audio claim together: a fresh and a repeated load leave both
# equal to the source, the source tree unchanged, and no output names a file or a row; a hard kill during rsync or during
# pg_restore leaves Flux suspended and the writers at 0 until the same command runs again. Prints names, counts and verdicts.
export KUBECONFIG="$HOME/.kube/config"
namespace="$SONGMAKER_NAMESPACE"
claim="$(kubectl --namespace "$namespace" get configmap postgres --output jsonpath='{.data.backup-claim}')"
reading_uid="$(kubectl --namespace "$namespace" get deployment web --output jsonpath='{.spec.template.spec.securityContext.runAsUser}')"
[ -n "$claim" ] && [ -n "$reading_uid" ] || fail "the layer $namespace declares no claim or the web no runAsUser"

scratch="$(mktemp -d)"
tree="$scratch/tree"
shim="$scratch/shim"
dump="$scratch/dump"
output="$scratch/output"
mkdir -p "$tree/nested" "$shim"
marker="load-marker-$(openssl rand -hex 4)"
holder="claim-holder"
loader_pid=
sql() { kubectl --namespace "$namespace" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="$1"; }
cleanup() {
  local cell_status=$?
  [ -z "$loader_pid" ] || pkill -KILL --session "$loader_pid" 2>/dev/null || true
  delete_object --namespace "$namespace" delete pod "$holder" db-load-files --ignore-not-found --wait --timeout=2m
  flux resume kustomization "$namespace" >/dev/null || deletion_failures=$((deletion_failures + 1))
  sql 'DROP TABLE IF EXISTS load_marker' >/dev/null || deletion_failures=$((deletion_failures + 1))
  rm -rf "$scratch"
  end_deletions "$cell_status"
}
trap cleanup EXIT

# The source: files with a space and the marker in their names, which no output may print.
printf 'first' >"$tree/nested/first $marker.ogg"
printf 'second' >"$tree/second take.ogg"
sql "CREATE TABLE load_marker (value text); INSERT INTO load_marker VALUES ('$marker')" >/dev/null
kubectl --namespace "$namespace" exec postgres-0 --container postgres -- pg_dump --format=custom >"$dump"

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
on_claim() { kubectl --namespace "$namespace" exec "$holder" --container holder -- sh -c "$1"; }
# The digest of every file's path and bytes under a directory, read on the claim or on this machine.
digest_command='find . -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum | cut -c1-64'
claim_digest() { on_claim "cd /claim && $digest_command"; }
tree_digest() { (cd "$tree" && bash -c "$digest_command"); }
tree_listing() { (cd "$tree" && find . -exec stat -c '%n %s %Y %a' {} + | LC_ALL=C sort | sha256sum | cut -c1-64); }

suspended() { kubectl --namespace flux-system get kustomization "$namespace" --output jsonpath='{.spec.suspend}'; }
writers_at_zero() {
  [ "$(kubectl --namespace "$namespace" get deployments --output jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' | grep -vc '^0$')" = 0 ]
}
load() {
  local status=0
  mise run db:load-dump --compare --files "$tree" "$namespace" "$dump" >"$output" 2>&1 || status=$?
  cat "$output"
  ! grep -qF "$marker" "$output" || fail "the load printed a file name or a row"
  return "$status"
}
loaded_equal() {
  [ "$(claim_digest)" = "$(tree_digest)" ] && [ "$(sql 'SELECT count(*) FROM load_marker')" = 1 ] &&
    [ "$(suspended)" = false ] && ! kubectl --namespace "$namespace" get pod db-load-files >/dev/null 2>&1
}
# kill_during <tool> <pattern> <background>: starts the load with a wrapper of the tool that, at the call matching the
# pattern, sets a flag and then waits for the kill, running the call beside it when background is true; kills the load's
# whole session once the flag stands.
kill_during() {
  local tool="$1" pattern="$2" background="$3" real
  real="$(mise which "$tool" 2>/dev/null || command -v "$tool")"
  cat >"$shim/$tool" <<'WRAPPER'
#!/usr/bin/env bash
case "$*" in *"$SHIM_PATTERN"*)
  [ "$SHIM_BACKGROUND" != true ] || "$SHIM_REAL" "$@" &
  : >"$SHIM_FLAG"
  sleep 600 ;;
esac
exec "$SHIM_REAL" "$@"
WRAPPER
  chmod +x "$shim/$tool"
  rm -f "$scratch/started"
  SHIM_REAL="$real" SHIM_PATTERN="$pattern" SHIM_BACKGROUND="$background" SHIM_FLAG="$scratch/started" \
    PATH="$shim:$PATH" MISE_DISABLE_TOOLS=kubectl setsid mise run db:load-dump --compare --files "$tree" "$namespace" "$dump" \
    >"$output" 2>&1 &
  loader_pid=$!
  until_true 300 "the load reached $pattern" test -e "$scratch/started"
  pkill -KILL --session "$loader_pid" || true
  wait "$loader_pid" 2>/dev/null || true
  loader_pid=
  rm -f "$shim/$tool"
}
# held_back: Flux is suspended and every writer is at 0.
held_back() { [ "$(suspended)" = true ] && writers_at_zero; }

before_tree="$(tree_listing)"
# The claim's old content: a file the source lacks, which --delete must remove.
on_claim 'mkdir -p /claim/old && echo old >/claim/old/extra.ogg'

load || fail "the fresh load exited non-zero"
loaded_equal || fail "after the fresh load the claim, the database or Flux differs from the source"
[ -z "$(on_claim 'find /claim ! -user '"$reading_uid"' ! -path /claim | head -n 1')" ] || fail "a file on the claim is not the reading uid's"
[ -z "$(on_claim 'find /claim -path "/claim/old*"')" ] || fail "the file the source lacks is still on the claim"
grep -qF '0 differing entries' "$output" || fail "the load did not report an equal checksum comparison"
[ "$(tree_listing)" = "$before_tree" ] || fail "the load changed the source tree"
load || fail "the repeated load exited non-zero"
loaded_equal || fail "after the repeated load the claim, the database or Flux differs from the source"
echo "a fresh and a repeated load made the claim and the database equal to the source and left the source unchanged"

# A kill during rsync: Flux suspended, writers at 0, --resume refuses, the same command converges.
kill_during rsync 'rsh_into_pod' false
held_back || fail "a kill during rsync left Flux resumed or a writer running"
if mise run db:load-dump --resume "$namespace" >"$output" 2>&1; then fail "--resume of a claim layer exited 0"; fi
grep -qF 'same command again' "$output" || fail "--resume did not name the re-run"
load || fail "the re-run after a kill during rsync exited non-zero"
loaded_equal || fail "the re-run after a kill during rsync did not converge"

# A kill during pg_restore.
kill_during kubectl 'pg_restore --clean' true
held_back || fail "a kill during pg_restore left Flux resumed or a writer running"
load || fail "the re-run after a kill during pg_restore exited non-zero"
loaded_equal || fail "the re-run after a kill during pg_restore did not converge"
echo "a kill during rsync and one during pg_restore left Flux suspended and the writers at 0, and the same command converged"
