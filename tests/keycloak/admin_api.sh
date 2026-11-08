# shellcheck shell=bash
# Sourced by the scripts under tests/keycloak/ that call Keycloak's admin REST API and token endpoint from the runner,
# through a port-forward, which no NetworkPolicy sees. It needs namespace, REALM_FILE and RUNNER_TEMP; it sets realm,
# forward_pid, local_url and keycloak, and an EXIT trap that ends the forward, which a script with its own trap keeps.
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# mask_secret <value>: tells Actions to hide the value in its logs; outside Actions the command would print it.
mask_secret() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::$1"; }

# shellcheck disable=SC2034 # realm and keycloak are what the sourcing script reads.
realm="$(yq '.realm' "$REALM_FILE")"
# shellcheck disable=SC2154 # namespace is the sourcing script's.
keycloak="$(kubectl -n "$namespace" get deployment keycloak -o json)"
keycloak_env() { NAME="$1" yq -p json '.spec.template.spec.containers[0].env[] | select(.name == strenv(NAME))' <<<"$keycloak"; }
read -r secret_name secret_key < <(keycloak_env KC_BOOTSTRAP_ADMIN_CLIENT_SECRET |
  yq '.valueFrom.secretKeyRef | .name + " " + .key')
read -r admin_client < <(keycloak_env KC_BOOTSTRAP_ADMIN_CLIENT_ID | yq '.value')
# The secret lives in a file so curl posts it from there, never from its command line.
admin_secret_file="$RUNNER_TEMP/keycloak-admin-secret"
(umask 077 && kubectl -n "$namespace" get secret "$secret_name" \
  -o go-template="{{index .data \"$secret_key\" | base64decode}}" >"$admin_secret_file")
mask_secret "$(<"$admin_secret_file")"

forward_log="$RUNNER_TEMP/keycloak-forward.log"
timeout 20m kubectl -n "$namespace" port-forward --address 127.0.0.1 service/keycloak :8080 >"$forward_log" 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; rm -f -- "$admin_secret_file"' EXIT
timeout 30 bash -c 'until grep -q "^Forwarding from 127.0.0.1:" "$0"; do sleep 1; done' "$forward_log" ||
  fail "the port-forward to Keycloak did not start: $(<"$forward_log")"
local_url="http://127.0.0.1:$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -n 1)"

admin_token() {
  curl --silent --show-error --fail --data grant_type=client_credentials --data-urlencode "client_id=$admin_client" \
    --data-urlencode "client_secret@$admin_secret_file" "$local_url/realms/master/protocol/openid-connect/token" |
    jq --raw-output .access_token
}
# bearer_curl <token> <curl argument>...: curl with the token's header read from a process substitution, so the token
# stands in no command line and no file.
bearer_curl() {
  local token="$1"
  shift
  curl --header @<(printf 'Authorization: Bearer %s\n' "$token") "$@"
}
# admin <method> <path> [<JSON body or @file>]: one admin REST call with a fresh token; prints the answer's body.
admin() {
  local body=()
  [ "$#" -lt 3 ] || body=(--data "$3")
  bearer_curl "$(admin_token)" --silent --show-error --fail --request "$1" \
    --header 'Content-Type: application/json' "${body[@]}" "$local_url/admin/realms/$2"
}
# jwt_part <1|2> <token>: the decoded JSON of the token's header (1) or claims (2).
jwt_part() {
  cut -d . -f "$1" <<<"$2" | tr '_-' '/+' | awk '{ while (length($0) % 4) $0 = $0 "="; print }' | base64 --decode
}
# rerun_config_cli: deletes the finished Job and lets Flux run it again; returns once it completed.
rerun_config_cli() {
  kubectl -n "$namespace" delete job config-cli --wait --timeout=2m
  flux reconcile kustomization "$namespace" --timeout=10m
  kubectl -n "$namespace" wait job/config-cli --for=condition=Complete --timeout=10m
}
