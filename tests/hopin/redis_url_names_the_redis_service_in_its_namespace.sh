#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The applied Deployment's HOPIN_REDIS_URL must name the Service the Redis base renders in $APP_NAMESPACE.

url="$(kubectl --namespace "$APP_NAMESPACE" get deployment hopin \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="hopin")].env[?(@.name=="HOPIN_REDIS_URL")].value}')"
[ -n "$url" ] || fail "the Deployment hopin in $APP_NAMESPACE carries no HOPIN_REDIS_URL"
[[ "$url" =~ ^redis://([^:/]+):([0-9]+)/([0-9]+)$ ]] || fail "HOPIN_REDIS_URL is not redis://<host>:<port>/<database>"
host="${BASH_REMATCH[1]}"
port="${BASH_REMATCH[2]}"
service="${host%%.*}"
[ "$host" = "$service" ] || [ "$host" = "$service.$APP_NAMESPACE" ] || [ "$host" = "$service.$APP_NAMESPACE.svc" ] ||
  [ "$host" = "$service.$APP_NAMESPACE.svc.cluster.local" ] ||
  fail "HOPIN_REDIS_URL names the host $host, which is no Service of $APP_NAMESPACE"

service_ports="$(kubectl --namespace "$APP_NAMESPACE" get service "$service" -o jsonpath='{.spec.ports[*].port}')" ||
  fail "HOPIN_REDIS_URL names the Service $service, which $APP_NAMESPACE does not hold"
[[ " $service_ports " == *" $port "* ]] || fail "the Service $service in $APP_NAMESPACE has the ports $service_ports, not the $port of HOPIN_REDIS_URL"
backing_pods="$(kubectl --namespace "$APP_NAMESPACE" get endpoints "$service" \
  -o jsonpath='{.subsets[*].addresses[*].targetRef.name}')"
[ "$backing_pods" = "redis-0" ] ||
  fail "the Service $service named by HOPIN_REDIS_URL is backed by [$backing_pods], not by the Redis base's pod redis-0"
echo "HOPIN_REDIS_URL names the Service $service of $APP_NAMESPACE on its port $port, backed by the Redis pod"
