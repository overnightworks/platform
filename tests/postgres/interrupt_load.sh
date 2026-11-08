#!/usr/bin/env bash
# interrupt_load.sh <namespace> <dump> <INT|KILL>, from a platform checkout: interrupts mise run db:load-dump while its
# pg_restore blocks inside its transaction, asserts the recovery the signal leaves, then asserts that a second load
# verifies equal. It prints names, counts and outcomes, never a row.
# pg_restore reads a custom archive's whole table of contents before it opens its transaction, and the TOC can fill most
# of the file, so the script feeds all of the dump but its last byte. That byte is the end of the last data block, the
# zero-length chunk (a sign byte and the int's bytes) that closes every block: pg_restore waits for it inside its
# transaction, as an idle session or in COPY, whatever the dump holds.
set -euo pipefail
namespace="$1" dump="$2" signal="$3"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
fail() { echo "interrupt_load: $1" >&2; exit 1; }
kubectl() { mise exec -- kubectl "$@"; }
load() { mise run db:load-dump "$@"; }
# The name leads, so a read that printed nothing is not taken for a Kustomization that is not suspended.
suspended() { kubectl --namespace flux-system get kustomization "$namespace" -o jsonpath='{.metadata.name}:{.spec.suspend}'; }
# Sessions of the database inside a transaction that wait for their client, as a pg_restore without input does.
blocked_sessions() {
  kubectl --namespace "$namespace" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only --no-align \
    --command="SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()
      AND xact_start IS NOT NULL AND wait_event = 'ClientRead'"
}
# The writers the loader stops and Flux restores: "<name>=<replicas>" per Deployment, and the Jobs Flux applied.
replicas() {
  kubectl --namespace "$namespace" get deployments -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}'
}
flux_jobs() {
  kubectl --namespace "$namespace" get jobs --selector "kustomize.toolkit.fluxcd.io/name=$namespace" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}
# A positive count; a failed read counts as none, so an unread session is never one that blocks.
blocked_count() { blocked_sessions 2>/dev/null || true; }
blocks_inside_transaction() { [[ "$(blocked_count)" =~ ^[1-9][0-9]*$ ]]; }
case "$signal" in INT | KILL) ;; *) fail "the signal is INT or KILL, not $signal" ;; esac
[ -f "$dump" ] || fail "$dump is no file"
withheld_bytes=1
dump_size="$(stat -c %s "$dump")"
[ "$dump_size" -gt "$withheld_bytes" ] || fail "$dump is not larger than the $withheld_bytes byte it withholds"

# The loader's session ended: no process of it remains, a resume that outlives mise included.
session_ended() {
  for _ in $(seq 600); do [ -n "$(pgrep --session "$loader")" ] || return 0; sleep 1; done
  return 1
}
# On every exit the writer and the loader's session end before the FIFO goes: a loader that refused at once leaves a
# writer blocked on a full FIFO nobody reads.
loader="" writer=""
cleanup() {
  exec 3>&-
  [ -z "$writer" ] || { kill "$writer" 2>/dev/null || true; wait "$writer" 2>/dev/null || true; }
  if [ -n "$loader" ]; then
    pkill -TERM --session "$loader" 2>/dev/null || true
    session_ended || pkill -KILL --session "$loader" 2>/dev/null || true
    wait "$loader" 2>/dev/null || true
  fi
  rm -rf "$fifo_dir"
}
replicas_before="$(replicas)" || fail "cannot read the Deployments of $namespace"
jobs_before="$(flux_jobs)" || fail "cannot read the Jobs of $namespace"
fifo_dir="$(mktemp -d)"
trap cleanup EXIT
mkfifo -m 0600 "$fifo_dir/dump"
# Held open read-write, so pg_restore never reads the end of its input and can never commit.
exec 3<>"$fifo_dir/dump"
# Its own session, so the signal reaches every process of the loader, whatever process group mise gives its task.
setsid mise run db:load-dump "$namespace" "$fifo_dir/dump" 3>&- &
loader=$!
head -c "$((dump_size - withheld_bytes))" "$dump" >&3 &
writer=$!

for _ in $(seq 300); do
  kill -0 "$loader" 2>/dev/null || fail "the loader exited before its pg_restore blocked inside its transaction"
  ! blocks_inside_transaction || break
  sleep 1
done
blocks_inside_transaction || fail "no pg_restore blocked inside its transaction within 300 seconds"
running="$(replicas)" || fail "cannot read the Deployments of $namespace"
existing_jobs="$(flux_jobs)" || fail "cannot read the Jobs of $namespace"
[ -z "$(grep -v '=0$' <<<"$running" || true)" ] && [ -z "$existing_jobs" ] ||
  fail "a Deployment runs or a Flux Job exists while pg_restore blocks inside its transaction"
echo "interrupt_load: pg_restore blocks inside its transaction; sending $signal to every process of the loader"
# Their process groups decide which of them a terminal's signal would reach.
ps -o pid=,pgid=,comm= --sid "$loader"
pkill "-$signal" --session "$loader"
kill "$writer" 2>/dev/null || true
exec 3>&-
loader_status=0
wait "$loader" || loader_status=$?
[ "$loader_status" != 0 ] || fail "the interrupted loader exited 0"
# The trap's resume may outlive mise, which leads the session.
session_ended || fail "a process of the loader still runs 600 seconds after $signal"
[ "$(stat -c %a "$fifo_dir")" = 700 ] && [ "$(stat -c %a "$fifo_dir/dump.load.log")" = 600 ] ||
  fail "$fifo_dir is not at 0700 or its load log not at 0600"

if [ "$signal" = KILL ]; then
  [ "$(suspended)" = "$namespace:true" ] || fail "the Kustomization $namespace is not suspended after the killed load"
  refusal="$(load "$namespace" "$dump" 2>&1)" && fail "a new load ran while the Kustomization was suspended"
  [[ $refusal == *"--resume $namespace"* ]] || fail "the refused load does not name --resume"
  echo "interrupt_load: a new load refuses and names --resume"
  load --resume "$namespace"
  [ "$(blocked_sessions)" = 0 ] || fail "--resume returned while a session still blocks inside its transaction"
fi
state="$(suspended)" || fail "cannot read whether the Kustomization $namespace is suspended"
[[ $state == "$namespace:"* ]] || fail "the suspension of the Kustomization $namespace read as '$state'"
[ "$state" != "$namespace:true" ] || fail "the Kustomization $namespace is still suspended"
replicas_after="$(replicas)" || fail "cannot read the Deployments of $namespace"
[ "$replicas_after" = "$replicas_before" ] || fail "the Deployments of $namespace do not run at the replicas they had before"
for deployment in $(kubectl --namespace "$namespace" get deployments -o name); do
  kubectl --namespace "$namespace" rollout status "$deployment" --timeout=5m
done
jobs="$(flux_jobs)"
[ "$jobs" = "$jobs_before" ] || fail "the Flux Jobs of $namespace are not those before the load"
[ -z "$jobs" ] || kubectl --namespace "$namespace" wait job --selector "kustomize.toolkit.fluxcd.io/name=$namespace" \
  --for=condition=Complete --timeout=5m
echo "interrupt_load: $signal recovered: the Kustomization $namespace runs and its Deployments are back"
load --compare "$namespace" "$dump"
echo "interrupt_load: the second load verified equal"
