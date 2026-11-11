#!/usr/bin/env bash
set -euo pipefail
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

# shellcheck source=admin_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/admin_api.sh"
public_url="$(keycloak_env KC_HOSTNAME | yq '.value')"
public_issuer="$public_url/realms/$realm"
public_host="${public_url#https://}"
# Keycloak keeps the forwarded headers of exactly the senders whose headers Traefik's web entry point keeps.
keycloak_trusted="$(keycloak_env KC_PROXY_TRUSTED_ADDRESSES | yq '.value')"
traefik_trusted="$(kubectl -n traefik get deployment traefik -o json | yq \
  '.spec.template.spec.containers[0].args[] | select(test("^--entryPoints[.]web[.]forwardedHeaders[.]trustedIPs=")) | sub("^[^=]*=", "")')"
[ -n "$keycloak_trusted" ] && [ "$(tr , '\n' <<<"$keycloak_trusted" | sort)" = "$(tr , '\n' <<<"$traefik_trusted" | sort)" ] ||
  fail "Keycloak trusts the forwarded headers of '$keycloak_trusted', Traefik's web those of '$traefik_trusted'"
echo "Keycloak and Traefik's web trust the forwarded headers of the same senders: $keycloak_trusted"
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
retired_status="$(bearer_curl "$(admin_token)" --silent --output /dev/null --write-out '%{http_code}' \
  "$local_url/admin/realms/$realm/group-by-path$RETIRED_GROUP")"
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

# canonical_form: writes its JSON input with object keys and every list sorted, at every depth. Keycloak returns its
# sets (a client's optional scopes, redirect URIs) in no fixed order, and walk sorts a list after its elements.
canonical_form() { jq --sort-keys 'walk(if type == "array" then sort else . end)'; }
# keep_part <state directory> <realm> <part>: passes its input on and keeps it as one file of the state.
keep_part() { tee "$1/$2.$3.json"; }
# A second run on the applied realms changes nothing: their exports and their declared service accounts with their
# roles and groups are equal, and it needs no retry.
realm_state() {
  local state_dir="$1" realm_file realm_name username user user_id
  for realm_file in "$MASTER_FILE" "$REALM_FILE"; do
    realm_name="$(yq '.realm' "$realm_file")"
    admin POST "$realm_name/partial-export?exportClients=true&exportGroupsAndRoles=true" | canonical_form |
      keep_part "$state_dir" "$realm_name" "partial export" || return 1
    for username in $(yq '.users[] | select(.serviceAccountClientId) | .username' "$realm_file"); do
      user="$(admin GET "$realm_name/users?exact=true&username=$username" | jq '.[0] // empty' | canonical_form)" || return 1
      [ -n "$user" ] || { echo "::error::the realm $realm_name holds no user $username" >&2; return 1; }
      printf '%s\n' "$user" | keep_part "$state_dir" "$realm_name" "user $username" || return 1
      user_id="$(jq --raw-output .id <<<"$user")"
      admin GET "$realm_name/users/$user_id/role-mappings" | canonical_form |
        keep_part "$state_dir" "$realm_name" "role mappings $username" || return 1
      admin GET "$realm_name/users/$user_id/groups" | canonical_form |
        keep_part "$state_dir" "$realm_name" "groups $username" || return 1
    done
  done
}
fingerprint() { realm_state "$1" | sha256sum; }

# The report names realms, parts and JSON paths only: a state holds client attributes and user data, so no value is
# printed, and the files stay under the runner's temporary directory.
# differing_paths <before file> <after file>: the paths of the leaves (scalars, null, false, empty arrays and objects)
# that differ, one per line. Paths come from jq's stream of path and leaf pairs, so a changed type or a missing path
# needs no lookup that could fail; jq's own errors are dropped, as they can quote a value.
differing_paths() {
  jq -n --raw-output --slurpfile before "$1" --slurpfile after "$2" '
    def leaves: [tostream | select(length == 2)] | map({key: tojson, value: .[0]}) | from_entries;
    ($before[0] | leaves) as $was | ($after[0] | leaves) as $now
    | [($was | with_entries(select(.key | in($now) | not))), ($now | with_entries(select(.key | in($was) | not)))]
    | map(.[]) | unique_by(tojson)[] | tojson' 2>/dev/null
}
# describe_difference <before dir> <after dir> <file name>: one line for a part whose two files differ.
describe_difference() {
  local before_file="$1/$3" after_file="$2/$3" name="${3%.json}" paths shown total
  paths="$(differing_paths "$before_file" "$after_file")" || paths=""
  total="$(grep -c . <<<"$paths")" || total=0
  shown="$(head -n 20 <<<"$paths" | paste -sd, - | sed 's/,/, /g')"
  [ "$total" -le 20 ] || shown="$shown, and $((total - 20)) more"
  echo "realm ${name%%.*}, part ${name#*.}: differs at ${shown:-no path}"
}
# report_difference <before dir> <after dir>: a line per part that differs or exists in one run only. The calls
# run under `||` so that a failing report cannot end the cell before its message.
report_difference() {
  local file_name label
  while IFS= read -r file_name; do
    label="${file_name%.json}"
    if [ ! -f "$1/$file_name" ] || [ ! -f "$2/$file_name" ]; then
      echo "realm ${label%%.*}, part ${label#*.}: held by only one of the two runs"
    elif ! cmp -s "$1/$file_name" "$2/$file_name"; then
      describe_difference "$1" "$2" "$file_name"
    fi
  done < <(find "$1" "$2" -type f -name '*.json' -printf '%f\n' | sort -u)
}
state_root="$(mktemp -d "$RUNNER_TEMP/keycloak-state.XXXXXX")"
mkdir "$state_root/before" "$state_root/after"
before="$(fingerprint "$state_root/before")" || fail "the realms master and $realm cannot be read"
# The file clears a client's back-channel URL with "" and states the others. Config-cli must leave no attribute on a
# cleared client, which the console or an earlier run may have filled, and hold each stated URL as the file has it.
backchannel_attribute=backchannel.logout.url
backchannel_urls() { yq --output-format json '.clients' "$REALM_FILE" | jq --raw-output --arg key "$backchannel_attribute" "$1"; }
cleared_clients="$(backchannel_urls '.[] | select(.attributes[$key] == "") | .clientId')"
stated_urls="$(backchannel_urls '.[] | select((.attributes[$key] // "") != "") | .clientId + "\t" + .attributes[$key]')"
[ -n "$cleared_clients" ] && [ -n "$stated_urls" ] ||
  fail "$REALM_FILE clears no client's back-channel URL or states none"
# client_attribute <client id> <key>: the client's attribute on the running realm; empty when the client holds none.
client_attribute() {
  admin GET "$realm/clients?clientId=$1" | jq --raw-output --exit-status --arg key "$2" '.[0].attributes[$key] // empty'
}
written_url=http://written-by-the-cell.invalid/
while IFS= read -r client_id; do
  client="$(admin GET "$realm/clients?clientId=$client_id" | jq --exit-status '.[0]')" ||
    fail "the realm $realm holds no client $client_id"
  jq --arg key "$backchannel_attribute" --arg url "$written_url" '.attributes[$key] = $url' <<<"$client" |
    admin PUT "$realm/clients/$(jq --raw-output .id <<<"$client")" @- >/dev/null
  [ "$(client_attribute "$client_id" "$backchannel_attribute")" = "$written_url" ] ||
    fail "the client $client_id did not keep the back-channel URL the cell wrote, so the next check proves nothing"
done <<<"$cleared_clients"
rerun_config_cli
second_failures="$(kubectl -n "$namespace" get job/config-cli -o jsonpath='{.status.failed}')"
[ -z "$second_failures" ] || fail "config-cli's second run failed $second_failures times before it completed"
after="$(fingerprint "$state_root/after")" || fail "the realms master and $realm cannot be read after config-cli's second run"
if [ "$after" != "$before" ]; then
  report_difference "$state_root/before" "$state_root/after" || true
  fail "config-cli's second run changed the realms master or $realm"
fi
echo "config-cli's second run completed at its first attempt and changed neither master nor $realm"
while IFS= read -r client_id; do
  [ -z "$(client_attribute "$client_id" "$backchannel_attribute")" ] ||
    fail "the client $client_id holds a back-channel URL after config-cli's run, though $REALM_FILE clears it"
done <<<"$cleared_clients"
while IFS=$'\t' read -r client_id url; do
  [ "$(client_attribute "$client_id" "$backchannel_attribute")" = "$url" ] ||
    fail "the client $client_id holds a back-channel URL other than the one $REALM_FILE states"
done <<<"$stated_urls"
echo "config-cli removed the back-channel URL of $(paste -sd, - <<<"$cleared_clients") and kept each stated URL as $REALM_FILE has it"

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
trap 'kill "$forward_pid" 2>/dev/null || true; rm -f -- "$admin_secret_file"; remove_target' EXIT
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
trap 'kill "$forward_pid" 2>/dev/null || true; rm -f -- "$admin_secret_file"' EXIT

# B6: a person's password grant waits for the terms; an administrator without TOTP gets no token at all.
probe_password="$(openssl rand -hex 24)"
mask_secret "$probe_password"
probe_client=b6-password-grant
probe_user=b6-person
admin POST "$realm/clients" "{\"clientId\": \"$probe_client\", \"publicClient\": true, \"directAccessGrantsEnabled\": true, \"standardFlowEnabled\": false}"
admin POST "$realm/users" "$(USER="$probe_user" PASSWORD="$probe_password" jq --null-input \
  '{username: env.USER, enabled: true, email: (env.USER + "@example.invalid"), emailVerified: true, firstName: "B6",
    lastName: "Person", requiredActions: ["TERMS_AND_CONDITIONS"],
    credentials: [{type: "password", value: env.PASSWORD, temporary: false}]}')"
probe_user_id="$(admin GET "$realm/users?exact=true&username=$probe_user" | jq --raw-output '.[0].id')"
# password_grant <realm> <client> <user> [<curl argument>...]: sets grant_status and grant_body.
password_grant() {
  local realm_name="$1" client="$2" user="$3"
  shift 3
  grant_body="$(curl --silent --show-error --write-out '\n%{http_code}' --data grant_type=password \
    --data-urlencode "client_id=$client" --data-urlencode "username=$user" --data-urlencode "password=$probe_password" \
    --data scope=openid "$@" "$local_url/realms/$realm_name/protocol/openid-connect/token")"
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
token_issuer="$(jwt_part 2 "$(jq --raw-output .access_token <<<"$grant_body")" | jq --raw-output .iss)"
[ "$token_issuer" = "$public_issuer" ] || fail "the person's token names the issuer '$token_issuer', not $public_issuer"
echo "with the terms accepted the password grant yields a token of the public issuer $token_issuer"
admin DELETE "$realm/users/$probe_user_id"
admin DELETE "$realm/clients/$(admin GET "$realm/clients?clientId=$probe_client" | jq --raw-output '.[0].id')"

# The positive control runs through the same client and master's own flow: an administrator with TOTP gets a token
# with the current code and none without it, and one without TOTP none at all. The secret's bytes are the HMAC key, as
# Keycloak reads an imported secret without an encoding, and the code follows RFC 6238 at the credential's algorithm,
# digits and period.
totp_admin=b6-admin
plain_admin=b6-admin-without-totp
totp_secret="$(openssl rand -hex 20)"
totp_period=30
totp_digits=6
admin POST master/partialImport "$(TOTP_USER="$totp_admin" PLAIN_USER="$plain_admin" PASSWORD="$probe_password" \
  SECRET="$totp_secret" PERIOD="$totp_period" DIGITS="$totp_digits" jq --null-input '
  def administrator($name; $second_factor): {username: $name, enabled: true, email: ($name + "@example.invalid"),
    emailVerified: true, firstName: "B6", lastName: "Admin",
    credentials: ([{type: "password", value: env.PASSWORD, temporary: false}] + $second_factor)};
  {ifResourceExists: "FAIL", users: [
    administrator(env.TOTP_USER; [{type: "otp", userLabel: "b6", secretData: ({value: env.SECRET} | tojson),
      credentialData: ({subType: "totp", algorithm: "HmacSHA1", digits: (env.DIGITS | tonumber),
        period: (env.PERIOD | tonumber), counter: 0} | tojson)}]),
    administrator(env.PLAIN_USER; [])]}')" >/dev/null
admin_role="$(admin GET master/roles/admin)"
admin_ids=()
for username in "$totp_admin" "$plain_admin"; do
  admin_ids+=("$(admin GET "master/users?exact=true&username=$username" | jq --raw-output '.[0].id')")
  admin POST "master/users/${admin_ids[-1]}/role-mappings/realm" "[$admin_role]"
done
totp_code() {
  TOTP_SECRET="$totp_secret" TOTP_PERIOD="$totp_period" TOTP_DIGITS="$totp_digits" python3 -I -c '
import hashlib, hmac, os, struct, time
counter = int(time.time()) // int(os.environ["TOTP_PERIOD"])
digest = hmac.new(os.environ["TOTP_SECRET"].encode(), struct.pack(">Q", counter), hashlib.sha1).digest()
offset = digest[-1] & 0x0F
digits = int(os.environ["TOTP_DIGITS"])
print(str((struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 10**digits).zfill(digits))'
}
# grant_outcome: the status, the OAuth error and whether a token came, never the token. Keycloak's deny-access step
# answers without JSON, which holds no token either.
grant_outcome() {
  echo "$grant_status $(jq --raw-output '(.error // "no-error") + " " + (if .access_token then "token" else "no-token" end)' \
    <<<"$grant_body" 2>/dev/null || echo "no-json no-token")"
}
password_grant master admin-cli "$totp_admin" --data-urlencode "totp=$(totp_code)"
with_code="$(grant_outcome)"
password_grant master admin-cli "$totp_admin"
without_code="$(grant_outcome)"
password_grant master admin-cli "$plain_admin"
without_totp="$(grant_outcome)"
for user_id in "${admin_ids[@]}"; do admin DELETE "master/users/$user_id"; done
[ "$with_code" = "200 no-error token" ] ||
  fail "a master administrator with TOTP got '$with_code' from admin-cli's password grant with the code, not 200 and a token"
[[ $without_code == "400 "*" no-token" ]] ||
  fail "a master administrator with TOTP got '$without_code' from admin-cli's password grant without the code, not 400 without a token"
[[ $without_totp == "401 "*" no-token" ]] ||
  fail "a master administrator without TOTP got '$without_totp' from admin-cli's password grant, not 401 without a token"
echo "through admin-cli and master's own flow a master administrator with TOTP gets 200 and a token with the code and" \
  "'$without_code' without it, and one without TOTP '$without_totp'"
