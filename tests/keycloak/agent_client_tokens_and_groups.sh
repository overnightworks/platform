#!/usr/bin/env bash
# agent_client_tokens_and_groups.sh: the agent client AGENT_CLIENT of REALM_FILE, as config-cli applied it. Its tokens
# carry exactly its rights, keycloak:agent-owner sets the person-linked facts and refuses everything else, a person
# cannot read or write agent_owner, and a switch-off in the console stops new tokens and survives a config-cli re-run.
# AGENT_GROUPS is the allowlist of the service account's rights, space-separated. Prints names, counts and outcomes,
# never a token or a secret; every throwaway user and client is deleted on every exit.
set -euo pipefail
umask 077
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
namespace="$KEYCLOAK_NAMESPACE"
client="$AGENT_CLIENT"
# shellcheck source=admin_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/admin_api.sh"

stand_in=p2-stand-in
other_owner=p2-other-owner
person_control=p2-person-control
password_client=p2-password-grant
scratch="$(mktemp -d "$RUNNER_TEMP/p2-cells.XXXXXX")"
password_file="$scratch/password"
client_secret_file="$scratch/client-secret"
remove_throwaways() {
  local username id
  for username in "$stand_in" "$other_owner" "$person_control"; do
    id="$(admin GET "$realm/users?exact=true&username=$username" | jq --raw-output '.[0].id // empty')" || id=""
    [ -z "$id" ] || admin DELETE "$realm/users/$id" || echo "::warning::the throwaway user $username was not deleted"
  done
  id="$(admin GET "$realm/clients?clientId=$password_client" | jq --raw-output '.[0].id // empty')" || id=""
  [ -z "$id" ] || admin DELETE "$realm/clients/$id" || echo "::warning::the throwaway client $password_client was not deleted"
  [ -z "${account_id:-}" ] || {
    admin GET "$realm/users/$account_id" | jq 'del(.attributes.agent_owner)' >"$scratch/body" &&
      admin PUT "$realm/users/$account_id" "@$scratch/body" >/dev/null
  } || echo "::warning::agent_owner of the service account was not cleared"
  rm -rf -- "$scratch"
  kill "$forward_pid" 2>/dev/null || true
}
trap remove_throwaways EXIT
trap 'exit 143' TERM INT

client_entry="$(CLIENT="$client" yq --output-format json '.clients[] | select(.clientId == strenv(CLIENT))' "$REALM_FILE")"
[ -n "$client_entry" ] || fail "$REALM_FILE declares no client $client"
hopin_audience="$(yq --exit-status '.clientScopes[] | select(.name == "mcp-hopin") | .protocolMappers[0].config."included.custom.audience"' "$REALM_FILE")"
lifespan="$(yq --exit-status '.accessTokenLifespan' "$REALM_FILE")"
agent_name="$(jq --raw-output '.protocolMappers[] | select(.name == "agent_name") | .config."claim.value"' <<<"$client_entry")"
sorted_list() { tr ' ' '\n' | grep . | LC_ALL=C sort; }
file_groups="$(USER="service-account-$client" yq '.users[] | select(.username == strenv(USER)) | .groups[]' "$REALM_FILE" | sorted_list)"
[ "$file_groups" = "$(sorted_list <<<"$AGENT_GROUPS")" ] ||
  fail "$REALM_FILE gives $client the groups '${file_groups//$'\n'/ }', not the allowlist '$AGENT_GROUPS'"

# The secret's name from the file and its Secret key from the Job that used it, read straight into a file.
secret_variable="$(yq '.secret' <<<"$client_entry" | sed 's/^$(env:\(.*\))$/\1/')"
secret_key="$(kubectl -n "$namespace" get job/config-cli -o json | NAME="$secret_variable" yq -p json \
  '.spec.template.spec.containers[0].env[] | select(.name == strenv(NAME)) | .valueFrom.secretKeyRef.key')"
kubectl -n "$namespace" get secret keycloak -o go-template="{{index .data \"$secret_key\" | base64decode}}" >"$client_secret_file"
openssl rand -hex 24 | tr -d '\n' >"$password_file"
echo "::add-mask::$(<"$client_secret_file")"
echo "::add-mask::$(<"$password_file")"

client_uuid="$(admin GET "$realm/clients?clientId=$client" | jq --raw-output '.[0].id')"
account_id="$(admin GET "$realm/clients/$client_uuid/service-account-user" | jq --raw-output .id)"
person_id() { admin GET "$realm/users?exact=true&username=$1" | jq --raw-output '.[0].id'; }
agent_owner() { admin GET "$realm/users/$account_id" | jq --raw-output '.attributes.agent_owner // [] | join(",")'; }
# people_in <group path>: the usernames of the group's members who are no service accounts, sorted.
people_in() {
  admin GET "$realm/groups/$(admin GET "$realm/group-by-path$1" | jq --raw-output .id)/members?max=1000" |
    jq --raw-output '.[] | select(.username | startswith("service-account-") | not) | .username' | LC_ALL=C sort
}
[ -z "$(people_in /agent-adders)$(people_in /agent-owners)" ] || fail "a person is in /agent-adders or /agent-owners before the command"
echo "before the command no person is in /agent-adders or /agent-owners"

# create_person <username> <attributes as JSON>: a person with the probe password, no required action and every profile
# field set; the body with the password goes through a file.
create_person() {
  jq --null-input --arg username "$1" --argjson attributes "$2" --rawfile password "$password_file" \
    '{username: $username, enabled: true, email: ($username + "@example.invalid"), emailVerified: true,
      firstName: "Probe", lastName: "Person", attributes: $attributes,
      credentials: [{type: "password", value: $password, temporary: false}]}' >"$scratch/body"
  admin POST "$realm/users" "@$scratch/body" >/dev/null
  rm -f -- "$scratch/body"
  # A create adds the realm's default actions whatever it names, so only an update clears the terms.
  admin PUT "$realm/users/$(person_id "$1")" '{"requiredActions": []}' >/dev/null
}
create_person "$stand_in" '{}'
create_person "$other_owner" '{}'
create_person "$person_control" '{"agent_owner": ["admin-set"]}'
admin POST "$realm/clients" "$(jq --null-input --arg id "$password_client" '{clientId: $id, publicClient: true,
  directAccessGrantsEnabled: true, standardFlowEnabled: false,
  defaultClientScopes: ["basic", "profile", "email", "roles", "groups"], optionalClientScopes: []}')" >/dev/null
stand_in_id="$(person_id "$stand_in")"

# The command through its real entry point.
owner_command() {
  command_status=0
  command_output="$(mise run keycloak:agent-owner "$@" 2>&1)" || command_status=$?
  printf '%s\n' "$command_output"
}
refused() {
  [ "$command_status" != 0 ] || fail "$1 was not refused"
  [ "$(agent_owner)" = "$2" ] || fail "$1 changed agent_owner"
  echo "$1 is refused and agent_owner stays"
}
owner_command "$client" p2-nobody
refused "an unknown username" ""
owner_command "$client" "service-account-$client"
refused "a service account as owner" ""
other_client="$(yq '[.clients[] | select(.serviceAccountsEnabled == true and ((.defaultClientScopes // []) | contains(["agent-identity"]) | not))][0].clientId' "$REALM_FILE")"
owner_command "$other_client" "$stand_in"
refused "the service-account client $other_client without agent-identity" ""
owner_command no-such-client "$stand_in"
refused "a client realm.yaml does not declare" ""

owner_command "$client" "$stand_in"
[ "$command_status" = 0 ] || fail "keycloak:agent-owner failed for $stand_in"
[ "$(agent_owner)" = "$stand_in_id" ] || fail "agent_owner does not name $stand_in"
[ "$(people_in /agent-owners)" = "$stand_in" ] || fail "/agent-owners does not hold exactly $stand_in"
[ -z "$(people_in /agent-adders)" ] || fail "/agent-adders gained a person without --adder"
echo "the command set agent_owner and /agent-owners; /agent-adders stayed empty"

owner_command "$client" "$stand_in"
[ "$command_status" = 0 ] && grep -q 'nothing changed' <<<"$command_output" || fail "a second run did not report nothing changed"
owner_command "$client" "$other_owner"
refused "another owner" "$stand_in_id"
[ "$(people_in /agent-owners)" = "$stand_in" ] || fail "the refused owner changed /agent-owners"

owner_command --adder "$client" "$stand_in"
[ "$command_status" = 0 ] || fail "keycloak:agent-owner --adder failed for $stand_in"
[ "$(people_in /agent-adders)" = "$stand_in" ] || fail "/agent-adders does not hold exactly $stand_in"
[ "$(people_in /agent-owners)" = "$stand_in" ] || fail "--adder changed /agent-owners"
echo "--adder added exactly $stand_in to /agent-adders; a second owner stays refused, a second run changes nothing"

token_endpoint="$local_url/realms/$realm/protocol/openid-connect/token"
# agent_token [<curl argument>...]: a client-credentials request with the secret from its file; sets token_status and
# token_body, neither ever printed.
agent_token() {
  local response
  response="$(curl --silent --show-error --write-out '\n%{http_code}' --data grant_type=client_credentials \
    --data-urlencode "client_id=$client" --data-urlencode "client_secret@$client_secret_file" "$@" "$token_endpoint")"
  token_status="${response##*$'\n'}"
  token_body="${response%$'\n'*}"
}
# person_token <username>: a person's password grant through the throwaway client; prints the access token.
person_token() {
  curl --silent --show-error --fail --data grant_type=password --data-urlencode "client_id=$password_client" \
    --data-urlencode "username=$1" --data-urlencode "password@$password_file" "$token_endpoint" | jq --raw-output .access_token
}
access_token() { jq --raw-output .access_token <<<"$token_body"; }

# R1, R3: the token's rights are exactly the file's list, its audience exactly hopin's /mcp, its life the realm's.
agent_token --data scope=mcp-hopin
[ "$token_status" = 200 ] || fail "the client-credentials grant with scope=mcp-hopin answered $token_status"
[ "$(jq 'has("refresh_token")' <<<"$token_body")" = false ] || fail "the token response carries a refresh token"
agent_access_token="$(access_token)"
header="$(jwt_part 1 "$agent_access_token")"
claims="$(jwt_part 2 "$agent_access_token")"
claim() { jq --raw-output "$1" <<<"$claims"; }
[ "$(jq --raw-output .typ <<<"$header")" = at+jwt ] || fail "the token's header typ is not at+jwt"
[ "$(claim '.groups | sort | join(" ")')" = "${file_groups//$'\n'/ }" ] ||
  fail "the token's groups are '$(claim '.groups | sort | join(" ")')', not the file's '${file_groups//$'\n'/ }'"
[ "$(claim 'if (.aud | type) == "string" then .aud else "not one string" end')" = "$hopin_audience" ] ||
  fail "the token's aud is '$(claim '.aud | tojson')', not exactly $hopin_audience"
[ "$(claim '.exp - .iat')" = "$lifespan" ] || fail "the token lives $(claim '.exp - .iat') s, not the realm's $lifespan s"
[ "$(claim .azp)" = "$client" ] || fail "the token's azp is not $client"
[ "$(claim .agent_name)" = "$agent_name" ] || fail "the token's agent_name is not $agent_name"
[ "$(claim .agent_owner)" = "$stand_in_id" ] || fail "the token's agent_owner is not the stand-in's id"
[ "$(claim .preferred_username)" = "service-account-$client" ] || fail "the token's preferred_username is not its username"
[ "$(claim 'has("realm_access") or has("resource_access")')" = false ] || fail "the token carries a realm or client role"
role_mappings="$(admin GET "$realm/users/$account_id/role-mappings")"
[ "$(jq --arg default "default-roles-$realm" '(.clientMappings // {} | length) == 0 and
  ([.realmMappings[]?.name] - [$default] | length) == 0' <<<"$role_mappings")" = true ] ||
  fail "the service account holds a role beyond default-roles-$realm"
live_attributes="$(admin GET "$realm/clients/$client_uuid" | jq --sort-keys '.attributes | {"use.refresh.tokens", "client_credentials.use_refresh_token"}')"
[ "$(jq --raw-output '[.[]] | unique | join(" ")' <<<"$live_attributes")" = false ] ||
  fail "the live client's refresh-token attributes are not both false"
echo "R1, R3: groups '${file_groups//$'\n'/ }', aud exactly $hopin_audience, no refresh token, $lifespan s, at+jwt, azp, agent_name, agent_owner, preferred_username, no role beyond the default"

agent_token
[ "$token_status" = 200 ] || fail "the client-credentials grant without scope answered $token_status"
[ "$(jwt_part 2 "$(access_token)" | jq --arg audience "$hopin_audience" \
  '(.aud // []) | (if type == "string" then [.] else . end) | index($audience) == null')" = true ] ||
  fail "a token without scope=mcp-hopin carries hopin's audience"
echo "R3: without scope=mcp-hopin the token has no hopin audience"

# R2: the agent's own token is refused at both APIs; a person meets the profile's read-only rule.
# The account path serves its web console unless a request asks for JSON.
http_status() { curl --silent --output "$scratch/answer" --write-out '%{http_code}' --header 'Accept: application/json' "$@"; }
attack='{"attributes": {"agent_owner": ["attacker"]}}'
account_status="$(http_status --request POST --header "Authorization: Bearer $agent_access_token" \
  --header 'Content-Type: application/json' --data "$attack" "$local_url/realms/$realm/account/")"
admin_status="$(http_status --request PUT --header "Authorization: Bearer $agent_access_token" \
  --header 'Content-Type: application/json' --data "$attack" "$local_url/admin/realms/$realm/users/$account_id")"
case "$account_status:$admin_status" in 401:401 | 401:403 | 403:401 | 403:403) ;;
  *) fail "the agent's own token got $account_status at the account API and $admin_status at the admin user PUT" ;;
esac
[ "$(agent_owner)" = "$stand_in_id" ] || fail "the agent's own token changed agent_owner"
echo "R2: the agent's own token gets $account_status at the account API and $admin_status at the admin user PUT; agent_owner stays"

control_token="$(person_token "$person_control")"
control_id="$(person_id "$person_control")"
account_body() { jq --null-input --arg username "$person_control" --arg first "$1" --argjson attributes "$2" \
  '{username: $username, email: ($username + "@example.invalid"), firstName: $first, lastName: "Person", attributes: $attributes}'; }
person_post() {
  http_status --request POST --header "Authorization: Bearer $control_token" --header 'Content-Type: application/json' \
    --data "$(account_body "$1" "$2")" "$local_url/realms/$realm/account/"
}
control_value() { admin GET "$realm/users/$control_id" | jq --raw-output '.attributes.agent_owner // [] | join(",")'; }
attacked="$(person_post Probe '{"agent_owner": ["attacker"]}')"
[ "$attacked" = 400 ] && [ "$(jq --raw-output .errorMessage "$scratch/answer")" = error-user-attribute-read-only ] ||
  fail "a person writing agent_owner got $attacked and '$(jq --raw-output .errorMessage "$scratch/answer" 2>/dev/null)', not 400 error-user-attribute-read-only"
[ "$(control_value)" = admin-set ] || fail "a refused write changed a person's agent_owner"
renamed="$(person_post Renamed '{}')"
[ "$renamed" = 204 ] || fail "changing only firstName answered $renamed, not 204"
[ "$(control_value)" = admin-set ] || fail "changing only firstName changed a person's agent_owner"
metadata="$(curl --silent --show-error --fail --header 'Accept: application/json' --header "Authorization: Bearer $control_token" \
  "$local_url/realms/$realm/account/?userProfileMetadata=true")"
[ "$(jq '([.userProfileMetadata.attributes[].name] | (index("email") != null and index("agent_owner") == null))
  and (.attributes.agent_owner == null)' <<<"$metadata")" = true ] ||
  fail "a person's account metadata lists agent_owner or lists no attributes"
echo "R2: a person writing agent_owner gets 400 error-user-attribute-read-only, firstName alone 204, the value stays and the metadata does not list it"

stand_in_groups="$(jwt_part 2 "$(person_token "$stand_in")" | jq --raw-output '.groups | sort | join(" ")')"
[ "$stand_in_groups" = "/agent-adders /agent-owners" ] || fail "the stand-in's own token carries '$stand_in_groups'"
echo "the stand-in's own token carries $stand_in_groups"

# R4, R5: a switch-off stops new tokens, and a file that re-enabled it would undo that on the next apply.
set_enabled() {
  admin GET "$1" | jq --argjson enabled "$2" '.enabled = $enabled' >"$scratch/enabled-body"
  admin PUT "$1" "@$scratch/enabled-body" >/dev/null
  rm -f -- "$scratch/enabled-body"
}
set_client_enabled() { set_enabled "$realm/clients/$client_uuid" "$1"; }
set_account_enabled() { set_enabled "$realm/users/$account_id" "$1"; }
grant_error() { jq --raw-output '.error // ""' <<<"$token_body"; }
set_client_enabled false
agent_token --data scope=mcp-hopin
[ "$token_status" = 401 ] && [ "$(grant_error)" = invalid_client ] ||
  fail "a disabled client got $token_status '$(grant_error)', not 401 invalid_client"
echo "R4: a disabled client gets 401 invalid_client"
set_client_enabled true
set_account_enabled false
agent_token --data scope=mcp-hopin
[ "$token_status" = 401 ] || fail "a disabled service account got $token_status, not 401"
echo "R5: a disabled service account gets 401"

set_client_enabled false
live_state() {
  jq --null-input --sort-keys --arg owner "$(agent_owner)" --arg people_adders "$(people_in /agent-adders)" \
    --arg people_owners "$(people_in /agent-owners)" --argjson client_enabled "$(admin GET "$realm/clients/$client_uuid" | jq .enabled)" \
    --argjson account_enabled "$(admin GET "$realm/users/$account_id" | jq .enabled)" \
    --argjson groups "$(admin GET "$realm/users/$account_id/groups" | jq --sort-keys '[.[].path] | sort')" \
    '{client_enabled: $client_enabled, account_enabled: $account_enabled, owner: $owner, groups: $groups,
      people_adders: $people_adders, people_owners: $people_owners}'
}
state_before="$(live_state)"
[ "$(jq '.client_enabled == false and .account_enabled == false' <<<"$state_before")" = true ] ||
  fail "the client and the service account are not both disabled before the re-run"
rerun_config_cli
state_after="$(live_state)"
[ "$state_after" = "$state_before" ] ||
  fail "config-cli's re-run changed the switch-off, the groups, agent_owner or the members: $state_after"
echo "with both left disabled a config-cli re-run keeps them disabled and keeps the service account's groups, agent_owner and both groups' members"
set_client_enabled true
set_account_enabled true
agent_token --data scope=mcp-hopin
[ "$token_status" = 200 ] || fail "after re-enabling, the grant answered $token_status, not 200"
echo "re-enabled, the grant answers 200"
