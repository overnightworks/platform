#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# presentator's Postgres in the layer as Flux applied it: Ready, its Service and its Pod accepting a TCP connection on
# the Postgres port from the web's container, and neither accepting one from the sealed build worker's container, whose
# pod holds lo alone. The web's connection is the positive control for the worker's refusal; names and verdicts only.
export KUBECONFIG="$HOME/.kube/config"
namespace=presentator

kubectl --namespace "$namespace" wait pod/postgres-0 --for=condition=Ready --timeout=5m
kubectl --namespace "$namespace" exec postgres-0 --container postgres -- pg_isready --username="$namespace" --dbname="$namespace"
service_address="$(kubectl --namespace "$namespace" get service postgres --output jsonpath='{.spec.clusterIP}')"
service_port="$(kubectl --namespace "$namespace" get service postgres --output jsonpath='{.spec.ports[?(@.name=="postgres")].port}')"
pod_address="$(kubectl --namespace "$namespace" get pod postgres-0 --output jsonpath='{.status.podIP}')"
[ -n "$service_address" ] && [ -n "$service_port" ] && [ -n "$pod_address" ] ||
  fail "the Service postgres or the Pod postgres-0 of $namespace names no address or no port"

# Addresses, not names: the worker has no resolver to reach, and a name would fail for that and not for the route.
read -r -d '' connect_script <<'PYTHON' || true
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5).close()
except OSError as error:
    print(f"no connection: {type(error).__name__}")
    sys.exit(1)
print("connected")
PYTHON

kubectl --namespace "$namespace" wait pod/build-worker-0 --for=condition=Ready --timeout=5m
for address in "$service_address" "$pod_address"; do
  web_answer="$(kubectl --namespace "$namespace" exec deployment/web --container web -- python3 -I -c "$connect_script" "$address" "$service_port" 2>&1)" ||
    fail "the web did not connect to Postgres at $address:$service_port: $web_answer"
  echo "the web connects to Postgres at $address:$service_port"
  worker_status=0
  worker_answer="$(kubectl --namespace "$namespace" exec build-worker-0 --container worker -- python3 -I -c "$connect_script" "$address" "$service_port" 2>&1)" ||
    worker_status=$?
  [ "$worker_status" != 0 ] || fail "the sealed worker connected to Postgres at $address:$service_port: $worker_answer"
  [[ $worker_answer == "no connection: "* ]] ||
    fail "the sealed worker's attempt at $address:$service_port ended $worker_status without the script's own verdict: $worker_answer"
  echo "the sealed worker cannot connect to Postgres at $address:$service_port: $worker_answer"
done
