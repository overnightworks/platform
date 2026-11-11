#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
namespace="$KEYCLOAK_NAMESPACE"
kubectl -n "$namespace" wait --for=condition=Available --timeout=5m deployment/keycloak
kubectl -n "$namespace" wait job/config-cli --for=condition=Complete --timeout=10m
# shellcheck source=admin_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/admin_api.sh"

# Every client whose back-channel URL the realm file states, read from the running realm.
backchannel_attribute=backchannel.logout.url
client_ids="$(yq --output-format json '.clients' "$REALM_FILE" | jq --raw-output --arg key "$backchannel_attribute" \
  '.[] | select((.attributes[$key] // "") != "") | .clientId')"
[ -n "$client_ids" ] || fail "$REALM_FILE states no client's back-channel URL"

# The image has bash but no network client, so bash's /dev/tcp opens the connection from Keycloak's own container. The
# post is a form with a malformed logout_token, which the app refuses with 400 once the route and the Host are right; the
# probe prints "answered" and the status line, or "none" when no connection opens.
logout_post='body=logout_token=malformed
{
  printf "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" \
    "$3" "$4" "${#body}" "$body" >&3
  read -r -t 10 -u 3 status_line
  echo "answered $status_line"
} 2>/dev/null 3<>"/dev/tcp/$1/$2" || echo none'
# logout_status <host> <port> <path> <authority>: the status Keycloak's container gets for the post, or none.
logout_status() {
  local outcome code
  outcome="$(kubectl -n "$namespace" exec deployment/keycloak --container keycloak -- timeout 15 bash -c "$logout_post" \
    logout-post "$1" "$2" "$3" "$4")" || outcome=none
  read -r _ code _ <<<"${outcome#answered }"
  echo "${code:-none}"
}

read -r -a policy_manifests <<<"$POLICY_MANIFESTS"
counter=0
while IFS= read -r client_id; do
  url="$(admin GET "$realm/clients?clientId=$client_id" | jq --raw-output --arg key "$backchannel_attribute" \
    '.[0].attributes[$key] // empty')"
  [[ "$url" =~ ^http://([^/:]+):([0-9]+)(/.*)$ ]] ||
    fail "the back-channel URL of the client $client_id in the running realm is not http://<host>:<port>/<path>"
  host="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}" path="${BASH_REMATCH[3]}"
  authority="$host:$port"
  # The node may not have programmed the new policies yet, so only a missing connection is tried again; a status is final.
  answer=none
  for _ in 1 2 3 4 5 6; do
    answer="$(logout_status "$host" "$port" "$path" "$authority")"
    [ "$answer" = none ] || break
    sleep 5
  done
  [ "$answer" = 400 ] ||
    fail "Keycloak's container got '$answer', not 400, for a malformed logout token at $url of the client $client_id"
  echo "Keycloak's container gets 400 for a malformed logout token at $url with the host $authority"

  # A Pod beside Keycloak without its labels is no sender of that app: it gets no connection at all.
  counter=$((counter + 1))
  request "$namespace" "unlabelled-backchannel-$counter" "$authority" "http://$authority$path" \
    --request POST --data logout_token=malformed --max-time 5 --retry 0
  [ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; } ||
    fail "a Pod in $namespace without Keycloak's labels got the status $status, curl exit code $exit_code, from $url"
  echo "a Pod in $namespace without Keycloak's labels gets no answer from $url (curl exit code $exit_code)"

  # The three policies that open the path stand in the cluster: the app's ingress rule that admits Keycloak's labelled
  # pods and Keycloak's egress rule that names the app's namespace.
  app_namespace="$(cut -d. -f2 <<<"$host")"
  ingress_policy="$(APP_NAMESPACE="$app_namespace" yq 'select(.kind == "NetworkPolicy"
    and .metadata.namespace == strenv(APP_NAMESPACE)
    and .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == strenv(KEYCLOAK_NAMESPACE))
    | .metadata.name' "${policy_manifests[@]}")"
  egress_policy="$(APP_NAMESPACE="$app_namespace" yq 'select(.kind == "NetworkPolicy"
    and .spec.egress[].to[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == strenv(APP_NAMESPACE))
    | .metadata.name' "${policy_manifests[@]}")"
  [ -n "$ingress_policy" ] && [ -n "$egress_policy" ] ||
    fail "$POLICY_MANIFESTS hold no policy that admits Keycloak into $app_namespace or none that lets Keycloak send there"
  kubectl -n "$app_namespace" get networkpolicy "$ingress_policy" -o name
  kubectl -n "$namespace" get networkpolicy "$egress_policy" -o name
  echo "the NetworkPolicies $app_namespace/$ingress_policy and $namespace/$egress_policy open the path to $app_namespace"
done <<<"$client_ids"
