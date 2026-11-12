#!/usr/bin/env bash
# The web's route, as the layer applied it: a Pod beside cloudflared gets the web's health answer through Traefik for the
# host the readiness probe names, the Ingress holds exactly the two origins the web is configured with, and no Pod
# reaches the web's Service directly. It needs CLIENT_POD, CLIENT_IMAGE, TUNNEL_NAMESPACE and OTHER_NAMESPACE, a
# Namespace the cell creates and deletes.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
namespace=presentator
web=web
remove_objects() {
  local cell_status=$?
  delete_object delete namespace "$OTHER_NAMESPACE" --ignore-not-found --wait --timeout=2m
  end_deletions "$cell_status"
}
trap remove_objects EXIT

deployment="$(kubectl --namespace "$namespace" get deployment "$web" --output json)"
probe_path="$(yq '.spec.template.spec.containers[0].readinessProbe.httpGet.path' <<<"$deployment")"
probe_host="$(yq '.spec.template.spec.containers[0].readinessProbe.httpGet.httpHeaders[] | select(.name == "Host") | .value' <<<"$deployment")"
origin_hosts="$(yq '.spec.template.spec.containers[0].env[] | select(.name == "PRESENTATOR_PUBLIC_ORIGIN" or .name == "PRESENTATOR_TALK_ORIGIN") | .value | sub("^https://", "")' <<<"$deployment" | sort)"
ingress="$(kubectl --namespace "$namespace" get ingress "$web" --output json)"
ingress_hosts="$(yq '.spec.rules[].host' <<<"$ingress" | sort)"
[ "$(wc -l <<<"$origin_hosts")" = 2 ] && [ "$ingress_hosts" = "$origin_hosts" ] ||
  fail "the Ingress $namespace/$web routes '${ingress_hosts//$'\n'/ }', not the two origins '${origin_hosts//$'\n'/ }' the web is configured with"
echo "the Ingress routes exactly the hosts of the web's two origins: ${ingress_hosts//$'\n'/ }"
[[ $'\n'"$ingress_hosts"$'\n' == *$'\n'"$probe_host"$'\n'* ]] || fail "the readiness probe names the host $probe_host, which the Ingress does not route"

service_url="http://$web.$namespace.svc:$(yq '.spec.rules[0].http.paths[0].backend.service.port.number' <<<"$ingress")"
traefik_port="$(kubectl --namespace traefik get service traefik --output jsonpath='{.spec.ports[?(@.name=="web")].port}')"
request "$TUNNEL_NAMESPACE" web-health-through-traefik "$probe_host" "http://traefik.traefik.svc:$traefik_port$probe_path"
[ "$status" = 200 ] || fail "Traefik answered $status, not 200, to a Pod in $TUNNEL_NAMESPACE for $probe_host$probe_path, curl exit code $exit_code"
echo "Traefik routes $probe_host: a Pod in $TUNNEL_NAMESPACE got 200 for $probe_path"

kubectl create namespace "$OTHER_NAMESPACE"
for client_namespace in "$OTHER_NAMESPACE" "$TUNNEL_NAMESPACE"; do
  request "$client_namespace" web-direct-request "$probe_host" "$service_url$probe_path"
  # A refused connection (curl's 7) or no reply within the timeout (28) both leave the client without a status.
  [ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; } ||
    fail "a Pod in $client_namespace got the status $status from the Service $namespace/$web, curl exit code $exit_code"
  echo "a Pod in $client_namespace got no answer from the Service $namespace/$web (curl exit code $exit_code)"
done
