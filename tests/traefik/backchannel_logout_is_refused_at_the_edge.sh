#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"

web_port="$(kubectl --namespace traefik get service traefik -o jsonpath='{.spec.ports[?(@.name=="web")].port}')"
traefik_origin="http://traefik.traefik.svc:${web_port}"
backchannel_path=/auth/backchannel-logout

# The paths that name the back-channel route once Traefik has cleaned and decoded them, and the ones the entrypoint
# refuses because they carry an encoded slash or backslash.
refused_paths=("$backchannel_path" "$backchannel_path/" "$backchannel_path?logout_token=x" "$backchannel_path/?logout_token=x"
  /AUTH/Backchannel-Logout "/$backchannel_path" /auth//backchannel-logout /x/../auth/backchannel-logout
  /./auth/backchannel-logout /%61uth/backchannel-logout)
encoded_paths=(/auth%2Fbackchannel-logout /auth%2fbackchannel-logout "$backchannel_path%2F" /auth%5Cbackchannel-logout)
# The neighbours the rule must leave to the app, so a rule that matches by prefix turns red.
neighbour_paths=("$backchannel_path-x" "$backchannel_path/x")
# What Traefik's own router answers: the status of noop@internal and no body.
refusal="418 0"

mapfile -t routed_hosts < <(kubectl get ingresses -A \
  -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' | sort -u | grep -v '^$' || true)
[ "${#routed_hosts[@]}" -gt 0 ] || fail "no Ingress routes a host"
echo "the Ingresses route ${routed_hosts[*]}"

# ask <name> <host> <method> <path>...: a Pod in the tunnel's namespace sends the method to Traefik with the host for
# each path as written, dot segments and doubled slashes kept; sets answers to one "<status> <body bytes>" line per path.
ask() {
  local name="$1" host="$2" method="$3" joined data=()
  shift 3
  joined="$(
    IFS=,
    printf '%s' "$*"
  )"
  [ "$method" != POST ] || data=(--data logout_token=malformed)
  request "$TUNNEL_NAMESPACE" "$name" "$host" "$traefik_origin{$joined}" --path-as-is \
    --write-out '%{http_code} %{size_download}\n' "${data[@]}"
  [ "$exit_code" = 0 ] || fail "the Pod $name ended with curl's exit code $exit_code"
  mapfile -t answers <<<"$status"
  [ "${#answers[@]}" = "$#" ] || fail "the Pod $name printed ${#answers[@]} answers for $# paths"
}

# Traefik's own 404 for the control path, from a host nothing routes.
ask backchannel-unrouted "$UNROUTED_HOST" GET /
traefik_not_found="${answers[0]}"
[[ $traefik_not_found == "404 "* ]] || fail "Traefik answered '$traefik_not_found' for $UNROUTED_HOST/, not 404"

# answered_by_traefik <host> <method>: the answers to the last ask are Traefik's for every path of the back-channel
# route. A mismatch is printed and returned.
answered_by_traefik() {
  local host="$1" method="$2" index offset="${#refused_paths[@]}"
  for index in "${!refused_paths[@]}"; do
    [ "${answers[index]}" = "$refusal" ] || {
      echo "$method ${refused_paths[index]} with the host $host got '${answers[index]}', not '$refusal'"
      return 1
    }
  done
  for index in "${!encoded_paths[@]}"; do
    [[ ${answers[offset + index]} == "400 "* || ${answers[offset + index]} == "$traefik_not_found" ]] || {
      echo "$method ${encoded_paths[index]} with the host $host got '${answers[offset + index]}', neither 400 nor Traefik's 404"
      return 1
    }
  done
}

# refused_on <host> <control path> <round>: POST and GET get Traefik's answer for every path of the route, while the
# control path, which the host's Ingress routes, and the neighbouring paths still reach the app, that is get neither the
# refusal nor a 5xx. The round only names the Pods.
refused_on() {
  local host="$1" control_path="$2" name="backchannel-${1//./-}-$3" offset index
  local kept_paths=("$control_path" "${neighbour_paths[@]}") kept_answers
  ask "$name-post" "$host" POST "${refused_paths[@]}" "${encoded_paths[@]}"
  answered_by_traefik "$host" POST || return 1
  ask "$name-get" "$host" GET "${refused_paths[@]}" "${encoded_paths[@]}" "${kept_paths[@]}"
  offset=$((${#refused_paths[@]} + ${#encoded_paths[@]}))
  kept_answers=("${answers[@]:offset}")
  answered_by_traefik "$host" GET || return 1
  for index in "${!kept_paths[@]}"; do
    [ "${kept_answers[index]}" != "$refusal" ] && [[ ${kept_answers[index]} != 5* ]] || {
      echo "GET ${kept_paths[index]} with the host $host got '${kept_answers[index]}', which is the refusal or a server error"
      return 1
    }
  done
  [ "${kept_answers[0]}" != "$traefik_not_found" ] || {
    echo "GET $control_path with the host $host got '${kept_answers[0]}', which is not an app's answer"
    return 1
  }
}

prove_hosts() {
  local round="$1" host control_path
  for host in "${routed_hosts[@]}"; do
    control_path="$(kubectl get ingresses -A -o jsonpath="{range .items[*]}{range .spec.rules[?(@.host==\"$host\")]}{.http.paths[0].path}{\"\n\"}{end}{end}" | head -n 1)"
    until_true 120 "Traefik refuses the back-channel route on $host and routes $control_path" refused_on "$host" "$control_path" "$round"
    echo "a Pod in $TUNNEL_NAMESPACE gets Traefik's answer for ${#refused_paths[@]} spellings of $backchannel_path and ${#encoded_paths[@]} encoded ones with the host $host, by POST and GET, the app's answer for $control_path and no refusal for ${#neighbour_paths[@]} neighbouring paths"
  done
}

# A host nothing routes gets the refusal too, since the rule names no host.
ask backchannel-unrouted-paths "$UNROUTED_HOST" POST "${refused_paths[@]}"
for index in "${!refused_paths[@]}"; do
  [ "${answers[index]}" = "$refusal" ] ||
    fail "POST ${refused_paths[index]} with the host $UNROUTED_HOST got '${answers[index]}', not '$refusal'"
done
echo "a Pod in $TUNNEL_NAMESPACE gets Traefik's answer for the back-channel route with the host $UNROUTED_HOST that nothing routes"

prove_hosts first

# Keycloak's call goes to the Service and never passes Traefik: songmaker's web answers it by its own rule.
manifest=apps/songmaker/web.yaml
service_name="$(yq 'select(.kind == "Service") | .metadata.name' "$manifest")"
service_port="$(yq 'select(.kind == "Service") | .spec.ports[0].port' "$manifest")"
backchannel_host="$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "web") | .env[] | select(.name == "BACKCHANNEL_LOGOUT_HOST") | .value' "$manifest")"
service_url="http://$service_name.$SONGMAKER_NAMESPACE.svc.cluster.local:$service_port$backchannel_path"
request "$SONGMAKER_NAMESPACE" backchannel-in-namespace "$backchannel_host" "$service_url" --data logout_token=malformed
[ "$status" = 400 ] || fail "a Pod in $SONGMAKER_NAMESPACE got '$status' from the Service $service_name for the malformed logout, not 400"
echo "a Pod in $SONGMAKER_NAMESPACE gets 400 from the Service $service_name for the malformed logout, so the route is untouched"

# The routers come from files the pod reads at its start, so a new pod must hold the rule as well.
kubectl --namespace traefik rollout restart deployment/traefik
kubectl --namespace traefik rollout status deployment/traefik --timeout=3m
prove_hosts restarted
