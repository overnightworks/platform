#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
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

# B1: the realm as the files declare it, on the public issuer, with the AI group and without the one it replaces.
issuer="$(curl --silent --show-error --fail "$local_url/realms/$realm/.well-known/openid-configuration" | jq --raw-output .issuer)"
[ "$issuer" = "$public_issuer" ] || fail "discovery names the issuer '$issuer', not $public_issuer"
echo "discovery names the issuer $issuer"
ai_group_path="$(admin GET "$realm/group-by-path$AI_GROUP" | jq --raw-output .path)"
[ "$ai_group_path" = "$AI_GROUP" ] || fail "the realm $realm holds no group $AI_GROUP"
replaced_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "Authorization: Bearer $(admin_token)" "$local_url/admin/realms/$realm/group-by-path$REPLACED_GROUP")"
[ "$replaced_status" = 404 ] || fail "an empty database's realm $realm answers $replaced_status for $REPLACED_GROUP, not 404"
echo "the realm $realm holds the group $AI_GROUP, and an empty database none at $REPLACED_GROUP"
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

# A second run on the applied realms changes nothing: their exports are equal, and it needs no retry.
fingerprint() {
  local realm_name
  for realm_name in master "$realm"; do
    admin POST "$realm_name/partial-export?exportClients=true&exportGroupsAndRoles=true" | jq --sort-keys .
  done | sha256sum
}
before="$(fingerprint)"
kubectl -n "$namespace" delete job config-cli --wait --timeout=2m
flux reconcile kustomization "$namespace" --timeout=10m
kubectl -n "$namespace" wait job/config-cli --for=condition=Complete --timeout=10m
second_failures="$(kubectl -n "$namespace" get job/config-cli -o jsonpath='{.status.failed}')"
[ -z "$second_failures" ] || fail "config-cli's second run failed $second_failures times before it completed"
[ "$(fingerprint)" = "$before" ] || fail "config-cli's second run changed the realms master or $realm"
echo "config-cli's second run completed at its first attempt and changed neither master nor $realm"

# The client Pods' requests, as the ingress step makes them.
client_pod_template="${CLIENT_POD//@IMAGE@/${CLIENT_IMAGE}}"
# request <namespace> <name> <host> <url> [<curl argument>...]: a client Pod in the namespace asks the URL with the
# host and the further arguments, runs to its end and is deleted; sets status to what it printed and exit_code to
# curl's.
request() {
  local request_namespace="$1" name="$2" host="$3" url="$4" client_pod
  shift 4
  client_pod="${client_pod_template//@NAME@/${name}}"
  client_pod="${client_pod//@HOST@/${host}}"
  client_pod="${client_pod//@URL@/${url}}"
  if [ "$#" -gt 0 ]; then
    client_pod="$(CURL_ARGUMENTS="$(printf '%s\n' "$@")" yq '.spec.containers[0].args += (strenv(CURL_ARGUMENTS) | split("\n"))' <<<"$client_pod")"
  fi
  printf '%s\n' "$client_pod" | kubectl -n "$request_namespace" create -f -
  kubectl -n "$request_namespace" wait "pod/$name" --timeout=2m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' || {
    kubectl -n "$request_namespace" describe "pod/$name"
    fail "the client Pod $name in $request_namespace did not run to its end"
  }
  exit_code="$(kubectl -n "$request_namespace" get "pod/$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  status="$(kubectl -n "$request_namespace" logs "pod/$name")"
  kubectl -n "$request_namespace" delete pod "$name" --wait --timeout=2m
}

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

# B3: only Traefik and Keycloak's own namespace reach it; Keycloak reaches its Postgres, no app and no outside host.
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
# The image has bash but no network client, so bash's /dev/tcp opens each connection from Keycloak's own container.
reach() {
  kubectl -n "$namespace" exec deployment/keycloak --container keycloak -- \
    bash -c 'timeout 5 bash -c "exec 3<>/dev/tcp/${0%:*}/${0##*:}" 2>/dev/null' "$1"
}
reach "$postgres_target" || fail "Keycloak's container does not reach its Postgres at $postgres_target"
for target in "$caller_service" "$OUTSIDE_TARGET"; do
  if reach "$target"; then fail "Keycloak's container reaches $target"; fi
done
echo "Keycloak's container reaches $postgres_target, neither $caller_service nor $OUTSIDE_TARGET"

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
password_grant master admin-cli "$probe_admin"
admin DELETE "master/users/$probe_admin_id"
[ "$grant_status" = 401 ] && [ "$(jq --raw-output '.access_token // empty' <<<"$grant_body")" = "" ] ||
  fail "a master administrator without TOTP got $grant_status from a password grant, not 401 without a token"
echo "a master administrator without TOTP gets 401 and no token from a password grant"
