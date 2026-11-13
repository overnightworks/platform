#!/usr/bin/env bash
# hopin_exchanges_an_agent_token_for_the_speech_audience.sh: EXCHANGING_CLIENT of REALM_FILE, as config-cli applied it,
# trades the mcp-hopin token of the agent client AGENT_CLIENT for a token of its own with the scope EXCHANGE_SCOPE, and
# no other client, scope, subject, subject token or switch-off lets a token through, and a person's token at every client is
# what the base of BASE_REF gave. Prints names and outcomes, never a token or a secret; every throwaway user, client and
# realm is deleted on every exit.
set -euo pipefail
umask 077
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
namespace="$KEYCLOAK_NAMESPACE"
agent="$AGENT_CLIENT"
exchanger="$EXCHANGING_CLIENT"
refused_exchanger="$REFUSED_CLIENT"
base_ref="$BASE_REF"
exchange_scope="$EXCHANGE_SCOPE"
# shellcheck source=admin_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/admin_api.sh"

person=p2-exchange-person
password_client=p2-exchange-password
twin_client=p2-exchange-twin
base_realm=p2-exchange-base
scratch="$(mktemp -d "$RUNNER_TEMP/p2-exchange-cells.XXXXXX")"
password_file="$scratch/password"
agent_secret_file="$scratch/agent-secret"
exchanger_secret_file="$scratch/exchanger-secret"
refused_secret_file="$scratch/refused-secret"
subject_file="$scratch/subject-token"
# Admin paths of what the cell switches off or changes, set once they exist, so the exit restores them.
agent_path=""
account_path=""
exchanger_path=""
removed_membership_path=""
refused_exchanger_path=""
remove_throwaways() {
  local id
  id="$(admin GET "$realm/users?exact=true&username=$person" | jq --raw-output '.[0].id // empty')" || id=""
  [ -z "$id" ] || admin DELETE "$realm/users/$id" || echo "::warning::the throwaway user $person was not deleted"
  local throwaway_client
  for throwaway_client in "$password_client" "$twin_client"; do
    id="$(admin GET "$realm/clients?clientId=$throwaway_client" | jq --raw-output '.[0].id // empty')" || id=""
    [ -z "$id" ] || admin DELETE "$realm/clients/$id" || echo "::warning::the throwaway client $throwaway_client was not deleted"
  done
  if admin GET "$base_realm" >/dev/null 2>&1; then
    admin DELETE "$base_realm" || echo "::warning::the throwaway realm $base_realm was not deleted"
  fi
  # A switch-off left by a failing step must not outlive the cell.
  local switched_off
  for switched_off in "$agent_path" "$account_path" "$exchanger_path"; do
    [ -z "$switched_off" ] || set_enabled "$switched_off" true || echo "::warning::$switched_off was not re-enabled"
  done
  [ -z "$agent_path" ] || put_changed "$agent_path" '.attributes["access.token.lifespan"] = null' ||
    echo "::warning::the token lifespan of $agent was not restored"
  [ -z "$refused_exchanger_path" ] ||
    put_changed "$refused_exchanger_path" '.attributes["standard.token.exchange.enabled"] = null' ||
    echo "::warning::the exchange switch of $refused_exchanger was not restored"
  [ -z "$removed_membership_path" ] || admin PUT "$removed_membership_path" ||
    echo "::warning::$removed_membership_path was not restored"
  rm -rf -- "$scratch" "$admin_secret_file"
  kill "$forward_pid" 2>/dev/null || true
}
trap remove_throwaways EXIT
trap 'exit 143' TERM INT

speech_audience="$(yq --exit-status '.clientScopes[] | select(.name == "'"$exchange_scope"'") | .protocolMappers[].config."included.client.audience" | select(. != null)' "$REALM_FILE")"
speech_group="/services/$speech_audience"
exchange_enabled_in_file="$(yq '[.clients[] | select(.attributes."standard.token.exchange.enabled" == "true") | .clientId] | join(" ")' "$REALM_FILE")"
[ "$exchange_enabled_in_file" = "$exchanger" ] ||
  fail "$REALM_FILE enables the standard token exchange for '$exchange_enabled_in_file', not for $exchanger alone"
mcp_audience="$(yq --exit-status '.clientScopes[] | select(.name == "mcp-hopin") | .protocolMappers[]
  | select(.name == "mcp-hopin-audience") | .config."included.custom.audience"' "$REALM_FILE")"
file_groups="$(file_groups_of "service-account-$agent")"
for needed in /apps/hopin "$speech_group"; do
  grep -qxF "$needed" <<<"$file_groups" || fail "$REALM_FILE does not put the service account of $agent into $needed"
done
# The scopes the file offers the exchanging client, and every other scope it declares.
offered_scopes="$(CLIENT="$exchanger" yq '.clients[] | select(.clientId == strenv(CLIENT))
  | ((.defaultClientScopes // []) + (.optionalClientScopes // []))[]' "$REALM_FILE" | sorted_list)"
grep -qxF "$exchange_scope" <<<"$offered_scopes" || fail "$REALM_FILE does not offer $exchange_scope to $exchanger"
other_scopes="$(yq '.clientScopes[].name' "$REALM_FILE" | grep -vxFf <(printf '%s\n' "$offered_scopes"))" ||
  fail "$REALM_FILE declares no scope that $exchanger is not offered"

client_secret_to_file "$agent" "$agent_secret_file"
client_secret_to_file "$exchanger" "$exchanger_secret_file"
client_secret_to_file "$refused_exchanger" "$refused_secret_file"
openssl rand -hex 24 | tr -d '\n' >"$password_file"
mask_secret "$(<"$password_file")"

live_exchangers="$(admin GET "$realm/clients" |
  jq --raw-output '[.[] | select(.attributes["standard.token.exchange.enabled"] == "true") | .clientId] | sort | join(" ")')"
[ "$live_exchangers" = "$exchanger" ] || fail "the live realm lets '$live_exchangers' exchange, not $exchanger alone"
agent_path="$realm/clients/$(admin GET "$realm/clients?clientId=$agent" | jq --raw-output '.[0].id')"
account_path="$realm/users/$(admin GET "$agent_path/service-account-user" | jq --raw-output .id)"
exchanger_path="$realm/clients/$(admin GET "$realm/clients?clientId=$exchanger" | jq --raw-output '.[0].id')"
echo "the file and the live realm let $exchanger alone exchange a token"

token_endpoint="$local_url/realms/$realm/protocol/openid-connect/token"
# agent_token [<curl argument>...]: the agent's client-credentials token into subject_file; prints the status.
agent_token() {
  local status
  status="$(curl --silent --show-error --output "$scratch/answer" --write-out '%{http_code}' --data grant_type=client_credentials \
    --data-urlencode "client_id=$agent" --data-urlencode "client_secret@$agent_secret_file" "$@" "$token_endpoint")"
  [ "$status" != 200 ] || jq --raw-output .access_token "$scratch/answer" | tr -d '\n' >"$subject_file"
  echo "$status"
}
# exchange <client> <secret file> <subject token file> [<curl argument>...]: sets exchange_status and leaves the answer
# in $scratch/answer, neither ever printed.
exchange() {
  exchange_status="$(curl --silent --show-error --output "$scratch/answer" --write-out '%{http_code}' \
    --data grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    --data subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    --data-urlencode "client_id=$1" --data-urlencode "client_secret@$2" --data-urlencode "subject_token@$3" \
    "${@:4}" "$token_endpoint")"
}
exchange_error() { jq --raw-output '.error // ""' "$scratch/answer"; }
# expect_refusal <description> <status> <error>
expect_refusal() {
  [ "$exchange_status" = "$2" ] && [ "$(exchange_error)" = "$3" ] &&
    [ "$(jq 'has("access_token")' "$scratch/answer")" = false ] ||
    fail "$1 got $exchange_status '$(exchange_error)', not $2 $3"
  echo "$1 is refused with $2 $3"
}

# The exchange: the agent's own sub and groups, hopin's authorized party, the speech service as the only audience hopin's
# scope adds, an expiry at most a second after the subject token's.
[ "$(agent_token --data scope=mcp-hopin)" = 200 ] || fail "$agent's grant with scope=mcp-hopin was refused"
subject_claims="$(jwt_part 2 "$(<"$subject_file")")"
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
[ "$exchange_status" = 200 ] || fail "$exchanger's exchange of $agent's mcp-hopin token got $exchange_status '$(exchange_error)'"
[ "$(jq --raw-output '[.issued_token_type, .token_type, has("refresh_token")] | join(" ")' "$scratch/answer")" = \
  "urn:ietf:params:oauth:token-type:access_token Bearer false" ] ||
  fail "the exchange response is not a Bearer access token without a refresh token"
exchanged_claims="$(jwt_part 2 "$(jq --raw-output .access_token "$scratch/answer")")"
exchanged() { jq --raw-output "$1" <<<"$exchanged_claims"; }
[ "$(exchanged .azp)" = "$exchanger" ] || fail "the exchanged token's azp is not $exchanger"
[ "$(exchanged .sub)" = "$(jq --raw-output .sub <<<"$subject_claims")" ] || fail "the exchanged token's sub is not the agent's"
[ "$(exchanged '[.aud] | flatten | index("'"$speech_audience"'") != null')" = true ] ||
  fail "the exchanged token's aud does not hold $speech_audience"
[ "$(exchanged '[.aud] | flatten | index("'"$mcp_audience"'") == null')" = true ] ||
  fail "the exchanged token still names the MCP audience $mcp_audience"
[ "$(exchanged '.groups | sort | join(" ")')" = "${file_groups//$'\n'/ }" ] ||
  fail "the exchanged token's groups are '$(exchanged '.groups | sort | join(" ")')', not the file's '${file_groups//$'\n'/ }'"
expiry_gap="$(jq --null-input --argjson exchanged "$exchanged_claims" --argjson subject "$subject_claims" '$exchanged.exp - $subject.exp')"
[ "$expiry_gap" -le 1 ] || fail "the exchanged token outlives the subject token by $expiry_gap s"
echo "$exchanger's exchange of $agent's mcp-hopin token with scope=$exchange_scope: azp $exchanger, the agent's sub, aud $speech_audience, groups '${file_groups//$'\n'/ }', expiry at most 1 s after the subject's"

# The refusals.
exchange "$refused_exchanger" "$refused_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "$refused_exchanger's exchange of the same token" 400 invalid_request
# With the exchange switched on for it, the client still names no hopin audience, which is the issuer's own refusal.
refused_exchanger_path="$realm/clients/$(admin GET "$realm/clients?clientId=$refused_exchanger" | jq --raw-output '.[0].id')"
put_changed "$refused_exchanger_path" '.attributes["standard.token.exchange.enabled"] = "true"'
exchange "$refused_exchanger" "$refused_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "$refused_exchanger's exchange of the same token with its exchange switched on" 403 access_denied
put_changed "$refused_exchanger_path" '.attributes["standard.token.exchange.enabled"] = null'
refused_exchanger_path=""
for other_scope in $other_scopes; do
  exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$other_scope"
  expect_refusal "$exchanger's exchange for the scope $other_scope, which the file does not offer it" 400 invalid_scope
done
# A token that was altered, or that has run out, is no subject either.
tamper_signature() {
  local token signature first
  token="$(<"$1")"
  signature="${token##*.}"
  first="${signature:0:1}"
  printf '%s.%s%s' "${token%.*}" "$([ "$first" = A ] && echo B || echo A)" "${signature:1}"
}
[ "$(agent_token --data scope=mcp-hopin)" = 200 ] || fail "$agent's grant with scope=mcp-hopin was refused"
tamper_signature "$subject_file" >"$scratch/tampered-token"
exchange "$exchanger" "$exchanger_secret_file" "$scratch/tampered-token" --data "scope=$exchange_scope"
expect_refusal "the exchange of a token with a changed signature" 400 invalid_request
# A negative lifespan puts the token's expiry in the past when it is minted.
put_changed "$agent_path" '.attributes["access.token.lifespan"] = "-5"'
[ "$(agent_token --data scope=mcp-hopin)" = 200 ] || fail "$agent's grant with a lifespan of -5 s was refused"
put_changed "$agent_path" '.attributes["access.token.lifespan"] = null'
[ "$(jwt_part 2 "$(<"$subject_file")" | jq '.exp < now')" = true ] || fail "the token minted with a lifespan of -5 s is not expired"
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "the exchange of an expired token" 400 invalid_request
[ "$(agent_token)" = 200 ] || fail "$agent's grant without a scope was refused"
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "the exchange of $agent's token asked without mcp-hopin" 403 access_denied

# A person's token holds no hopin audience, so it is not exchangeable either. Keycloak grants no role or scope for the
# speech group, so a person's token is the same in and out of it at every client: the speech service decides by the group.
create_person_body() {
  jq --null-input --arg username "$person" --rawfile password "$password_file" \
    '{username: $username, enabled: true, email: ($username + "@example.invalid"), emailVerified: true,
      firstName: "Probe", lastName: "Person", credentials: [{type: "password", value: $password, temporary: false}]}'
}
# add_member <realm>: the throwaway person in the realm and in the speech group; sets person_id, group_id and
# person_membership_path.
add_member() {
  create_person_body >"$scratch/body"
  admin POST "$1/users" "@$scratch/body" >/dev/null
  rm -f -- "$scratch/body"
  # A create adds the realm's default actions whatever it names, so only an update clears the terms.
  person_id="$(admin GET "$1/users?exact=true&username=$person" | jq --raw-output '.[0].id')"
  admin PUT "$1/users/$person_id" '{"requiredActions": []}' >/dev/null
  group_id="$(admin GET "$1/group-by-path$speech_group" | jq --raw-output .id)"
  person_membership_path="$1/users/$person_id/groups/$group_id"
  admin PUT "$person_membership_path" >/dev/null
}
add_member "$realm"
# The throwaway client has the scopes presentator signs a person in with that matter here: the roles scope, and the speech
# audience as an optional one.
admin POST "$realm/clients" "$(jq --null-input --arg id "$password_client" --arg scope "$exchange_scope" '{clientId: $id,
  publicClient: true, directAccessGrantsEnabled: true, standardFlowEnabled: false,
  defaultClientScopes: ["basic", "profile", "email", "roles", "groups"], optionalClientScopes: [$scope]}')" >/dev/null
# person_claims_at <token endpoint> <client> <curl argument>...: a person's password grant at the client; the access token
# goes to person-token, the claims to stdout.
person_claims_at() {
  local endpoint="$1" client="$2"
  shift 2
  curl --silent --show-error --fail --output "$scratch/person-answer" --data grant_type=password \
    --data-urlencode "client_id=$client" --data-urlencode "username=$person" --data-urlencode "password@$password_file" \
    "$@" "$endpoint" || return
  jq --raw-output .access_token "$scratch/person-answer" | tr -d '\n' >"$scratch/person-token"
  jwt_part 2 "$(<"$scratch/person-token")"
}
person_claims() { person_claims_at "$token_endpoint" "$password_client" "$@"; }
# audience_and_roles <claims> [<audience to leave out>]: the claims a role or a scope would change, as the speech group
# must not. A realm's default role carries the realm's name, which the base's realm does not share.
audience_and_roles() {
  jq --compact-output --arg left_out "${2:-}" 'def roles: if . == null then null
      else .roles |= (map(if startswith("default-roles-") then "default-roles" else . end) | sort) end;
    {aud: (([.aud] | flatten | sort) - [$left_out]), realm_access: (.realm_access | roles),
     resource_access: ((.resource_access // {}) | map_values(roles))}' <<<"$1"
}
member_claims="$(person_claims)"
[ "$(jq '[.aud] | flatten | index("'"$exchanger"'") == null' <<<"$member_claims")" = true ] ||
  fail "a person's token names $exchanger in its audience"
[ "$(jq --arg audience "$speech_audience" '([.aud] | flatten | index($audience)) == null and ((.resource_access // {}) | has($audience) | not)' \
  <<<"$member_claims")" = true ] || fail "the token of a member of $speech_group names $speech_audience without asking for it"
exchange "$exchanger" "$exchanger_secret_file" "$scratch/person-token" --data "scope=$exchange_scope"
expect_refusal "the exchange of a person's token" 403 access_denied
member_scoped_claims="$(person_claims --data "scope=$exchange_scope")"
[ "$(jq --arg audience "$speech_audience" '[.aud] | flatten | index($audience) != null' <<<"$member_scoped_claims")" = true ] ||
  fail "a person's sign-in with scope=$exchange_scope does not name $speech_audience"
admin DELETE "$person_membership_path"
[ "$(audience_and_roles "$member_claims")" = "$(audience_and_roles "$(person_claims)")" ] ||
  fail "the audiences or roles of a person's sign-in depend on $speech_group"
[ "$(audience_and_roles "$member_scoped_claims")" = "$(audience_and_roles "$(person_claims --data "scope=$exchange_scope")")" ] ||
  fail "the audiences or roles of a person's sign-in with scope=$exchange_scope depend on $speech_group"
echo "a person's audiences and roles are the same in and out of $speech_group, with and without scope=$exchange_scope"

# The exchanged token names the speech service's group only while the principal is in it, which is all the realm adds: the
# service decides by the group.
removed_membership_path="$account_path/groups/$group_id"
admin DELETE "$removed_membership_path"
[ "$(agent_token --data scope=mcp-hopin)" = 200 ] || fail "$agent's grant outside $speech_group was refused"
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
[ "$exchange_status" = 200 ] || fail "the exchange of $agent's token outside $speech_group got $exchange_status '$(exchange_error)'"
[ "$(jwt_part 2 "$(jq --raw-output .access_token "$scratch/answer")" | jq --arg group "$speech_group" '.groups | index($group) == null')" = true ] ||
  fail "the exchanged token names $speech_group though $agent is not in it"
admin PUT "$removed_membership_path"
removed_membership_path=""
echo "the exchanged token names $speech_group only while $agent is in it"

# A switch-off of the exchanging client, the agent client or its service account stops the exchange of a token minted
# before.
[ "$(agent_token --data scope=mcp-hopin)" = 200 ] || fail "$agent's grant with scope=mcp-hopin was refused"
while IFS='|' read -r switched_off description status error; do
  set_enabled "${!switched_off}" false
  exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
  expect_refusal "$description" "$status" "$error"
  set_enabled "${!switched_off}" true
done < <(printf '%s|%s|%s|%s\n' \
  exchanger_path "a disabled $exchanger's exchange" 401 invalid_client \
  agent_path "the exchange of a token of the disabled $agent" 400 invalid_request \
  account_path "the exchange of a token of $agent's disabled service account" 400 invalid_request)
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
[ "$exchange_status" = 200 ] || fail "after re-enabling, $exchanger's exchange got $exchange_status '$(exchange_error)'"
echo "re-enabled, $exchanger's exchange answers 200"

# A person's token at every client, with no scope and with each optional scope, is what the base gave: the same
# audiences, realm roles and client roles, but for the audience the exchange adds to mcp-hopin. The base is the realm
# file at the merge base with BASE_REF, imported as a throwaway realm with the scopes Keycloak ships and the file does not
# declare, which an import that names client scopes does not create; a client is compared through a twin of its
# representation that takes the password grant.
git show "$(git merge-base HEAD "$base_ref"):$REALM_FILE" >"$scratch/base-realm.yaml"
shipped_scopes="$(admin GET "$realm/client-scopes" | jq --argjson declared "$(yq --output-format json '[.clientScopes[].name]' "$scratch/base-realm.yaml")" \
  '[.[] | select(.name as $name | $declared | index($name) | not) | del(.id) | del(.protocolMappers[]?.id)]')"
BASE_REALM="$base_realm" yq --output-format json '.realm = strenv(BASE_REALM) | del(.users) | del(.userProfile)
  | (.clients[] | select(has("secret")) | .secret) = "unused"' "$scratch/base-realm.yaml" |
  jq --argjson shipped "$shipped_scopes" '.clientScopes += $shipped' >"$scratch/base-realm.json"
admin POST "" "@$scratch/base-realm.json" >/dev/null
add_member "$base_realm"
base_token_endpoint="$local_url/realms/$base_realm/protocol/openid-connect/token"
# add_twin <realm> <realm file> <client>: the client as the file states it, under the twin's id, public, with the password
# grant and without what a password grant never reads or refuses.
add_twin() {
  TWIN="$twin_client" CLIENT="$3" yq --output-format json '.clients[] | select(.clientId == strenv(CLIENT))
    | .clientId = strenv(TWIN) | .publicClient = true | .directAccessGrantsEnabled = true | .standardFlowEnabled = false
    | .serviceAccountsEnabled = false | .consentRequired = false | del(.secret) | del(.attributes["standard.token.exchange.enabled"])' "$2" >"$scratch/body"
  admin POST "$1/clients" "@$scratch/body" >/dev/null
  rm -f -- "$scratch/body"
}
# remove_twin <realm>
remove_twin() { admin DELETE "$1/clients/$(admin GET "$1/clients?clientId=$twin_client" | jq --raw-output '.[0].id')"; }
for compared in $(yq '.clients[] | select(.bearerOnly != true) | .clientId' "$REALM_FILE"); do
  add_twin "$realm" "$REALM_FILE" "$compared"
  add_twin "$base_realm" "$scratch/base-realm.yaml" "$compared"
  compared_scopes="$(CLIENT="$compared" yq '.clients[] | select(.clientId == strenv(CLIENT)) | (.optionalClientScopes // []) | join(" ")' "$REALM_FILE")"
  for scope in "" $compared_scopes; do
    scope_arguments=()
    [ -z "$scope" ] || scope_arguments=(--data "scope=$scope")
    left_out=""
    [ "$scope" != mcp-hopin ] || left_out="$exchanger"
    candidate_claims="$(person_claims_at "$token_endpoint" "$twin_client" "${scope_arguments[@]}")"
    base_claims="$(person_claims_at "$base_token_endpoint" "$twin_client" "${scope_arguments[@]}")"
    [ "$(audience_and_roles "$candidate_claims" "$left_out")" = "$(audience_and_roles "$base_claims" "$left_out")" ] ||
      fail "the audiences or roles of a person's sign-in at $compared with scope '$scope' are $(audience_and_roles "$candidate_claims" "$left_out"), not the base's $(audience_and_roles "$base_claims" "$left_out")"
  done
  remove_twin "$realm"
  remove_twin "$base_realm"
  echo "a person's audiences and roles at $compared with no scope and with '$compared_scopes' equal the base's"
done
