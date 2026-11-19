#!/usr/bin/env bash
# Proves docs/personal-data.md PD-8: who reaches Traefik, the apps behind it and speech-runtime.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
applied_revision="$(kubectl -n flux-system get kustomization traefik -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization traefik applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n traefik wait deployment/traefik --for=condition=Available --timeout=3m
echo "the Kustomization traefik applied the candidate, and the Deployment traefik is Available"

web_port="$(kubectl -n traefik get service traefik -o jsonpath='{.spec.ports[?(@.name=="web")].port}')"
traefik_url="http://traefik.traefik.svc:${web_port}"
# A refused connection (curl's 7) or no reply within the timeout (28) both leave the client without a status.
# assert_no_answer <namespace> <target>: the last request, from a Pod in the namespace, got no answer.
assert_no_answer() {
  [ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; } ||
    fail "a Pod in $1 got the status $status from $2, curl exit code $exit_code"
  echo "a Pod in $1 got no answer from $2 (curl exit code $exit_code)"
}

request "$TUNNEL_NAMESPACE" unrouted-request "$UNROUTED_HOST" "$traefik_url/"
[ "$status" = 404 ] || fail "Traefik answered $status, not 404, to a Pod in $TUNNEL_NAMESPACE for the unrouted host $UNROUTED_HOST"
echo "Traefik answered 404 to a Pod in $TUNNEL_NAMESPACE for the unrouted host $UNROUTED_HOST"

# Traefik refuses encoded path characters in each route's chain, so an unrouted host gets 404 for them: the
# encoded slash goes to a host an Ingress routes to a Service without endpoints, which Traefik answers with 503
# once it serves the route.
kubectl create namespace "$OTHER_NAMESPACE"
kubectl -n "$OTHER_NAMESPACE" create service clusterip no-endpoints --tcp=80:80
kubectl -n "$OTHER_NAMESPACE" create ingress encoded-path --rule="$ROUTED_HOST/*=no-endpoints:80"
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  request "$TUNNEL_NAMESPACE" "route-request-$attempt" "$ROUTED_HOST" "$traefik_url/"
  [ "$status" = 404 ] || break
done
[ "$status" = 503 ] || fail "Traefik answered $status, not 503, for $ROUTED_HOST, routed to a Service without endpoints"
echo "Traefik serves the route of $ROUTED_HOST and answers its Service without endpoints with 503"
request "$TUNNEL_NAMESPACE" encoded-slash-request "$ROUTED_HOST" "$traefik_url/a%2Fb"
[ "$status" = 400 ] || fail "Traefik answered $status, not 400, to a Pod in $TUNNEL_NAMESPACE for $ROUTED_HOST/a%2Fb"
echo "Traefik answered 400 to a Pod in $TUNNEL_NAMESPACE for $ROUTED_HOST/a%2Fb"

request "$OTHER_NAMESPACE" denied-request "$ROUTED_HOST" "$traefik_url/"
assert_no_answer "$OTHER_NAMESPACE" "Traefik's web port"

# Traefik's own port answers its readiness probe from the node, yet gives a Pod beside cloudflared no answer.
traefik="$(kubectl -n traefik get deployment traefik -o json)"
traefik_selector="$(yq '.spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | join(",")' \
  <<<"$traefik")"
read -r probe_path probe_port < <(yq \
  '.spec.template.spec.containers[0].readinessProbe.httpGet | .path + " " + (.port | tostring)' <<<"$traefik")
traefik_pod_ip="$(kubectl -n traefik get pods -l "$traefik_selector" -o jsonpath='{.items[0].status.podIP}')"
request "$TUNNEL_NAMESPACE" probe-port-request "$UNROUTED_HOST" "http://${traefik_pod_ip}:${probe_port}${probe_path}"
assert_no_answer "$TUNNEL_NAMESPACE" "Traefik's probe port $probe_port"

# The app's Ingress sends its host to the app's Service, whose pods only Traefik's reach.
# routed_app_answers_only_traefik <manifest>: the app of the manifest is routed and closed to every other Pod.
routed_app_answers_only_traefik() {
  local manifest="$1" ingress app_namespace route app_host app_service app_port app_deployment app health_path namespace
  ingress="$(yq 'select(.kind == "Ingress") | .metadata.namespace + "/" + .metadata.name' "$manifest")"
  app_namespace="${ingress%/*}"
  route='{.spec.rules[0].host} {.spec.rules[0].http.paths[0].backend.service.name}'
  route+=' {.spec.rules[0].http.paths[0].backend.service.port.number}{"\n"}'
  read -r app_host app_service app_port < <(kubectl -n "$app_namespace" get ingress "${ingress#*/}" -o jsonpath="$route")
  app_deployment="$(yq 'select(.kind == "Deployment") | .metadata.name' "$manifest")"
  app="$(kubectl -n "$app_namespace" get deployment "$app_deployment" -o json)"
  health_path="$(yq '.spec.template.spec.containers[0].readinessProbe.httpGet.path' <<<"$app")"
  request "$TUNNEL_NAMESPACE" app-health-request "$app_host" "$traefik_url$health_path"
  [ "$status" = 200 ] || fail "Traefik answered $status, not 200, to a Pod in $TUNNEL_NAMESPACE for $app_host$health_path"
  echo "Traefik routes $app_host: a Pod in $TUNNEL_NAMESPACE got 200 for $health_path"
  for namespace in "$OTHER_NAMESPACE" "$TUNNEL_NAMESPACE"; do
    request "$namespace" app-denied-request "$app_host" "http://$app_service.$app_namespace.svc:$app_port$health_path"
    assert_no_answer "$namespace" "the Service $app_namespace/$app_service"
  done
}
routed_app_answers_only_traefik "$ROUTED_APP_MANIFEST"
routed_app_answers_only_traefik "$ROUTED_APP_2_MANIFEST"

# speech-runtime's NetworkPolicy admits its callers' namespaces on the Service's port, and no other.
speech_port="$(kubectl -n "$SPEECH_NAMESPACE" get service "$SPEECH_SERVICE" -o jsonpath='{.spec.ports[0].port}')"
speech_callers="$(kubectl -n "$SPEECH_NAMESPACE" get networkpolicy "$SPEECH_SERVICE" \
  -o jsonpath='{.spec.ingress[*].from[*].namespaceSelector.matchExpressions[*].values[*]}')"
[[ " $speech_callers " == *" $SPEECH_CALLER_NAMESPACE "* ]] ||
  fail "the NetworkPolicy $SPEECH_SERVICE admits '$speech_callers', not $SPEECH_CALLER_NAMESPACE"
speech_url="http://${SPEECH_SERVICE}.${SPEECH_NAMESPACE}.svc:${speech_port}/health"
request "$SPEECH_CALLER_NAMESPACE" speech-caller-request "$SPEECH_SERVICE" "$speech_url"
[ "$status" = 200 ] ||
  fail "$SPEECH_SERVICE answered $status, not 200, to a Pod in $SPEECH_CALLER_NAMESPACE, curl exit code $exit_code"
echo "$SPEECH_SERVICE answered 200 to a Pod in $SPEECH_CALLER_NAMESPACE"
request "$OTHER_NAMESPACE" speech-denied-request "$SPEECH_SERVICE" "$speech_url"
assert_no_answer "$OTHER_NAMESPACE" "$SPEECH_SERVICE"

kubectl delete namespace "$OTHER_NAMESPACE" --wait --timeout=2m
[ -z "$(kubectl get namespace "$OTHER_NAMESPACE" --ignore-not-found -o name)" ] ||
  fail "the namespace $OTHER_NAMESPACE outlived its deletion"
echo "the namespace $OTHER_NAMESPACE is gone"

# The app trusts the forwarded addresses of every Traefik pod, so its sign-in budget counts the address the
# client named: one more start than the budget from one address gets 429, and one from another does not.
# sign_in_budget_follows_the_named_address <manifest> <trusted proxies setting> <sign-in start path> <budget>
sign_in_budget_follows_the_named_address() {
  local manifest="$1" proxies_setting="$2" sign_in_path="$3" sign_in_budget="$4"
  local app_host app trusted_proxies traefik_pod_ips starts admitted
  app_host="$(yq 'select(.kind == "Ingress") | .spec.rules[0].host' "$manifest")"
  app="$(kubectl -n "$(yq 'select(.kind == "Ingress") | .metadata.namespace' "$manifest")" get deployment \
    "$(yq 'select(.kind == "Deployment") | .metadata.name' "$manifest")" -o json)"
  trusted_proxies="$(PROXIES_SETTING="$proxies_setting" yq \
    '.spec.template.spec.containers[0].env[] | select(.name == strenv(PROXIES_SETTING)) | .value' <<<"$app")"
  traefik_pod_ips="$(kubectl -n traefik get pods -l "$traefik_selector" -o jsonpath='{range .items[*]}{range .status.podIPs[*]}{.ip}{" "}{end}{end}')"
  python3 -I -c '
import ipaddress, sys
trusted = [ipaddress.ip_network(entry.strip()) for entry in sys.argv[1].split(",") if entry.strip()]
addresses = [ipaddress.ip_address(address) for address in sys.argv[2].split()]
sys.exit(not trusted or not addresses or
         not all(any(address in network for network in trusted) for address in addresses))
' "$trusted_proxies" "$traefik_pod_ips" ||
    fail "$proxies_setting '$trusted_proxies' does not hold every Traefik pod's address '$traefik_pod_ips'"
  echo "$proxies_setting $trusted_proxies holds every Traefik pod's address: $traefik_pod_ips"
  starts=$((sign_in_budget + 1))
  request "$TUNNEL_NAMESPACE" sign-in-requests "$app_host" "$traefik_url$sign_in_path?attempt=[1-$starts]" \
    --header "X-Forwarded-For: $FIRST_CLIENT_ADDRESS"
  mapfile -t statuses < <(grep -o '[0-9][0-9][0-9]' <<<"$status")
  admitted="$(printf '%s\n' "${statuses[@]:0:sign_in_budget}" | grep -cvxE '000|429' || true)"
  [ "${#statuses[@]}" = "$starts" ] && [ "$admitted" = "$sign_in_budget" ] && [ "${statuses[-1]}" = 429 ] ||
    fail "$app_host answered '${statuses[*]}' to $starts sign-in starts from $FIRST_CLIENT_ADDRESS, not $sign_in_budget without 429, then 429"
  echo "$app_host admitted $sign_in_budget sign-in starts from $FIRST_CLIENT_ADDRESS and answered the next with 429"
  request "$TUNNEL_NAMESPACE" other-sign-in-request "$app_host" "$traefik_url$sign_in_path" \
    --header "X-Forwarded-For: $SECOND_CLIENT_ADDRESS"
  [ "$status" != 429 ] && [ "$status" != 000 ] ||
    fail "$app_host answered $status to a sign-in start from $SECOND_CLIENT_ADDRESS after the budget of $FIRST_CLIENT_ADDRESS"
  echo "$app_host answered $status to a sign-in start from $SECOND_CLIENT_ADDRESS"
}
sign_in_budget_follows_the_named_address "$ROUTED_APP_MANIFEST" "$TRUSTED_PROXIES_SETTING" "$SIGN_IN_PATH" "$SIGN_IN_BUDGET"
sign_in_budget_follows_the_named_address "$ROUTED_APP_2_MANIFEST" "$ROUTED_APP_2_TRUSTED_PROXIES_SETTING" \
  "$ROUTED_APP_2_SIGN_IN_PATH" "$ROUTED_APP_2_SIGN_IN_BUDGET"
