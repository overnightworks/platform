#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"

cleanup() {
  kubectl --namespace "$SONGMAKER_NAMESPACE" delete pod worker-host-client unknown-host-client backchannel-control \
    --ignore-not-found --wait --timeout=2m
  kubectl --namespace "$TUNNEL_NAMESPACE" delete pod backchannel-through-traefik --ignore-not-found --wait --timeout=2m
  kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
}
trap cleanup EXIT
kubectl create namespace "$OTHER_NAMESPACE"

manifest=apps/songmaker/web.yaml
public_host="$(yq 'select(.kind == "Ingress") | .spec.rules[0].host' "$manifest")"
worker_host="$(yq 'select(.kind == "Service") | .metadata.name' "$manifest")"
web_port="$(kubectl --namespace traefik get service traefik -o jsonpath='{.spec.ports[?(@.name=="web")].port}')"
traefik_origin="http://traefik.traefik.svc:${web_port}"
traefik_url="$traefik_origin/health"
web_service_port="$(yq 'select(.kind == "Service") | .spec.ports[0].port' "$manifest")"
service_host="$worker_host.$SONGMAKER_NAMESPACE.svc:$web_service_port"
backchannel_path=/auth/backchannel-logout
# The status of noop@internal, which answers the router that refuses the back-channel route.
refusal_status=418
backchannel_url="http://$worker_host.$SONGMAKER_NAMESPACE.svc.cluster.local:${web_service_port}$backchannel_path"
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

# post_malformed_token <namespace> <name> <host> <url> [<curl argument>...]: a POST of a malformed logout_token, so 400 means
# the route was reached and the token refused; sets answer_status and answer_body from the response.
# shellcheck disable=SC2034 # the answers are what the sourcing cells below read.
post_malformed_token() {
  local response
  request_body "$@" --request POST --data logout_token=malformed --include
  [ "$exit_code" = 0 ] || fail "the request of $2 in $1 ended with curl's exit code $exit_code"
  response="$(tr -d '\r' <<<"$status")"
  answer_status="$(awk 'NR == 1 { print $2 }' <<<"$response")"
  answer_body="$(sed '1,/^$/d' <<<"$response")"
}

# expect_answer <namespace> <name> <host> <url> <status> <body> <curl argument>...: the answer has the status, and the body
# "empty" (none) or "any". A Pod in the tunnel's namespace sends through Traefik.
expect_answer() {
  local namespace="$1" name="$2" host="$3" url="$4" expected_status="$5" expected_body="$6"
  shift 6
  post_malformed_token "$namespace" "$name" "$host" "$url" "$@"
  [ "$answer_status" = "$expected_status" ] ||
    fail "a Pod in $namespace got '$answer_status' for the logout with the host $host at $url, not $expected_status"
  case "$expected_body" in
    empty) [ -z "$answer_body" ] || fail "the answer to $name carried a body, so it is not an empty $expected_status" ;;
    any) ;;
  esac
  echo "a Pod in $namespace got $answer_status with a $expected_body body for the logout with the host $host at $url"
}

expect_answer "$SONGMAKER_NAMESPACE" backchannel-control "$service_host" "$backchannel_url" 400 any

# Through Traefik no request reaches the route: its router names no host, so the public Host gets the status of
# Traefik's refusal, which carries no body.
expect_answer "$TUNNEL_NAMESPACE" backchannel-through-traefik "$public_host" "$traefik_origin$backchannel_path" "$refusal_status" empty

request "$OTHER_NAMESPACE" other-client "$public_host" "$web_url" --max-time 5 --retry 0
[ "$status" = 000 ] || fail "a Pod in $OTHER_NAMESPACE got '$status' from the web"
echo "a Pod in $OTHER_NAMESPACE gets no answer from the web"
