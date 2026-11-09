#!/usr/bin/env bash
# access_tokens_hold_no_profile_or_email_claim.sh: a person signs in to every client of REALM_FILE with the standard
# flow (authorization code with PKCE, then a refresh grant), and no access token holds a claim that a mapper of the live
# scopes profile and email names, while the ID tokens keep the identity the apps read and the tokens for the speech
# service keep their audience, subject, authorized party and groups. Prints names and outcomes, never a token, a claim
# value, a secret or a password; the throwaway person is deleted on every exit.
set -euo pipefail
umask 077
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
namespace="$KEYCLOAK_NAMESPACE"
# shellcheck source=admin_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/admin_api.sh"

person=p240-person
scratch="$(mktemp -d "$RUNNER_TEMP/p240-cells.XXXXXX")"
password_file="$scratch/password"
secret_file="$scratch/client-secret"
verifier_file="$scratch/verifier"
code_file="$scratch/code"
refresh_file="$scratch/refresh-token"
cookie_jar="$scratch/cookies"
response_file="$scratch/response"
remove_throwaways() {
  local id
  id="$(admin GET "$realm/users?exact=true&username=$person" | jq --raw-output '.[0].id // empty')" || id=""
  [ -z "$id" ] || admin DELETE "$realm/users/$id" || echo "::warning::the throwaway user $person was not deleted"
  rm -rf -- "$scratch" "$admin_secret_file"
  kill "$forward_pid" 2>/dev/null || true
}
trap remove_throwaways EXIT
trap 'exit 143' TERM INT

# The claims the live scopes' mappers write, and a count to compare with the file's, so a scope that lost its mappers
# cannot make the check below vacuous. A full-name mapper writes the claim name.
mapper_models=""
for scope in profile email; do
  scope_id="$(admin GET "$realm/client-scopes" | jq --raw-output --arg scope "$scope" '.[] | select(.name == $scope) | .id')"
  [ -n "$scope_id" ] || fail "the realm $realm holds no client scope $scope"
  mapper_models+="$(admin GET "$realm/client-scopes/$scope_id/protocol-mappers/models" | jq --compact-output '.[]')"$'\n'
done
claim_names="$(jq --slurp --compact-output '[.[] | .config["claim.name"] // (select(.protocolMapper == "oidc-full-name-mapper") | "name")] | unique' <<<"$mapper_models")"
live_mappers="$(jq --slurp length <<<"$mapper_models")"
declared_mappers="$(yq '[.clientScopes[] | select(.name == "profile" or .name == "email") | .protocolMappers[]] | length' "$REALM_FILE")"
[ "$live_mappers" -gt 0 ] && [ "$live_mappers" = "$declared_mappers" ] ||
  fail "the live scopes profile and email hold $live_mappers mappers, $REALM_FILE declares $declared_mappers"
echo "the live scopes profile and email hold $live_mappers mappers naming $(jq length <<<"$claim_names") claims"

speech_audience="$(yq --exit-status '.clientScopes[] | select(.name == "speech-service-audience") | .protocolMappers[0].config."included.client.audience"' "$REALM_FILE")"
speech_group="/services/$speech_audience"
openssl rand -hex 24 | tr -d '\n' >"$password_file"
mask_secret "$(<"$password_file")"
jq --null-input --arg username "$person" --rawfile password "$password_file" \
  '{username: $username, enabled: true, email: ($username + "@example.invalid"), emailVerified: true,
    firstName: "Probe", lastName: "Person", attributes: {locale: ["de"]},
    credentials: [{type: "password", value: $password, temporary: false}]}' >"$scratch/body"
admin POST "$realm/users" "@$scratch/body" >/dev/null
rm -f -- "$scratch/body"
person_id="$(admin GET "$realm/users?exact=true&username=$person" | jq --raw-output '.[0].id')"
# A create adds the realm's default actions whatever it names, so only an update clears the terms.
admin PUT "$realm/users/$person_id" '{"requiredActions": []}' >/dev/null
for group in "$speech_group" $(yq '.groups[] | select(.name == "apps") | .subGroups[] | "/apps/" + .name' "$REALM_FILE"); do
  admin PUT "$realm/users/$person_id/groups/$(admin GET "$realm/group-by-path$group" | jq --raw-output .id)" >/dev/null
done
person_groups="$(admin GET "$realm/users/$person_id/groups" | jq --compact-output '[.[].path] | sort')"

base_url="$local_url/realms/$realm/protocol/openid-connect"
# claims_of <token>: the token's claims as one JSON line.
claims_of() { jwt_part 2 "$1" | jq --compact-output .; }
# request_token <client_auth word>... -- <curl argument>...: a token request answered into the response file; fails
# naming the status, never the body.
request_token() {
  local status
  status="$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --data-urlencode "client_id=$client" "${client_auth[@]}" "$@" "$base_url/token")"
  [ "$status" = 200 ] || fail "the token endpoint answered $status for $client, not 200"
}
# check_access <label> <access token>: it holds no claim a profile or email mapper names.
check_access() {
  local held
  held="$(claims_of "$2" | jq --raw-output --argjson names "$claim_names" 'keys as $keys | $names[] | select(. as $name | $keys | index($name))' | paste -sd, -)"
  [ -z "$held" ] || fail "the access token of $client ($1) holds the claims: $held"
  echo "the access token of $client ($1) holds no claim of profile or email"
}
# check_id <label> <ID token> <expected claims word>...: the ID token holds each of them.
check_id() {
  local label="$1" claims missing
  claims="$(claims_of "$2")"
  shift 2
  missing="$(jq --raw-output --arg wanted "$*" '. as $held | $wanted | split(" ") | map(select(. as $name | $held | has($name) | not)) | join(",")' <<<"$claims")"
  [ -z "$missing" ] || fail "the ID token of $client ($label) lacks the claims: $missing"
  echo "the ID token of $client ($label) holds $*"
}
# check_speech <label> <access token>: the audience, the person, the authorized party and the groups.
check_speech() {
  jq --exit-status --arg audience "$speech_audience" --arg client "$client" --arg person "$person_id" --argjson groups "$person_groups" \
    '([.aud] | flatten | index($audience)) != null and .sub == $person and .azp == $client and (.groups | sort) == $groups' \
    >/dev/null <<<"$(claims_of "$2")" || fail "the access token of $client ($1) misses $speech_audience as audience, the person, the client as azp or the groups"
  echo "the access token of $client ($1) names $speech_audience, the person, the client as azp and the person's groups"
}

# form_action <page>: the first form's action path, which names the public hostname that the runner cannot reach.
form_action() {
  grep -o '<form[^>]*action="[^"]*"' "$1" | head -n 1 | sed -n 's/.*action="\([^"]*\)".*/\1/p' | sed 's/&amp;/\&/g; s#^https\?://[^/]*##'
}
# post_form <page> <curl argument>...: posts to the page's form; prints the status and the redirect address.
post_form() {
  local action
  action="$(form_action "$1")"
  [ -n "$action" ] || fail "the page of $client holds no form"
  shift
  curl --silent --show-error --output /dev/null --write-out '%{http_code} %{redirect_url}' --cookie-jar "$cookie_jar" \
    --cookie "$cookie_jar" "$@" "$local_url$action"
}
# sign_in <scope> <redirect uri>: the authorization code flow with PKCE as a browser drives it, with the consent a client
# asks for; leaves the code in its file.
sign_in() {
  local scope="$1" redirect_uri="$2" challenge state page="$scratch/page.html" status location
  openssl rand -hex 32 | tr -d '\n' >"$verifier_file"
  challenge="$(openssl dgst -sha256 -binary <"$verifier_file" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  state="$(openssl rand -hex 8)"
  : >"$cookie_jar"
  status="$(curl --silent --show-error --output "$page" --write-out '%{http_code}' --cookie-jar "$cookie_jar" --cookie "$cookie_jar" \
    --get --data-urlencode "client_id=$client" --data-urlencode "redirect_uri=$redirect_uri" --data response_type=code \
    --data-urlencode "scope=$scope" --data code_challenge_method=S256 --data-urlencode "code_challenge=$challenge" \
    --data "state=$state" "$base_url/auth")"
  [ "$status" = 200 ] || fail "the login page of $client answered $status, not 200"
  status="$(post_form "$page" --data-urlencode "username=$person" --data-urlencode "password@$password_file")"
  [ "${status%% *}" = 302 ] || fail "the sign-in of $client answered ${status%% *}, not a redirect"
  location="${status#* }"
  if [ "${location%%\?*}" != "$redirect_uri" ]; then
    # The client asks for a consent: its page is read from the redirect and accepted with the code it carries.
    status="$(curl --silent --show-error --output "$page" --write-out '%{http_code}' --cookie-jar "$cookie_jar" --cookie "$cookie_jar" \
      "$local_url$(sed -E 's#^https?://[^/]+##' <<<"$location")")"
    [ "$status" = 200 ] || fail "the page after the sign-in of $client answered $status, not 200"
    consent_code="$(grep -o '<input[^>]*name="code"[^>]*' "$page" | sed -n 's/.*value="\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$consent_code" ] || fail "the sign-in of $client redirects to ${location%%\?*}, not $redirect_uri, and asks no consent"
    status="$(post_form "$page" --data-urlencode "code=$consent_code" --data accept=Yes)"
    [ "${status%% *}" = 302 ] || fail "the consent of $client answered ${status%% *}, not a redirect"
    location="${status#* }"
  fi
  [ "${location%%\?*}" = "$redirect_uri" ] || fail "the sign-in of $client ends at ${location%%\?*}, not $redirect_uri"
  [ "$(sed -n 's/.*[?&]state=\([^&]*\).*/\1/p' <<<"$location")" = "$state" ] || fail "the sign-in of $client returns another state"
  sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location" | tr -d '\n' >"$code_file"
  [ -s "$code_file" ] || fail "the sign-in of $client returns no code"
}

for client in $(yq '.clients[] | select(.standardFlowEnabled == true) | .clientId' "$REALM_FILE"); do
  entry="$(CLIENT="$client" yq --output-format json '.clients[] | select(.clientId == strenv(CLIENT))' "$REALM_FILE")"
  scope="$(jq --raw-output '["openid"] + (.defaultClientScopes // []) + (.optionalClientScopes // []) | join(" ")' <<<"$entry")"
  redirect_uri="$(jq --raw-output '.redirectUris[0]' <<<"$entry")"
  client_auth=()
  if [ "$(jq --raw-output '.publicClient // false' <<<"$entry")" = false ]; then
    uuid="$(admin GET "$realm/clients?clientId=$client" | jq --raw-output '.[0].id')"
    admin GET "$realm/clients/$uuid/client-secret" | jq --join-output .value >"$secret_file"
    mask_secret "$(<"$secret_file")"
    client_auth=(--data-urlencode "client_secret@$secret_file")
  fi
  speaks="$(jq --raw-output '(.optionalClientScopes // []) | index("speech-service-audience") != null' <<<"$entry")"
  has_profile="$(jq --raw-output '(.defaultClientScopes // []) | index("profile") != null' <<<"$entry")"
  id_claims=(groups)
  [ "$has_profile" = false ] || id_claims+=(preferred_username)

  sign_in "$scope" "$redirect_uri"
  request_token --data grant_type=authorization_code --data-urlencode "code@$code_file" \
    --data-urlencode "redirect_uri=$redirect_uri" --data-urlencode "code_verifier@$verifier_file"
  access_token="$(jq --raw-output .access_token "$response_file")"
  check_access "code exchange" "$access_token"
  check_id "code exchange" "$(jq --raw-output .id_token "$response_file")" "${id_claims[@]}"
  [ "$speaks" = false ] || check_speech "code exchange" "$access_token"
  if jq --exit-status '.refresh_token' "$response_file" >/dev/null; then
    jq --join-output .refresh_token "$response_file" >"$refresh_file"
    request_token --data grant_type=refresh_token --data-urlencode "refresh_token@$refresh_file"
    access_token="$(jq --raw-output .access_token "$response_file")"
    check_access "refresh grant" "$access_token"
    check_id "refresh grant" "$(jq --raw-output .id_token "$response_file")" "${id_claims[@]}"
    [ "$speaks" = false ] || check_speech "refresh grant" "$access_token"
  else
    echo "$client hands out no refresh token, so no refresh grant is made"
  fi

  if [ "$speaks" = true ]; then
    workload_role="$(CLIENT="service-account-$client" yq '.users[] | select(.username == strenv(CLIENT)) | .realmRoles[0]' "$REALM_FILE")"
    request_token --data grant_type=client_credentials --data scope=speech-service-audience
    jq --exit-status --arg role "$workload_role" --arg audience "$speech_audience" --arg client "$client" \
      '(.realm_access.roles | index($role)) != null and .client_id == $client and ([.aud] | flatten | index($audience)) != null' \
      >/dev/null <<<"$(claims_of "$(jq --raw-output .access_token "$response_file")")" ||
      fail "the workload token of $client misses the role $workload_role, client_id or the audience $speech_audience"
    echo "the workload token of $client holds the role $workload_role, its client_id and the audience $speech_audience"
  fi
done
