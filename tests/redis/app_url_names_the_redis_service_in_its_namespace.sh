#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The applied Deployment $APP_DEPLOYMENT's container $APP_CONTAINER must carry $REDIS_URL_VARIABLE, which must name the Service the Redis base renders in $APP_NAMESPACE.

url="$(kubectl --namespace "$APP_NAMESPACE" get deployment "$APP_DEPLOYMENT" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$APP_CONTAINER\")].env[?(@.name==\"$REDIS_URL_VARIABLE\")].value}")"
[ -n "$url" ] || fail "the Deployment $APP_DEPLOYMENT in $APP_NAMESPACE carries no $REDIS_URL_VARIABLE"
[[ "$url" =~ ^redis://([^:/]+):([0-9]+)/([0-9]+)$ ]] || fail "$REDIS_URL_VARIABLE is not redis://<host>:<port>/<database>"
host="${BASH_REMATCH[1]}"
port="${BASH_REMATCH[2]}"
service="${host%%.*}"
[ "$host" = "$service" ] || [ "$host" = "$service.$APP_NAMESPACE" ] || [ "$host" = "$service.$APP_NAMESPACE.svc" ] ||
  [ "$host" = "$service.$APP_NAMESPACE.svc.cluster.local" ] ||
  fail "$REDIS_URL_VARIABLE names the host $host, which is no Service of $APP_NAMESPACE"

service_ports="$(kubectl --namespace "$APP_NAMESPACE" get service "$service" -o jsonpath='{.spec.ports[*].port}')" ||
  fail "$REDIS_URL_VARIABLE names the Service $service, which $APP_NAMESPACE does not hold"
[[ " $service_ports " == *" $port "* ]] || fail "the Service $service in $APP_NAMESPACE has the ports $service_ports, not the $port of $REDIS_URL_VARIABLE"
# The endpoints controller publishes a restarted pod's address after it is Ready, so the read waits at most 60 s.
backing_pods=""
for _ in $(seq 1 30); do
  backing_pods="$(kubectl --namespace "$APP_NAMESPACE" get endpointslices.discovery.k8s.io \
    --selector "kubernetes.io/service-name=$service" \
    -o jsonpath='{.items[*].endpoints[*].targetRef.name}')"
  [ "$backing_pods" = "redis-0" ] && break
  sleep 2
done
[ "$backing_pods" = "redis-0" ] ||
  fail "the Service $service named by $REDIS_URL_VARIABLE is backed by [$backing_pods], not by the Redis base's pod redis-0"
echo "$REDIS_URL_VARIABLE names the Service $service of $APP_NAMESPACE on its port $port, backed by the Redis pod"
