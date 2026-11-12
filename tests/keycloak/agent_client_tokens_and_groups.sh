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

# A person whose username starts like a service account's: the command must take it as the person it is.
stand_in=service-account-p2-stand-in
other_owner=p2-other-owner
person_control=p2-person-control
password_client=p2-password-grant
undeclared_client=p2-undeclared
extra_group=p2-extra-group
scratch="$(mktemp -d "$RUNNER_TEMP/p2-cells.XXXXXX")"
password_file="$scratch/password"
client_secret_file="$scratch/client-secret"
remove_throwaways() {
  local username id throwaway_client
  for username in "$stand_in" "$other_owner" "$person_control"; do
    id="$(admin GET "$realm/users?exact=true&username=$username" | jq --raw-output '.[0].id // empty')" || id=""
    [ -z "$id" ] || admin DELETE "$realm/users/$id" || echo "::warning::the throwaway user $username was not deleted"
  done
  for throwaway_client in "$password_client" "$undeclared_client"; do
    id="$(admin GET "$realm/clients?clientId=$throwaway_client" | jq --raw-output '.[0].id // empty')" || id=""
    [ -z "$id" ] || admin DELETE "$realm/clients/$id" || echo "::warning::the throwaway client $throwaway_client was not deleted"
  done
  [ -z "${account_id:-}" ] || {
    admin GET "$realm/users/$account_id" | jq 'del(.attributes.agent_owner)' >"$scratch/body" &&
      admin PUT "$realm/users/$account_id" "@$scratch/body" >/dev/null
  } || echo "::warning::agent_owner of the service account was not cleared"
  [ -z "${extra_group_id:-}" ] || admin DELETE "$realm/groups/$extra_group_id" ||
    echo "::warning::the throwaway group $extra_group was not deleted"
  rm -rf -- "$scratch" "$admin_secret_file"
  kill "$forward_pid" 2>/dev/null || true
}
trap remove_throwaways EXIT
trap 'exit 143' TERM INT

client_entry="$(CLIENT="$client" yq --output-format json '.clients[] | select(.clientId == strenv(CLIENT))' "$REALM_FILE")"
[ -n "$client_entry" ] || fail "$REALM_FILE declares no client $client"
lifespan="$(yq --exit-status '.accessTokenLifespan' "$REALM_FILE")"
agent_name="$(jq --raw-output '.protocolMappers[] | select(.name == "agent_name") | .config."claim.value"' <<<"$client_entry")"
sorted_list() { tr ' ' '\n' | grep . | LC_ALL=C sort; }
# mcp_hopin_audiences: the audiences of the scope mcp-hopin, each mapper read by its name, sorted.
mcp_hopin_audiences="$(yq --exit-status '[.clientScopes[] | select(.name == "mcp-hopin") | .protocolMappers[]
  | select(.name == "mcp-hopin-audience" or .name == "mcp-hopin-exchange-audience")
  | .config."included.custom.audience" // .config."included.client.audience"] | .[]' "$REALM_FILE" | sorted_list)"
[ "$(wc -l <<<"$mcp_hopin_audiences")" = 2 ] || fail "$REALM_FILE gives mcp-hopin '${mcp_hopin_audiences//$'\n'/ }', not two audiences"
file_groups="$(USER="service-account-$client" yq '.users[] | select(.username == strenv(USER)) | .groups[]' "$REALM_FILE" | sorted_list)"
[ "$file_groups" = "$(sorted_list <<<"$AGENT_GROUPS")" ] ||
  fail "$REALM_FILE gives $client the groups '${file_groups//$'\n'/ }', not the allowlist '$AGENT_GROUPS'"

client_secret_to_file "$client" "$client_secret_file"
openssl rand -hex 24 | tr -d '\n' >"$password_file"
mask_secret "$(<"$password_file")"

client_uuid="$(admin GET "$realm/clients?clientId=$client" | jq --raw-output '.[0].id')"
account_id="$(admin GET "$realm/clients/$client_uuid/service-account-user" | jq --raw-output .id)"
person_id() { admin GET "$realm/users?exact=true&username=$1" | jq --raw-output '.[0].id'; }
agent_owner() { admin GET "$realm/users/$account_id" | jq --raw-output '.attributes.agent_owner // [] | join(",")'; }
# members_of <group path>: the usernames of all members, sorted, space-separated.
members_of() {
  admin GET "$realm/groups/$(admin GET "$realm/group-by-path$1" | jq --raw-output .id)/members?max=1000" |
    jq --raw-output '[.[].username] | sort | join(" ")'
}
# sorted_words <word>...: the words in the order members_of prints.
sorted_words() { printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
# Every service account the file puts into /agent-owners: the agents' own, which the command leaves as it finds them.
mapfile -t agent_accounts < <(yq '.users[] | select((.groups // []) | contains(["/agent-owners"])) | .username' "$REALM_FILE")
agent_owners_before="$(sorted_words "${agent_accounts[@]}")"
[ -z "$(members_of /agent-adders)" ] || fail "/agent-adders has members before the command"
[ "$(members_of /agent-owners)" = "$agent_owners_before" ] ||
  fail "/agent-owners holds '$(members_of /agent-owners)', not exactly '$agent_owners_before', before the command"
echo "before the command /agent-adders is empty and /agent-owners holds $agent_owners_before alone"

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
# A confidential client with a service account and agent-identity, which only the declaration check can refuse.
admin POST "$realm/clients" "$(jq --null-input --arg id "$undeclared_client" '{clientId: $id, publicClient: false,
  serviceAccountsEnabled: true, standardFlowEnabled: false, directAccessGrantsEnabled: false,
  defaultClientScopes: ["basic", "agent-identity"], optionalClientScopes: []}')" >/dev/null
undeclared_uuid="$(admin GET "$realm/clients?clientId=$undeclared_client" | jq --raw-output '.[0].id')"
undeclared_account_before="$(admin GET "$realm/clients/$undeclared_uuid/service-account-user" | jq --sort-keys .)"
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
owner_command "$client" "SERVICE-ACCOUNT-${client^^}"
refused "a service account as owner, in upper case" ""
other_client="$(yq '[.clients[] | select(.serviceAccountsEnabled == true and ((.defaultClientScopes // []) | contains(["agent-identity"]) | not))][0].clientId' "$REALM_FILE")"
owner_command "$other_client" "$stand_in"
refused "the service-account client $other_client without agent-identity" ""
owner_command "$undeclared_client" "$stand_in"
refused "the service-account client $undeclared_client, which exists in Keycloak with agent-identity but realm.yaml does not declare" ""
[ "$(admin GET "$realm/clients/$undeclared_uuid/service-account-user" | jq --sort-keys .)" = "$undeclared_account_before" ] ||
  fail "the refused undeclared client's service account changed"

owner_command "$client" "$stand_in"
[ "$command_status" = 0 ] || fail "keycloak:agent-owner failed for $stand_in"
[ "$(agent_owner)" = "$stand_in_id" ] || fail "agent_owner does not name $stand_in"
[ "$(members_of /agent-owners)" = "$(sorted_words "${agent_accounts[@]}" "$stand_in")" ] ||
  fail "/agent-owners holds '$(members_of /agent-owners)', not exactly $agent_owners_before and $stand_in"
[ -z "$(members_of /agent-adders)" ] || fail "/agent-adders gained a member without --adder"
echo "the command set agent_owner and /agent-owners to $agent_owners_before and $stand_in; /agent-adders stayed empty"

owner_command "$client" "$stand_in"
[ "$command_status" = 0 ] && grep -q 'nothing changed' <<<"$command_output" || fail "a second run did not report nothing changed"
owner_command "$client" "$other_owner"
refused "another owner" "$stand_in_id"
[ "$(members_of /agent-owners)" = "$(sorted_words "${agent_accounts[@]}" "$stand_in")" ] || fail "the refused owner changed /agent-owners"

owner_command --adder "$client" "$stand_in"
[ "$command_status" = 0 ] || fail "keycloak:agent-owner --adder failed for $stand_in"
[ "$(members_of /agent-adders)" = "$stand_in" ] || fail "/agent-adders does not hold exactly $stand_in"
[ "$(members_of /agent-owners)" = "$(sorted_words "${agent_accounts[@]}" "$stand_in")" ] || fail "--adder changed /agent-owners"
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

# expected_scope <extra scope>...: the scope claim lists the requested optional scopes and each default scope whose
# definition puts it into the claim.
expected_scope() {
  admin GET "$realm/client-scopes" | jq --raw-output --argjson defaults "$(jq .defaultClientScopes <<<"$client_entry")" \
    '($defaults + $ARGS.positional) as $wanted
      | [.[] | select(.name as $name | $wanted | index($name)) | select(.attributes["include.in.token.scope"] == "true") | .name]
      | sort | join(" ")' --args "$@"
}

# R1, R3: the token's rights are exactly the file's list, its audiences exactly hopin's /mcp and hopin, its life the realm's.
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
[ "$(claim '[.aud] | flatten | sort | join(" ")')" = "${mcp_hopin_audiences//$'\n'/ }" ] ||
  fail "the token's aud is '$(claim '.aud | tojson')', not exactly ${mcp_hopin_audiences//$'\n'/ }"
[ "$(claim '.exp - .iat')" = "$lifespan" ] || fail "the token lives $(claim '.exp - .iat') s, not the realm's $lifespan s"
[ "$(claim '.scope | split(" ") | sort | join(" ")')" = "$(expected_scope mcp-hopin)" ] ||
  fail "the token's scope is '$(claim .scope)', not the scopes of the client's defaults and mcp-hopin that go into a token: $(expected_scope mcp-hopin)"
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
live_client="$(admin GET "$realm/clients/$client_uuid")"
[ "$(jq '[.standardFlowEnabled, .implicitFlowEnabled, .directAccessGrantsEnabled] | unique == [false]' <<<"$live_client")" = true ] ||
  fail "the live client has its standard, implicit or direct-access flow on"
password_grant_status="$(curl --silent --output "$scratch/answer" --write-out '%{http_code}' --data grant_type=password \
  --data-urlencode "client_id=$client" --data-urlencode "client_secret@$client_secret_file" \
  --data-urlencode "username=$stand_in" --data-urlencode "password@$password_file" "$token_endpoint")"
[ "$password_grant_status" = 400 ] && [ "$(jq --raw-output .error "$scratch/answer")" = unauthorized_client ] ||
  fail "a password grant through $client answered $password_grant_status, not 400 unauthorized_client"
echo "R1, R3: groups '${file_groups//$'\n'/ }', aud exactly ${mcp_hopin_audiences//$'\n'/ }, no refresh token, $lifespan s, at+jwt, azp, agent_name, agent_owner, preferred_username, no role beyond the default"

agent_token
[ "$token_status" = 200 ] || fail "the client-credentials grant without scope answered $token_status"
no_scope_claims="$(jwt_part 2 "$(access_token)")"
[ "$(jq --compact-output '(.aud // []) | if type == "string" then [.] else . end' <<<"$no_scope_claims")" = '[]' ] ||
  fail "a token without scope=mcp-hopin carries the audience $(jq --compact-output '.aud' <<<"$no_scope_claims")"
[ "$(jq --raw-output '.scope | split(" ") | sort | join(" ")' <<<"$no_scope_claims")" = "$(expected_scope)" ] ||
  fail "a token without scope=mcp-hopin carries the scope '$(jq --raw-output .scope <<<"$no_scope_claims")', not '$(expected_scope)'"
echo "R3: without scope=mcp-hopin the token has no audience and exactly the default scopes that go into a token"

# R2: the agent's own token is refused at both APIs; a person meets the profile's read-only rule.
# The account path serves its web console unless a request asks for JSON.
# http_status <token> <curl argument>...: the status of a JSON request that carries the token; the body goes to a file.
http_status() { bearer_curl "$1" --silent --output "$scratch/answer" --write-out '%{http_code}' --header 'Accept: application/json' "${@:2}"; }
attack='{"attributes": {"agent_owner": ["attacker"]}}'
account_status="$(http_status "$agent_access_token" --request POST \
  --header 'Content-Type: application/json' --data "$attack" "$local_url/realms/$realm/account/")"
admin_status="$(http_status "$agent_access_token" --request PUT \
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
  http_status "$control_token" --request POST --header 'Content-Type: application/json' \
    --data "$(account_body "$1" "$2")" "$local_url/realms/$realm/account/"
}
control_value() { admin GET "$realm/users/$control_id" | jq --raw-output '.attributes.agent_owner // [] | join(",")'; }
attacked="$(person_post Probe '{"agent_owner": ["attacker"]}')"
[ "$attacked" = 400 ] && [ "$(jq --raw-output .errorMessage "$scratch/answer")" = error-user-attribute-read-only ] ||
  fail "a person writing agent_owner got $attacked and '$(jq --raw-output .errorMessage "$scratch/answer" 2>/dev/null)', not 400 error-user-attribute-read-only"
[ "$(control_value)" = admin-set ] || fail "a refused write changed a person's agent_owner"
renamed="$(person_post Renamed '{}')"
[ "$renamed" = 204 ] || fail "changing only firstName answered $renamed, not 204"
[ "$(admin GET "$realm/users/$control_id" | jq --raw-output .firstName)" = Renamed ] || fail "changing only firstName did not change it"
[ "$(control_value)" = admin-set ] || fail "changing only firstName changed a person's agent_owner"
metadata="$(bearer_curl "$control_token" --silent --show-error --fail --header 'Accept: application/json' \
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
# service_account_memberships: each service account's username and its group paths, so a re-run that touches any
# account shows.
service_account_memberships() {
  local client_each account_each
  for client_each in $(admin GET "$realm/clients" | jq --raw-output '.[] | select(.serviceAccountsEnabled == true) | .id'); do
    account_each="$(admin GET "$realm/clients/$client_each/service-account-user" | jq --raw-output .id)"
    jq --null-input --arg username "$(admin GET "$realm/users/$account_each" | jq --raw-output .username)" \
      --argjson paths "$(admin GET "$realm/users/$account_each/groups" | jq '[.[].path] | sort')" '{($username): $paths}'
  done | jq --slurp --sort-keys 'add'
}
live_state() {
  jq --null-input --sort-keys --arg owner "$(agent_owner)" --arg members_adders "$(members_of /agent-adders)" \
    --arg members_owners "$(members_of /agent-owners)" --argjson client_enabled "$(admin GET "$realm/clients/$client_uuid" | jq .enabled)" \
    --argjson account_enabled "$(admin GET "$realm/users/$account_id" | jq .enabled)" \
    --argjson service_accounts "$(service_account_memberships)" \
    '{client_enabled: $client_enabled, account_enabled: $account_enabled, owner: $owner,
      service_accounts: $service_accounts, members_adders: $members_adders, members_owners: $members_owners}'
}
# A group only the console holds, on the agent's service account: config-cli must leave it.
admin POST "$realm/groups" "{\"name\": \"$extra_group\"}" >/dev/null
extra_group_id="$(admin GET "$realm/group-by-path/$extra_group" | jq --raw-output .id)"
admin PUT "$realm/users/$account_id/groups/$extra_group_id" >/dev/null
state_before="$(live_state)"
[ "$(jq '.client_enabled == false and .account_enabled == false' <<<"$state_before")" = true ] ||
  fail "the client and the service account are not both disabled before the re-run"
rerun_config_cli
state_after="$(live_state)"
[ "$state_after" = "$state_before" ] ||
  fail "config-cli's re-run changed the switch-off, the groups, agent_owner or the members: $state_after"
[ "$(admin GET "$realm/users/$account_id/groups" | jq --arg path "/$extra_group" '[.[].path] | index($path) != null')" = true ] ||
  fail "config-cli's re-run removed the group only the console had given the service account"
echo "with both left disabled a config-cli re-run keeps them disabled and keeps every service account's groups, an extra group of the agent's, agent_owner and both groups' members"
set_client_enabled true
set_account_enabled true
agent_token --data scope=mcp-hopin
[ "$token_status" = 200 ] || fail "after re-enabling, the grant answered $token_status, not 200"
echo "re-enabled, the grant answers 200"
