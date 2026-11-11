#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
deployment="$(kubectl -n "$TUNNEL_NAMESPACE" get deployment cloudflared -o json)"
[ "$(yq '.spec.template.spec.containers | length' <<<"$deployment")" = 1 ] ||
  fail "the Deployment cloudflared has not exactly one container"
mapfile -t run_arguments < <(yq '.spec.template.spec.containers[0].args[]' <<<"$deployment")
config_file=""
for index in "${!run_arguments[@]}"; do
  [ "${run_arguments[index]}" != --config ] || config_file="${run_arguments[index + 1]:-}"
done
[ -n "$config_file" ] || fail "the Deployment cloudflared's arguments name no --config file"

# cloudflared reads its config once, when it starts, and Flux rolls a Deployment only when its template
# changes: the template carries the hash of the lines, so a changed line cannot land without a rollout.
config_key="${config_file##*/}"
configmap_path="{.data.${config_key//./\\.}}"
expected_hash="$(kubectl -n "$TUNNEL_NAMESPACE" get configmap cloudflared -o jsonpath="$configmap_path" | sha256sum)"
expected_hash="${expected_hash%% *}"
annotated_hash="$(yq '.spec.template.metadata.annotations["checksum/config"] // ""' <<<"$deployment")"
[ "$annotated_hash" = "$expected_hash" ] ||
  fail "the Deployment cloudflared's template carries checksum/config '$annotated_hash', but the lines of the ConfigMap cloudflared hash to $expected_hash: set the annotation to that hash, so the changed lines roll the pod"
echo "the Deployment cloudflared's template carries the hash of the ConfigMap's lines"
config="$(kubectl -n "$TUNNEL_NAMESPACE" get configmap cloudflared -o jsonpath="$configmap_path")"
mapfile -t routed_lines < <(yq '.ingress | to_entries | .[] | select(.value | has("hostname")) | .key' <<<"$config")
[ "${#routed_lines[@]}" -gt 0 ] || fail "the ConfigMap cloudflared names no hostname"

# run_template_pod <name> <argument>...: a Pod from the Deployment's template with its Secret volumes dropped
# and its arguments replaced, admitted by Pod Security or refused, run once; sets pod_log and pod_exit_code.
run_template_pod() {
  local name="$1"
  shift
  POD_NAME="$name" POD_ARGUMENTS="$(printf '%s\n' "$@")" yq -o json '
    (.spec.template.spec.volumes | map(select(has("secret"))) | map(.name)) as $secret_volumes |
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(POD_NAME)}, "spec": .spec.template.spec} |
    .spec.restartPolicy = "Never" |
    .spec.volumes |= map(select(has("secret") | not)) |
    .spec.containers[0].volumeMounts |= map(select(.name as $mount | $secret_volumes | any_c(. == $mount) | not)) |
    .spec.containers[0].args = (strenv(POD_ARGUMENTS) | split("\n"))' <<<"$deployment" |
    kubectl -n "$TUNNEL_NAMESPACE" create -f - ||
    fail "the API server refused the Pod $name built from the Deployment cloudflared's template"
  kubectl -n "$TUNNEL_NAMESPACE" wait "pod/$name" --timeout=2m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' || {
    kubectl -n "$TUNNEL_NAMESPACE" describe "pod/$name"
    fail "the Pod $name did not run to its end"
  }
  pod_exit_code="$(kubectl -n "$TUNNEL_NAMESPACE" get "pod/$name" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  pod_log="$(kubectl -n "$TUNNEL_NAMESPACE" logs "pod/$name")"
  printf '%s\n' "$pod_log"
  kubectl -n "$TUNNEL_NAMESPACE" delete pod "$name" --wait --timeout=2m
}
# match_rule <host> [<path>]: sets matched_index and matched_service to the index in the lines and the service
# of the rule cloudflared matches for the host and path.
match_rule() {
  local host="$1" path="${2:-}"
  run_template_pod "ingress-rule-${host//./-}" tunnel --config "$config_file" ingress rule "https://$host$path"
  [ "$pod_exit_code" = 0 ] || fail "cloudflared tunnel ingress rule exited $pod_exit_code for $host$path"
  matched_index="$(sed -n 's/^Matched rule #//p' <<<"$pod_log")"
  matched_service="$(sed -n 's/^\tservice: //p' <<<"$pod_log")"
}

# cloudflared prints OK only after it parsed the rules of the file it names; the last must match every host.
run_template_pod ingress-validate tunnel --config "$config_file" ingress validate
[ "$pod_exit_code" = 0 ] && grep -qx OK <<<"$pod_log" ||
  fail "cloudflared tunnel ingress validate refused $config_file of the ConfigMap cloudflared"
echo "the Pod from the Deployment's template was admitted, and ingress validate passes on $config_file"

match_rule "$UNROUTED_HOST"
[ "$matched_service" = http_status:404 ] ||
  fail "the tunnel sends the unrouted host $UNROUTED_HOST to '$matched_service', not http_status:404"
echo "the tunnel answers the unrouted host $UNROUTED_HOST with http_status:404"

# Every line that names a host sends it, on the line's path if it names one, to Traefik's Service at its web
# port, and a client Pod beside cloudflared sends the request cloudflared forwards, as the line's
# httpHostHeader if it rewrites the host: Traefik answers 404 for a host neither an Ingress nor its file provider
# routes, and passes on the others; a host whose file provider redirects its root answers that redirect. Another
# path on a host a line restricts by path falls through to the final http_status:404.
file_provider="$(kubectl -n traefik get configmap traefik-file-provider -o jsonpath='{.data.config\.yml}')"
file_provider_hosts="$(yq '.http.routers[].rule' <<<"$file_provider" | { grep -o 'Host(`[^`]*`)' || true; } | sed 's/^Host(`//; s/`)$//')"
ingress_hosts="$(kubectl get ingresses -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}')"
ingress_hosts+=$'\n'"$file_provider_hosts"
web_port="$(kubectl -n traefik get service traefik -o jsonpath='{.spec.ports[?(@.name=="web")].port}')"
traefik_host="$(kubectl -n traefik get service traefik -o jsonpath='{.metadata.name}.{.metadata.namespace}.svc')"
client_pod_template="${CLIENT_POD//@IMAGE@/${CLIENT_IMAGE}}"
# cloudflared matches a path by regular expression, so the job judges a line's path only as one literal path.
literal_path_pattern='^\^(/[A-Za-z0-9_~-][A-Za-z0-9_~/-]*)\$$'
for line_index in "${routed_lines[@]}"; do
  line="$(yq ".ingress[$line_index]" <<<"$config")"
  routed_host="$(yq '.hostname' <<<"$line")"
  line_path="$(yq '.path // ""' <<<"$line")"
  forwarded_host="$(yq ".ingress[$line_index].originRequest.httpHostHeader // .originRequest.httpHostHeader // .ingress[$line_index].hostname" <<<"$config")"
  forwarded_as=""
  [ "$forwarded_host" = "$routed_host" ] || forwarded_as=" as $forwarded_host"
  request_path=""
  if [ -n "$line_path" ]; then
    [[ $line_path =~ $literal_path_pattern ]] ||
      fail "the line #$line_index restricts $routed_host to the path '$line_path', which the job judges only as ^/<literal path>\$"
    request_path="${BASH_REMATCH[1]}"
    match_rule "$routed_host" /
    [ "$matched_service" = http_status:404 ] ||
      fail "the tunnel sends $routed_host/, outside the path of the line #$line_index, to '$matched_service', not http_status:404"
    echo "the tunnel answers $routed_host/, outside the path of the line #$line_index, with http_status:404"
  else
    # A host whose Ingress routes no "/" is asked on the first path of its rule instead.
    request_path="$(kubectl get ingresses -A -o jsonpath="{range .items[*]}{range .spec.rules[?(@.host==\"$forwarded_host\")]}{.http.paths[0].path}{\"\n\"}{end}{end}" | head -n 1)"
    [ "$request_path" != / ] || request_path=""
  fi
  match_rule "$routed_host" "$request_path"
  [ "$matched_index" = "$line_index" ] ||
    fail "the tunnel sends $routed_host$request_path to the line #$matched_index, not to its own line #$line_index"
  routed_url="$matched_service"
  [[ $routed_url =~ ^http://([^:/]+):([0-9]+)/?$ ]] ||
    fail "the tunnel sends $routed_host$request_path to '$routed_url', not to an http URL with a host and a port"
  [[ ${BASH_REMATCH[1]} == "$traefik_host" || ${BASH_REMATCH[1]} == "$traefik_host.cluster.local" ]] ||
    fail "the tunnel sends $routed_host$request_path to $routed_url, not to the Service traefik of namespace traefik"
  [ "${BASH_REMATCH[2]}" = "$web_port" ] ||
    fail "the tunnel sends $routed_host$request_path to $routed_url, not to Traefik's web port $web_port"
  client_pod_name="routed-request-${routed_host//./-}"
  client_pod="${client_pod_template//@NAME@/${client_pod_name}}"
  client_pod="${client_pod//@HOST@/${forwarded_host}}"
  client_pod="${client_pod//@URL@/${routed_url%/}${request_path:-/}}"
  # The redirect the file provider gives the host's root, which the client Pod then prints beside the status.
  root_redirect=""
  root_middleware="$(FORWARDED_HOST="$forwarded_host" yq '.http.routers[] |
    select(.rule | contains("Host(`" + strenv(FORWARDED_HOST) + "`) && Path(`/`)")) | .middlewares[0] // ""' <<<"$file_provider")"
  if [ -n "$root_middleware" ]; then
    root_redirect="$(MIDDLEWARE="$root_middleware" yq '.http.middlewares[strenv(MIDDLEWARE)].redirectRegex |
      ((.permanent // false | tostring) + " " + .replacement)' <<<"$file_provider" | sed 's/^true /301 /; s/^false /302 /')"
  fi
  if [ -n "$root_redirect" ] && [ -z "$request_path" ]; then
    client_pod="$(yq '.spec.containers[0].args += ["--write-out", "%{http_code} %{redirect_url}"]' <<<"$client_pod")"
  else
    root_redirect=""
  fi
  printf '%s\n' "$client_pod" | kubectl -n "$TUNNEL_NAMESPACE" create -f -
  kubectl -n "$TUNNEL_NAMESPACE" wait "pod/$client_pod_name" --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m || {
    kubectl -n "$TUNNEL_NAMESPACE" describe "pod/$client_pod_name"
    kubectl -n "$TUNNEL_NAMESPACE" logs "pod/$client_pod_name" || true
    fail "the client Pod in $TUNNEL_NAMESPACE did not succeed for $routed_host"
  }
  status="$(kubectl -n "$TUNNEL_NAMESPACE" logs "pod/$client_pod_name")"
  kubectl -n "$TUNNEL_NAMESPACE" delete pod "$client_pod_name" --wait --timeout=2m
  if [ -n "$root_redirect" ]; then
    [ "$status" = "$root_redirect" ] ||
      fail "Traefik answered '$status' for $routed_host/$forwarded_as at $routed_url, not the redirect '$root_redirect' its file provider gives"
    echo "the tunnel sends $routed_host/$forwarded_as to $routed_url, where a Pod in $TUNNEL_NAMESPACE gets the redirect '$status'"
  elif grep -qxF "$forwarded_host" <<<"$ingress_hosts"; then
    [[ $status =~ ^[1-5][0-9][0-9]$ && $status != 404 ]] ||
      fail "Traefik answered $status for $routed_host$request_path$forwarded_as at $routed_url, which an Ingress routes"
    echo "the tunnel sends $routed_host$request_path$forwarded_as to $routed_url, where a Pod in $TUNNEL_NAMESPACE reaches its route ($status)"
  else
    [ "$status" = 404 ] ||
      fail "Traefik answered $status, not 404, for $routed_host$request_path$forwarded_as at $routed_url"
    echo "the tunnel sends $routed_host$request_path$forwarded_as to $routed_url, where a Pod in $TUNNEL_NAMESPACE reaches Traefik's 404"
  fi
done
