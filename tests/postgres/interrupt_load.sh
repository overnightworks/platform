#!/usr/bin/env bash
# interrupt_load.sh <namespace> <dump> <INT|KILL>, from a platform checkout: interrupts mise run db:load-dump while its
# pg_restore blocks inside its transaction on half the dump, asserts the recovery the signal leaves, then asserts that a
# second load verifies equal. It prints names, counts and outcomes, never a row.
set -euo pipefail
namespace="$1" dump="$2" signal="$3"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
fail() { echo "interrupt_load: $1" >&2; exit 1; }
kubectl() { mise exec -- kubectl "$@"; }
load() { mise run db:load-dump "$@"; }
suspended() { kubectl --namespace flux-system get kustomization "$namespace" -o jsonpath='{.spec.suspend}'; }
# Sessions of the database inside a transaction that wait for their client, as a pg_restore without input does.
blocked_sessions() {
  kubectl --namespace "$namespace" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only --no-align \
    --command="SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()
      AND xact_start IS NOT NULL AND wait_event = 'ClientRead'"
}
case "$signal" in INT | KILL) ;; *) fail "the signal is INT or KILL, not $signal" ;; esac
[ -f "$dump" ] || fail "$dump is no file"

fifo_dir="$(mktemp -d)"
trap 'exec 3>&-; rm -rf "$fifo_dir"' EXIT
mkfifo -m 0600 "$fifo_dir/dump"
# Held open read-write, so pg_restore never reads the end of its input and can never commit.
exec 3<>"$fifo_dir/dump"
set -m
load "$namespace" "$fifo_dir/dump" 3>&- &
loader=$!
set +m
head -c "$(($(stat -c %s "$dump") / 2))" "$dump" >&3 &
writer=$!

for _ in $(seq 300); do
  kill -0 "$loader" 2>/dev/null || fail "the loader exited before its pg_restore blocked inside its transaction"
  [ "$(blocked_sessions)" = 0 ] || break
  sleep 1
done
[ "$(blocked_sessions)" != 0 ] || fail "no pg_restore blocked inside its transaction within 300 seconds"
echo "interrupt_load: pg_restore blocks inside its transaction; sending $signal to the loader's process group"
kill "-$signal" -- "-$loader"
kill "$writer" 2>/dev/null || true
exec 3>&-
loader_status=0
wait "$loader" || loader_status=$?
[ "$loader_status" != 0 ] || fail "the interrupted loader exited 0"
[ "$(stat -c %a "$fifo_dir")" = 700 ] && [ "$(stat -c %a "$fifo_dir/dump.load.log")" = 600 ] ||
  fail "$fifo_dir is not at 0700 or its load log not at 0600"

if [ "$signal" = KILL ]; then
  [ "$(suspended)" = true ] || fail "the Kustomization $namespace is not suspended after the killed load"
  refusal="$(load "$namespace" "$dump" 2>&1)" && fail "a new load ran while the Kustomization was suspended"
  [[ $refusal == *"--resume $namespace"* ]] || fail "the refused load does not name --resume"
  echo "interrupt_load: a new load refuses and names --resume"
  load --resume "$namespace"
  [ "$(blocked_sessions)" = 0 ] || fail "--resume returned while a session still blocks inside its transaction"
fi
[ "$(suspended)" != true ] || fail "the Kustomization $namespace is still suspended"
for deployment in $(kubectl --namespace "$namespace" get deployments -o name); do
  kubectl --namespace "$namespace" rollout status "$deployment" --timeout=5m
done
echo "interrupt_load: $signal recovered: the Kustomization $namespace runs and its Deployments are back"
load --compare "$namespace" "$dump"
echo "interrupt_load: the second load verified equal"
