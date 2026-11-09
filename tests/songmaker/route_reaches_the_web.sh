#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"

cleanup() {
  kubectl --namespace "$SONGMAKER_NAMESPACE" delete pod worker-host-client unknown-host-client --ignore-not-found --wait --timeout=2m
  kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
}
trap cleanup EXIT
kubectl create namespace "$OTHER_NAMESPACE"

manifest=apps/songmaker/web.yaml
public_host="$(yq 'select(.kind == "Ingress") | .spec.rules[0].host' "$manifest")"
worker_host="$(yq 'select(.kind == "Service") | .metadata.name' "$manifest")"
web_port="$(kubectl --namespace traefik get service traefik -o jsonpath='{.spec.ports[?(@.name=="web")].port}')"
traefik_url="http://traefik.traefik.svc:${web_port}/health"
web_url="http://web.$SONGMAKER_NAMESPACE.svc.cluster.local:8080/health"

# The web's pod is Ready, so a 404 only means Traefik has not read the Ingress yet.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  request "$TUNNEL_NAMESPACE" "route-request-$attempt" "$public_host" "$traefik_url"
  [ "$status" = 404 ] || break
  sleep 3
done
[ "$status" = 200 ] || fail "a Pod in $TUNNEL_NAMESPACE got '$status' for /health through Traefik with the host $public_host, not 200"
echo "a Pod in $TUNNEL_NAMESPACE got 200 for /health through Traefik with the host $public_host"

request "$SONGMAKER_NAMESPACE" worker-host-client "$worker_host" "$web_url"
[ "$status" = 200 ] || fail "a Pod in $SONGMAKER_NAMESPACE got '$status' for /health with the host $worker_host, not 200"
request "$SONGMAKER_NAMESPACE" unknown-host-client "unknown.invalid" "$web_url"
[ "$status" = 400 ] || fail "a Pod in $SONGMAKER_NAMESPACE got '$status' for /health with a host off the list, not 400"
echo "the web answers 200 for the host $worker_host and 400 for a host off the list"

request "$OTHER_NAMESPACE" other-client "$public_host" "$web_url" --max-time 5 --retry 0
[ "$status" = 000 ] || fail "a Pod in $OTHER_NAMESPACE got '$status' from the web"
echo "a Pod in $OTHER_NAMESPACE gets no answer from the web"
