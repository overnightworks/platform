#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# presentator's build workers in the layer as Flux applied it, with a release that serves them: both pods of the
# StatefulSet Ready and endpoints of the Service build-worker, the key file of each root's at mode 0400 and the same file as
# the web's, the web connecting to the Service by its name, and a pod without the web's labels getting no connection to a
# worker. A plain connection spends no life, so the cell leaves the workers as it found them. The key is hashed, never
# printed; names and verdicts only. It needs PROBE_IMAGE, and creates and deletes one Pod in the Namespace presentator.
export KUBECONFIG="$HOME/.kube/config"
namespace=presentator
service=build-worker
outsider=build-worker-outsider
k() { kubectl --namespace "$namespace" "$@"; }
remove_objects() {
  local cell_status=$?
  delete_object --namespace "$namespace" delete pod "$outsider" --ignore-not-found --wait --timeout=2m
  end_deletions "$cell_status"
}
trap remove_objects EXIT

replicas="$(k get statefulset "$service" --output jsonpath='{.spec.replicas}')"
[ "$replicas" -ge 2 ] || fail "the StatefulSet $service runs '$replicas' replicas, not at least two"
for ordinal in $(seq 0 $((replicas - 1))); do
  k wait "pod/$service-$ordinal" --for=condition=Ready --timeout=5m
done
ready_addresses="$(k get endpointslices --selector "kubernetes.io/service-name=$service" \
  --output jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{"\n"}{end}' | sort)"
[ "$(grep -c . <<<"$ready_addresses")" = "$replicas" ] ||
  fail "the Service $service has '$(tr '\n' ' ' <<<"$ready_addresses")' ready endpoints, not $replicas"
service_port="$(k get service "$service" --output jsonpath='{.spec.ports[?(@.name=="build")].port}')"
[ -n "$service_port" ] || fail "the Service $service holds no port build"
echo "the Service $service has $replicas ready endpoints, one for each worker pod"

# The key file: the worker's command names it, and the web reads the same path.
key_file="$(k get statefulset "$service" --output jsonpath='{.spec.template.spec.containers[0].command}' | sed -n 's/.*"--key-file","\([^"]*\)".*/\1/p')"
web_key_file="$(k get deployment web --output jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PRESENTATOR_BUILD_WORKER_KEY_FILE")].value}')"
[ -n "$key_file" ] && [ "$key_file" = "$web_key_file" ] || fail "the worker's key file '$key_file' is not the web's '$web_key_file'"
web_hash="$(k exec deployment/web --container web -- sha256sum "$key_file")" || fail "the web cannot read the key file"
for ordinal in $(seq 0 $((replicas - 1))); do
  mode_and_owner="$(k exec "$service-$ordinal" --container worker -- stat -L -c '%a %u' "$key_file")" ||
    fail "the stat of the key file in $service-$ordinal failed"
  [ "$mode_and_owner" = '400 0' ] || fail "the key file in $service-$ordinal is '$mode_and_owner', not mode 400 and owner 0"
  worker_hash="$(k exec "$service-$ordinal" --container worker -- sha256sum "$key_file")" || fail "root cannot read the key file in $service-$ordinal"
  [ "$worker_hash" = "$web_hash" ] || fail "the key file in $service-$ordinal differs from the web's"
done
echo "the key file is mode 400 and root's in each worker pod and the web reads the same file"

# The addresses, not names, for the pods; the web dials the Service by its name, as presentator does.
read -r -d '' connect_script <<'PYTHON' || true
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5).close()
except OSError as error:
    print(f"no connection: {type(error).__name__}")
    sys.exit(1)
print("connected")
PYTHON
web_answer="$(k exec deployment/web --container web -- python3 -I -c "$connect_script" "$service" "$service_port" 2>&1)" ||
  fail "the web did not connect to $service:$service_port: $web_answer"
echo "the web connects to $service:$service_port"

# The outsider has no label of the web's: its connection to a worker's port gets no answer, where the web's was made.
worker_address="$(head -n 1 <<<"$ready_addresses")"
k run "$outsider" --image "$PROBE_IMAGE" --restart Never --command -- sleep 600
k wait "pod/$outsider" --for=condition=Ready --timeout=2m
# A refusal is nc's own failure status: an exec that did not run, or a missing nc (126, 127), is no refusal.
refused() {
  local reply refusal_status
  reply="$(k exec "$outsider" -- sh -c "nc -w 3 '$worker_address' '$service_port' </dev/null >/dev/null 2>&1; echo status=\$?")" || return 1
  refusal_status="${reply##*status=}"
  [[ $refusal_status =~ ^[0-9]+$ ]] && [ "$refusal_status" -ne 0 ] && [ "$refusal_status" -lt 126 ]
}
until_true 60 "the connection of a Pod without the web's labels to the worker $worker_address:$service_port is refused" refused
web_direct="$(k exec deployment/web --container web -- python3 -I -c "$connect_script" "$worker_address" "$service_port" 2>&1)" ||
  fail "the web did not connect to the worker pod $worker_address:$service_port: $web_direct"
echo "a Pod without the web's labels gets no connection to the worker pod $worker_address:$service_port, which the web makes"
