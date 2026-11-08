#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
namespace="$KEYCLOAK_NAMESPACE"
applied_revision="$(kubectl -n flux-system get kustomization "$namespace" -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization $namespace applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n "$namespace" wait --for=condition=Available --timeout=5m deployment/keycloak
kubectl -n "$namespace" wait job/config-cli --for=condition=Complete --timeout=10m
echo "the Kustomization $namespace applied the candidate; Keycloak is Available and config-cli's Job completed" \
  "after $(kubectl -n "$namespace" get job/config-cli -o jsonpath='{.status.failed}') failed attempts"

keycloak="$(kubectl -n "$namespace" get deployment keycloak -o json)"
keycloak_env() { NAME="$1" yq -p json '.spec.template.spec.containers[0].env[] | select(.name == strenv(NAME))' <<<"$keycloak"; }
public_url="$(keycloak_env KC_HOSTNAME | yq '.value')"
realm="$(yq '.realm' "$REALM_FILE")"
public_issuer="$public_url/realms/$realm"
public_host="${public_url#https://}"
read -r secret_name secret_key < <(keycloak_env KC_BOOTSTRAP_ADMIN_CLIENT_SECRET |
  yq '.valueFrom.secretKeyRef | .name + " " + .key')
read -r admin_client < <(keycloak_env KC_BOOTSTRAP_ADMIN_CLIENT_ID | yq '.value')
# Keycloak keeps the forwarded headers of exactly the senders whose headers Traefik's web entry point keeps.
keycloak_trusted="$(keycloak_env KC_PROXY_TRUSTED_ADDRESSES | yq '.value')"
traefik_trusted="$(kubectl -n traefik get deployment traefik -o json | yq \
  '.spec.template.spec.containers[0].args[] | select(test("^--entryPoints[.]web[.]forwardedHeaders[.]trustedIPs=")) | sub("^[^=]*=", "")')"
[ -n "$keycloak_trusted" ] && [ "$(tr , '\n' <<<"$keycloak_trusted" | sort)" = "$(tr , '\n' <<<"$traefik_trusted" | sort)" ] ||
  fail "Keycloak trusts the forwarded headers of '$keycloak_trusted', Traefik's web those of '$traefik_trusted'"
echo "Keycloak and Traefik's web trust the forwarded headers of the same senders: $keycloak_trusted"
admin_secret="$(kubectl -n "$namespace" get secret "$secret_name" -o go-template="{{index .data \"$secret_key\" | base64decode}}")"
echo "::add-mask::$admin_secret"

# The runner reaches Keycloak through a port-forward, which no NetworkPolicy sees; the Pods below meet the policies.
forward_log="$RUNNER_TEMP/keycloak-forward.log"
timeout 20m kubectl -n "$namespace" port-forward --address 127.0.0.1 service/keycloak :8080 >"$forward_log" 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true' EXIT
timeout 30 bash -c 'until grep -q "^Forwarding from 127.0.0.1:" "$0"; do sleep 1; done' "$forward_log" ||
  fail "the port-forward to Keycloak did not start: $(<"$forward_log")"
local_url="http://127.0.0.1:$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -n 1)"
admin_token() {
  curl --silent --show-error --fail --data grant_type=client_credentials --data-urlencode "client_id=$admin_client" \
    --data-urlencode "client_secret=$admin_secret" "$local_url/realms/master/protocol/openid-connect/token" |
    jq --raw-output .access_token
}
# admin <method> <path> [<JSON body>]: one admin REST call with a fresh token; prints the answer's body.
admin() {
  local token body=()
  token="$(admin_token)"
  [ "$#" -lt 3 ] || body=(--data "$3")
  curl --silent --show-error --fail --request "$1" --header "Authorization: Bearer $token" \
    --header 'Content-Type: application/json' "${body[@]}" "$local_url/admin/realms/$2"
}

# B1: the realm as the files declare it, on the public issuer, with its declared groups and without the retired one.
issuer="$(curl --silent --show-error --fail "$local_url/realms/$realm/.well-known/openid-configuration" | jq --raw-output .issuer)"
[ "$issuer" = "$public_issuer" ] || fail "discovery names the issuer '$issuer', not $public_issuer"
echo "discovery names the issuer $issuer"
declared_groups="$(yq --output-format json '.groups' "$REALM_FILE" | jq --raw-output '
  def group_paths($parent): .[] | ($parent + "/" + .name) as $path | $path, ((.subGroups // []) | group_paths($path));
  group_paths("")')"
[ -n "$declared_groups" ] || fail "$REALM_FILE declares no group"
while IFS= read -r group; do
  live_path="$(admin GET "$realm/group-by-path$group" | jq --raw-output .path)" || live_path=""
  [ "$live_path" = "$group" ] || fail "the realm $realm holds no group $group, which $REALM_FILE declares"
done <<<"$declared_groups"
retired_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "Authorization: Bearer $(admin_token)" "$local_url/admin/realms/$realm/group-by-path$RETIRED_GROUP")"
[ "$retired_status" = 404 ] || fail "an empty database's realm $realm answers $retired_status for $RETIRED_GROUP, not 404"
echo "the realm $realm holds the $(grep -c . <<<"$declared_groups") groups $REALM_FILE declares, and an empty database" \
  "none at $RETIRED_GROUP"
redirect_uri="$(CLIENT="$LOGIN_CLIENT" yq '.clients[] | select(.clientId == strenv(CLIENT)) | .redirectUris[0]' "$REALM_FILE")"
login_page="$RUNNER_TEMP/keycloak-login.html"
login_status="$(curl --silent --output "$login_page" --write-out '%{http_code}' --get \
  --data-urlencode "client_id=$LOGIN_CLIENT" --data-urlencode "redirect_uri=$redirect_uri" \
  --data response_type=code --data scope=openid --data code_challenge_method=S256 \
  --data "code_challenge=$(openssl rand -hex 32)" "$local_url/realms/$realm/protocol/openid-connect/auth")"
[ "$login_status" = 200 ] || fail "the login page of $LOGIN_CLIENT answered $login_status, not 200"
asset_path="$(grep -o '/resources/[a-z0-9]\{5\}/[^"?]*' "$login_page" | head -n 1)"
[ -n "$asset_path" ] || fail "the login page names no asset under /resources/<version>/"
echo "the login page of $LOGIN_CLIENT answers 200 and names the asset $asset_path"

# A second run on the applied realms changes nothing: their exports and their declared service accounts with their
# roles and groups are equal, and it needs no retry.
realm_state() {
  local realm_file realm_name username user
  for realm_file in "$MASTER_FILE" "$REALM_FILE"; do
    realm_name="$(yq '.realm' "$realm_file")"
    admin POST "$realm_name/partial-export?exportClients=true&exportGroupsAndRoles=true" | jq --sort-keys . || return 1
    for username in $(yq '.users[] | select(.serviceAccountClientId) | .username' "$realm_file"); do
      user="$(admin GET "$realm_name/users?exact=true&username=$username" | jq --sort-keys '.[0] // empty')" || return 1
      [ -n "$user" ] || { echo "::error::the realm $realm_name holds no user $username" >&2; return 1; }
      printf '%s\n' "$user"
      admin GET "$realm_name/users/$(jq --raw-output .id <<<"$user")/role-mappings" | jq --sort-keys . || return 1
      admin GET "$realm_name/users/$(jq --raw-output .id <<<"$user")/groups" | jq --sort-keys . || return 1
    done
  done
}
fingerprint() { realm_state | sha256sum; }
before="$(fingerprint)" || fail "the realms master and $realm cannot be read"
kubectl -n "$namespace" delete job config-cli --wait --timeout=2m
flux reconcile kustomization "$namespace" --timeout=10m
kubectl -n "$namespace" wait job/config-cli --for=condition=Complete --timeout=10m
second_failures="$(kubectl -n "$namespace" get job/config-cli -o jsonpath='{.status.failed}')"
[ -z "$second_failures" ] || fail "config-cli's second run failed $second_failures times before it completed"
after="$(fingerprint)" || fail "the realms master and $realm cannot be read after config-cli's second run"
[ "$after" = "$before" ] || fail "config-cli's second run changed the realms master or $realm"
echo "config-cli's second run completed at its first attempt and changed neither master nor $realm"

# B2: through Traefik, as the tunnel asks, the public paths answer and every other path of the host is 404.
web_port="$(kubectl -n traefik get service traefik -o jsonpath='{.spec.ports[?(@.name=="web")].port}')"
traefik_url="http://traefik.traefik.svc:${web_port}"
# expect <status> <host> <path> [<curl argument>...]: a Pod in the tunnel's namespace gets the status for the path.
expect() {
  local expected="$1" host="$2" path="$3"
  shift 3
  request "$TUNNEL_NAMESPACE" auth-route-request "$host" "$traefik_url$path" "$@"
  [ "$status" = "$expected" ] || fail "Traefik answered '$status', not '$expected', for $host$path"
  echo "Traefik answered $expected for $host$path"
}
expect 200 "$public_host" "/realms/$realm/.well-known/openid-configuration"
expect 200 "$public_host" "$asset_path"
expect 404 "$public_host" /resources/master/login/en
expect 404 "$public_host" /admin/
expect 404 "$public_host" /realms/master/.well-known/openid-configuration
expect "302 $public_issuer/account" "$public_host" / --write-out '%{http_code} %{redirect_url}'
expect 404 "$UNROUTED_HOST" /
expect 400 "$public_host" "/realms/$realm/a%2Fb"

# B3: only Traefik and Keycloak's own namespace reach it; Keycloak reaches its Postgres and nothing else.
keycloak_service_url="http://keycloak.$namespace.svc:$(kubectl -n "$namespace" get service keycloak -o jsonpath='{.spec.ports[0].port}')"
request "$namespace" own-namespace-request "$public_host" "$keycloak_service_url/realms/$realm/.well-known/openid-configuration"
[ "$status" = 200 ] || fail "Keycloak answered $status, not 200, to a Pod in $namespace"
caller_namespace="$(yq 'select(.kind == "Service") | .metadata.namespace' "$CALLER_MANIFEST")"
request "$caller_namespace" caller-request "$public_host" "$keycloak_service_url/realms/$realm/.well-known/openid-configuration"
[ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; } ||
  fail "a Pod in $caller_namespace got the status $status from Keycloak, curl exit code $exit_code"
echo "Keycloak answers a Pod in $namespace and gives one in $caller_namespace no answer (curl exit code $exit_code)"
caller_service="$(yq 'select(.kind == "Service") | .metadata.name + "." + .metadata.namespace + ".svc:" + (.spec.ports[0].port | tostring)' "$CALLER_MANIFEST")"
postgres_target="postgres.$namespace.svc:$(kubectl -n "$namespace" get service postgres -o jsonpath='{.spec.ports[0].port}')"
cluster_port="$(kubectl -n "${CLUSTER_SERVICE%/*}" get service "${CLUSTER_SERVICE#*/}" -o jsonpath='{.spec.ports[0].port}')"
cluster_target="${CLUSTER_SERVICE#*/}.${CLUSTER_SERVICE%/*}.svc:$cluster_port"
# No NetworkPolicy selects the API server behind that Service, so only keycloak-egress keeps Keycloak from it: a Pod
# beside Keycloak without its labels gets an answer.
request "$namespace" free-egress-request "${cluster_target%:*}" "https://$cluster_target/livez" --insecure
[ "$status" != 000 ] || fail "a Pod in $namespace without Keycloak's labels got no answer from $cluster_target, curl exit \
code $exit_code, so the probe below proves no policy"
echo "a Pod in $namespace without Keycloak's labels got $status from $cluster_target"
# hopin's own policy refuses every sender but Traefik, so only a throwaway target in hopin's namespace, with hopin's
# labels and port and a throwaway policy admitting Keycloak's namespace to it alone, leaves keycloak-egress as the one
# thing that can keep Keycloak from that namespace. It never turns ready, so hopin's Service never routes to it.
target_name="keycloak-egress-target"
target_objects=("pod/$target_name" "networkpolicy/$target_name")
remove_target() {
  local left
  kubectl -n "$caller_namespace" delete "${target_objects[@]}" --ignore-not-found --wait --timeout=2m
  left="$(kubectl -n "$caller_namespace" get "${target_objects[@]}" --ignore-not-found --output name)" ||
    fail "$caller_namespace cannot be read for the throwaway ${target_objects[*]}"
  [ -z "$left" ] || fail "$caller_namespace still holds the throwaway $left"
  echo "$caller_namespace holds none of the throwaway ${target_objects[*]}"
}
trap 'kill "$forward_pid" 2>/dev/null || true; remove_target' EXIT
caller_labels="$(yq --output-format json 'select(.kind == "Deployment") | .spec.template.metadata.labels' "$CALLER_MANIFEST")"
caller_port="$(yq --output-format json 'select(.kind == "Deployment") | .spec.template.spec.containers[0].ports[0]' "$CALLER_MANIFEST")"
jq --null-input --arg name "$target_name" --arg image "$PROBE_IMAGE" --argjson labels "$caller_labels" \
  --argjson port "$caller_port" '{apiVersion: "v1", kind: "Pod",
    metadata: {name: $name, labels: ($labels + {"app.kubernetes.io/component": $name})},
    spec: {restartPolicy: "Never", automountServiceAccountToken: false, enableServiceLinks: false,
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "target", image: $image, ports: [$port],
        command: ["httpd", "-f", "-p", ($port.containerPort | tostring), "-h", "/tmp"],
        readinessProbe: {exec: {command: ["false"]}},
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}]}}' |
  kubectl -n "$caller_namespace" create -f -
jq --null-input --arg name "$target_name" --arg from "$namespace" --argjson port "$caller_port" '{
    apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: {name: $name},
    spec: {podSelector: {matchLabels: {"app.kubernetes.io/component": $name}}, policyTypes: ["Ingress"],
      ingress: [{from: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": $from}}}],
        ports: [{port: $port.name, protocol: "TCP"}]}]}}' |
  kubectl -n "$caller_namespace" create -f -
kubectl -n "$caller_namespace" wait "pod/$target_name" --timeout=2m --for=jsonpath='{.status.containerStatuses[0].started}'=true
target_address="$(kubectl -n "$caller_namespace" get "pod/$target_name" -o jsonpath='{.status.podIP}'):$(jq .containerPort <<<"$caller_port")"
request "$namespace" target-request "${target_address%:*}" "http://$target_address/"
[ "$status" != 000 ] || fail "a Pod in $namespace without Keycloak's labels got no answer from the throwaway target \
$target_address in $caller_namespace, curl exit code $exit_code, so the probe below proves no policy"
echo "a Pod in $namespace without Keycloak's labels got $status from the throwaway target $target_address in $caller_namespace"
# The image has bash but no network client, so bash's /dev/tcp opens each connection from Keycloak's own container
# and names its outcome: open, refused, timeout, or failed for any other end, such as a name that does not resolve.
connection_probe='message="$(timeout 5 bash -c "exec 3<>/dev/tcp/${0%:*}/${0##*:}" 2>&1)"
  case "$?:$message" in
    0:*) echo open ;;
    124:*) echo timeout ;;
    *"Connection refused"* | *"No route to host"* | *unreachable*) echo refused ;;
    *) echo failed ;;
  esac'
# reach <host:port>: succeeds when Keycloak's container connects and fails when its connection is refused or times
# out; a probe that cannot run or ends otherwise fails the cell.
reach() {
  local outcome
  outcome="$(kubectl -n "$namespace" exec deployment/keycloak --container keycloak -- bash -c "$connection_probe" "$1")" ||
    fail "the connection probe could not run in Keycloak's container for $1"
  case "$outcome" in
    open) return 0 ;;
    refused | timeout) echo "Keycloak's container gets $outcome from $1" && return 1 ;;
    *) fail "the connection probe in Keycloak's container ended '$outcome' for $1, neither connected nor refused" ;;
  esac
}
reach "$postgres_target" || fail "Keycloak's container does not reach its Postgres at $postgres_target"
# The P7a step shows a Pod without Keycloak's labels reaching the outside target.
for target in "$cluster_target" "$OUTSIDE_TARGET" "$target_address" "$caller_service"; do
  if reach "$target"; then fail "Keycloak's container reaches $target"; fi
done
echo "Keycloak's container reaches $postgres_target, neither $cluster_target nor $OUTSIDE_TARGET, nor the target" \
  "$target_address in $caller_namespace, nor $caller_service"
remove_target
trap 'kill "$forward_pid" 2>/dev/null || true' EXIT

# B6: a person's password grant waits for the terms; an administrator without TOTP gets no token at all.
probe_password="$(openssl rand -hex 24)"
echo "::add-mask::$probe_password"
probe_client=b6-password-grant
probe_user=b6-person
admin POST "$realm/clients" "{\"clientId\": \"$probe_client\", \"publicClient\": true, \"directAccessGrantsEnabled\": true, \"standardFlowEnabled\": false}"
admin POST "$realm/users" "$(USER="$probe_user" PASSWORD="$probe_password" jq --null-input \
  '{username: env.USER, enabled: true, email: (env.USER + "@example.invalid"), emailVerified: true, firstName: "B6",
    lastName: "Person", requiredActions: ["TERMS_AND_CONDITIONS"],
    credentials: [{type: "password", value: env.PASSWORD, temporary: false}]}')"
probe_user_id="$(admin GET "$realm/users?exact=true&username=$probe_user" | jq --raw-output '.[0].id')"
# password_grant <realm> <client> <user>: sets grant_status and grant_body.
password_grant() {
  grant_body="$(curl --silent --show-error --write-out '\n%{http_code}' --data grant_type=password \
    --data-urlencode "client_id=$2" --data-urlencode "username=$3" --data-urlencode "password=$probe_password" \
    --data scope=openid "$local_url/realms/$1/protocol/openid-connect/token")"
  grant_status="${grant_body##*$'\n'}"
  grant_body="${grant_body%$'\n'*}"
}
password_grant "$realm" "$probe_client" "$probe_user"
[ "$grant_status" = 400 ] && [ "$(jq --raw-output .error <<<"$grant_body")" = invalid_grant ] &&
  [ "$(jq --raw-output '.access_token // empty' <<<"$grant_body")" = "" ] ||
  fail "a password grant with TERMS_AND_CONDITIONS pending answered $grant_status, not 400 invalid_grant without a token"
echo "a password grant with TERMS_AND_CONDITIONS pending is refused with 400 invalid_grant"
admin PUT "$realm/users/$probe_user_id" '{"requiredActions": []}'
password_grant "$realm" "$probe_client" "$probe_user"
[ "$grant_status" = 200 ] || fail "a password grant with the terms accepted answered $grant_status, not 200"
token_issuer="$(jq --raw-output .access_token <<<"$grant_body" | cut -d . -f 2 | tr '_-' '/+' |
  awk '{ while (length($0) % 4) $0 = $0 "="; print }' | base64 --decode | jq --raw-output .iss)"
[ "$token_issuer" = "$public_issuer" ] || fail "the person's token names the issuer '$token_issuer', not $public_issuer"
echo "with the terms accepted the password grant yields a token of the public issuer $token_issuer"
admin DELETE "$realm/users/$probe_user_id"
admin DELETE "$realm/clients/$(admin GET "$realm/clients?clientId=$probe_client" | jq --raw-output '.[0].id')"

probe_admin=b6-admin
admin POST master/users "$(USER="$probe_admin" PASSWORD="$probe_password" jq --null-input \
  '{username: env.USER, enabled: true, email: (env.USER + "@example.invalid"), emailVerified: true, firstName: "B6",
    lastName: "Admin", credentials: [{type: "password", value: env.PASSWORD, temporary: false}]}')"
probe_admin_id="$(admin GET "master/users?exact=true&username=$probe_admin" | jq --raw-output '.[0].id')"
admin POST "master/users/$probe_admin_id/role-mappings/realm" "[$(admin GET master/roles/admin)]"
# Keycloak's built-in direct grant asks for TOTP only from a user who has it, so through a client bound to that flow
# the same administrator and password get a token: the refusal after it is master's own flow, not a failed sign-in.
built_in_flow="$(admin GET master/authentication/flows | jq --raw-output '.[] | select(.alias == "direct grant") | .id')"
[ -n "$built_in_flow" ] || fail "the realm master holds no built-in flow 'direct grant'"
control_client=b6-admin-control
admin POST master/clients "$(CLIENT="$control_client" FLOW="$built_in_flow" jq --null-input \
  '{clientId: env.CLIENT, publicClient: true, directAccessGrantsEnabled: true, standardFlowEnabled: false,
    authenticationFlowBindingOverrides: {direct_grant: env.FLOW}}')"
password_grant master "$control_client" "$probe_admin"
control_status="$grant_status"
control_token="$(jq --raw-output '.access_token // empty' <<<"$grant_body")"
password_grant master admin-cli "$probe_admin"
admin DELETE "master/users/$probe_admin_id"
admin DELETE "master/clients/$(admin GET "master/clients?clientId=$control_client" | jq --raw-output '.[0].id')"
[ "$control_status" = 200 ] && [ -n "$control_token" ] ||
  fail "a master administrator without TOTP got $control_status and no token through the built-in direct grant, so" \
    "the refusal proves no flow"
[ "$grant_status" = 401 ] && [ "$(jq --raw-output '.access_token // empty' <<<"$grant_body")" = "" ] ||
  fail "a master administrator without TOTP got $grant_status from a password grant, not 401 without a token"
echo "a master administrator without TOTP gets a token through the built-in direct grant, and 401 without a token" \
  "through master's own"
