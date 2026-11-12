#!/usr/bin/env bash
# hopin_exchanges_an_agent_token_for_the_speech_audience.sh: EXCHANGING_CLIENT of REALM_FILE, as config-cli applied it,
# trades the mcp-hopin token of the agent client AGENT_CLIENT for a token of its own with the scope EXCHANGE_SCOPE, and
# no other client, scope, subject, subject token or switch-off lets a token through. Prints names and outcomes, never a token or a
# secret; every throwaway user and client is deleted on every exit.
set -euo pipefail
umask 077
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
namespace="$KEYCLOAK_NAMESPACE"
agent="$AGENT_CLIENT"
exchanger="$EXCHANGING_CLIENT"
refused_exchanger="$REFUSED_CLIENT"
exchange_scope="$EXCHANGE_SCOPE"
# shellcheck source=admin_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/admin_api.sh"

person=p2-exchange-person
password_client=p2-exchange-password
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
remove_throwaways() {
  local id
  id="$(admin GET "$realm/users?exact=true&username=$person" | jq --raw-output '.[0].id // empty')" || id=""
  [ -z "$id" ] || admin DELETE "$realm/users/$id" || echo "::warning::the throwaway user $person was not deleted"
  id="$(admin GET "$realm/clients?clientId=$password_client" | jq --raw-output '.[0].id // empty')" || id=""
  [ -z "$id" ] || admin DELETE "$realm/clients/$id" || echo "::warning::the throwaway client $password_client was not deleted"
  # A switch-off left by a failing step must not outlive the cell.
  local switched_off
  for switched_off in "$agent_path" "$account_path" "$exchanger_path"; do
    [ -z "$switched_off" ] || set_enabled "$switched_off" true || echo "::warning::$switched_off was not re-enabled"
  done
  [ -z "$agent_path" ] || put_changed "$agent_path" '.attributes["access.token.lifespan"] = null' ||
    echo "::warning::the token lifespan of $agent was not restored"
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
put_changed "$agent_path" '.attributes["access.token.lifespan"] = "2"'
[ "$(agent_token --data scope=mcp-hopin)" = 200 ] || fail "$agent's grant with a lifespan of 2 s was refused"
put_changed "$agent_path" '.attributes["access.token.lifespan"] = null'
expired_at="$(jwt_part 2 "$(<"$subject_file")" | jq .exp)"
timeout 30 bash -c 'until [ "$(date +%s)" -gt "$0" ]; do sleep 1; done' "$expired_at" || fail "the clock did not pass the token's expiry"
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "the exchange of an expired token" 400 invalid_request
[ "$(agent_token)" = 200 ] || fail "$agent's grant without a scope was refused"
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "the exchange of $agent's token asked without mcp-hopin" 403 access_denied

# A person's token holds no hopin audience, so it is not exchangeable either.
create_person_body() {
  jq --null-input --arg username "$person" --rawfile password "$password_file" \
    '{username: $username, enabled: true, email: ($username + "@example.invalid"), emailVerified: true,
      firstName: "Probe", lastName: "Person", credentials: [{type: "password", value: $password, temporary: false}]}'
}
create_person_body >"$scratch/body"
admin POST "$realm/users" "@$scratch/body" >/dev/null
rm -f -- "$scratch/body"
# A create adds the realm's default actions whatever it names, so only an update clears the terms.
person_id="$(admin GET "$realm/users?exact=true&username=$person" | jq --raw-output '.[0].id')"
admin PUT "$realm/users/$person_id" '{"requiredActions": []}' >/dev/null
admin POST "$realm/clients" "$(jq --null-input --arg id "$password_client" '{clientId: $id, publicClient: true,
  directAccessGrantsEnabled: true, standardFlowEnabled: false,
  defaultClientScopes: ["basic", "profile", "email", "roles", "groups"], optionalClientScopes: []}')" >/dev/null
curl --silent --show-error --fail --data grant_type=password --data-urlencode "client_id=$password_client" \
  --data-urlencode "username=$person" --data-urlencode "password@$password_file" "$token_endpoint" |
  jq --raw-output .access_token | tr -d '\n' >"$scratch/person-token"
person_claims="$(jwt_part 2 "$(<"$scratch/person-token")")"
[ "$(jq '[.aud] | flatten | index("'"$exchanger"'") == null' <<<"$person_claims")" = true ] ||
  fail "a person's token names $exchanger in its audience"
exchange "$exchanger" "$exchanger_secret_file" "$scratch/person-token" --data "scope=$exchange_scope"
expect_refusal "the exchange of a person's token" 403 access_denied

# A switch-off of the exchanging client, the agent client or its service account stops the exchange of a token minted
# before.
[ "$(agent_token --data scope=mcp-hopin)" = 200 ] || fail "$agent's grant with scope=mcp-hopin was refused"
set_enabled "$exchanger_path" false
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "a disabled $exchanger's exchange" 401 invalid_client
set_enabled "$exchanger_path" true
set_enabled "$agent_path" false
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "the exchange of a token of the disabled $agent" 400 invalid_request
set_enabled "$agent_path" true
set_enabled "$account_path" false
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
expect_refusal "the exchange of a token of $agent's disabled service account" 400 invalid_request
set_enabled "$account_path" true
exchange "$exchanger" "$exchanger_secret_file" "$subject_file" --data "scope=$exchange_scope"
[ "$exchange_status" = 200 ] || fail "after re-enabling, $exchanger's exchange got $exchange_status '$(exchange_error)'"
echo "re-enabled, $exchanger's exchange answers 200"
