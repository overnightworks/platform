#!/usr/bin/env bash
# In k3d: `mise run litellm:admin <username>` puts a named person's customer row, under the fingerprint agent-runtime's
# recipe makes of the realm's public issuer and the person's id, on the admin budget with no limit and adds the person to
# /services/litellm/admin. A name no person carries and a service account's name are refused with nothing changed, no
# budget and no customer row written; a person without a row gets one; a row on the person budget or with no budget moves to the admin budget
# with its spend and alias unchanged; an admin budget with a finite limit is corrected to no limit and to its monthly
# period while another admin's row stays as it was; a second run prints unchanged; a call past the person budget is
# refused by the person limit for the ordinary person and passes for the admin; and no output holds a person's id, a fingerprint or a key.
set -euo pipefail
# No value of this cell reaches a trace.
{ set +x; } 2>/dev/null
# The tasks fall back to the PC's kubeconfig, so the job's cluster is named for them.
export KUBECONFIG="$HOME/.kube/config"
namespace="$KEYCLOAK_NAMESPACE"
litellm_namespace="$LITELLM_NAMESPACE"
# shellcheck source=../keycloak/admin_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/../keycloak/admin_api.sh"
admin_group=/services/litellm/admin
admin_budget=litellm-admin
person_budget_id="" person_budget_made=false litellm_port="" litellm_forward=""
user_ids=() fingerprints=() forbidden=()

# litellm <path> [<JSON body>]: the master key's call to LiteLLM, which prints the reply; the key goes through curl's stdin.
litellm() {
  local body=()
  [ -z "${2-}" ] || body=(--data "$2")
  printf 'header = "Authorization: Bearer %s"\n' "$master_key" |
    curl --silent --show-error --fail-with-body --max-time 30 --config - \
      --header 'Content-Type: application/json' "${body[@]}" "http://127.0.0.1:$litellm_port$1"
}
# attempt <command>...: a cleanup step; one that fails is named and fails the cell after the rest ran.
attempt() {
  "$@" >/dev/null || {
    echo "::error::the cleanup step '$1 ${2-}' failed"
    deletion_failures=$((deletion_failures + 1))
  }
}
# Removes what the cell made on every exit: the customers, the admin budget, the person budget when the cell made it, the
# key and the people, then ends the forwards.
cleanup() {
  local cell_status=$? user_id
  if [ -n "$litellm_port" ]; then
    [ "${#fingerprints[@]}" = 0 ] || attempt litellm /customer/delete "$(FINGERPRINTS="${fingerprints[*]}" \
      yq --null-input --output-format json --indent 0 '{"user_ids": (strenv(FINGERPRINTS) | split(" "))}')"
    attempt litellm /key/delete '{"key_aliases": ["admin-cell"]}'
    attempt litellm /budget/delete "$(ID="$admin_budget" yq --null-input --output-format json --indent 0 '{"id": strenv(ID)}')"
    [ "$person_budget_made" = false ] ||
      attempt litellm /budget/delete "$(ID="$person_budget_id" yq --null-input --output-format json --indent 0 '{"id": strenv(ID)}')"
  fi
  for user_id in "${user_ids[@]}"; do attempt admin DELETE "$realm/users/$user_id"; done
  [ -z "$litellm_forward" ] || kill "$litellm_forward" 2>/dev/null || true
  kill "$forward_pid" 2>/dev/null || true
  rm -f -- "$admin_secret_file"
  end_deletions "$cell_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl --namespace "$namespace" wait job/config-cli --for=condition=Complete --timeout=5m
kubectl --namespace "$litellm_namespace" rollout status deployment/litellm --timeout=5m
master_key="$(kubectl --namespace "$litellm_namespace" get secret litellm -o jsonpath='{.data.master_key}' | base64 --decode)"
forbidden+=("$master_key")
service_port="$(kubectl --namespace "$litellm_namespace" get service litellm -o jsonpath='{.spec.ports[0].port}')"
litellm_log="$RUNNER_TEMP/litellm-admin-port-forward.log"
kubectl --namespace "$litellm_namespace" port-forward service/litellm ":$service_port" >"$litellm_log" 2>&1 &
litellm_forward=$!
for _ in $(seq 30); do grep -q '^Forwarding from 127.0.0.1:' "$litellm_log" && break; sleep 1; done
litellm_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$litellm_log" | head -n 1)"
[ -n "$litellm_port" ] || fail "kubectl port-forward to the Service litellm did not start"
# The empty copy of a fresh claim: LiteLLM migrates when it starts, so the budget list answers once it has.
for _ in $(seq 60); do litellm /budget/list >/dev/null 2>&1 && break; sleep 2; done

config_map="$(kubectl --namespace "$litellm_namespace" get deployment litellm \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}')"
person_budget_id="$(kubectl --namespace "$litellm_namespace" get configmap "$config_map" -o jsonpath='{.data.config\.yaml}' |
  yq '.litellm_settings.max_end_user_budget_id')"
budget_ids="$(litellm /budget/list | yq --input-format json '.[].budget_id')"
! grep -qxF "$admin_budget" <<<"$budget_ids" || fail "the cell expects a LiteLLM without the budget $admin_budget"
if ! grep -qxF "$person_budget_id" <<<"$budget_ids"; then
  litellm /budget/new "$(ID="$person_budget_id" yq --null-input --output-format json --indent 0 \
    '{"budget_id": strenv(ID), "max_budget": 2, "budget_duration": "1mo"}')" >/dev/null
  person_budget_made=true
fi
public_issuer="$(curl --silent --show-error --fail "$local_url/realms/$realm/.well-known/openid-configuration" | jq --raw-output .issuer)"

# run_task <case name> <expected exit> <username>: runs the task, which must end as expected; its output is checked for
# a person's id, a fingerprint and a key before anything of it is printed.
run_task() {
  local case_name="$1" expected="$2" task_status=0 value
  output="$(mise run litellm:admin "$3" 2>&1)" || task_status=$?
  for value in "${forbidden[@]}"; do
    case "$output" in *"$value"*) fail "$case_name: the output holds an id, a fingerprint or a key" ;; esac
  done
  [ "$task_status" = "$expected" ] || fail "$case_name: ended $task_status, not $expected: $output"
}
# make_person <name>: a person of the realm; sets person_id and fingerprint, the fingerprint by agent-runtime's recipe in
# Python, apart from the command.
make_person() {
  admin POST "$realm/users" "$(NAME="$1" yq --null-input --output-format json --indent 0 '{"username": strenv(NAME), "enabled": true}')"
  person_id="$(admin GET "$realm/users?username=$1&exact=true" | jq --raw-output '.[0].id')"
  [ -n "$person_id" ] && [ "$person_id" != null ] || fail "Keycloak made no person $1"
  user_ids+=("$person_id")
  fingerprint="$(ISS="$public_issuer" SUB="$person_id" python3 -I -c '
import hashlib, json, os
identity = json.dumps([os.environ["ISS"], os.environ["SUB"]], ensure_ascii=False, separators=(",", ":"))
print("fp-" + hashlib.sha256(identity.encode("utf-8")).hexdigest())')"
  fingerprints+=("$fingerprint")
  forbidden+=("$person_id" "$fingerprint")
}
# customer <fingerprint>: the customer row as LiteLLM answers it, or nothing.
customer() { litellm "/customer/info?end_user_id=$1" 2>/dev/null || true; }
# kept <fingerprint>: the fields of the customer row that a change of its budget leaves as they are.
kept() { customer "$1" | yq --input-format json --output-format json --indent 0 'del(.budget_id) | del(.litellm_budget_table)'; }
# budget_of <fingerprint>: the budget the customer row names.
budget_of() { customer "$1" | yq --input-format json '.budget_id'; }
# in_group <person id>: whether Keycloak lists the admin group among the person's groups.
in_group() { [ "$(admin GET "$realm/users/$1/groups" | jq --raw-output --arg path "$admin_group" '[.[] | select(.path == $path)] | length')" = 1 ]; }
# new_customer <fingerprint> <JSON fields>: a customer row as the loaded copy has it.
new_customer() {
  litellm /customer/new "$(FP="$1" FIELDS="$2" yq --null-input --output-format json --indent 0 \
    '{"user_id": strenv(FP)} + (strenv(FIELDS) | from_json)')" >/dev/null
}
# budget_field <field>: a field of the admin budget's row.
budget_field() { litellm /budget/list | yq --input-format json ".[] | select(.budget_id == \"$admin_budget\") | .$1"; }

# A name no person carries and a service account's name are refused, and no budget stands afterwards.
run_task unknown 1 no-such-person-in-the-realm
grep -q 'nothing changed$' <<<"$output" || fail "an unknown name was not refused with nothing changed: $output"
run_task service-account 1 service-account-agent-mozart
grep -q 'nothing changed$' <<<"$output" || fail "a service account was not refused with nothing changed: $output"
budget_ids="$(litellm /budget/list | yq --input-format json '.[].budget_id')"
! grep -qxF "$admin_budget" <<<"$budget_ids" || fail "a refused run wrote the budget $admin_budget"
[ "$(litellm /customer/list | yq --input-format json 'length')" = 0 ] || fail "a refused run wrote a customer row"
echo "an unknown name and a service account are refused with nothing changed, no budget and no customer row written"

# A new admin: the budget has no limit and a monthly period, the row stands under the fingerprint, the person is a member.
make_person admin-cell-new
new_id="$person_id" new_fingerprint="$fingerprint"
run_task new 0 admin-cell-new
[ "$(budget_of "$new_fingerprint")" = "$admin_budget" ] && in_group "$new_id" ||
  fail "the new admin is not on $admin_budget or not in $admin_group"
[ "$(budget_field max_budget)" = null ] && [ "$(budget_field budget_duration)" = 1mo ] ||
  fail "the admin budget has a limit or another period than 1mo"
echo "a new admin gets a row under the fingerprint on the unlimited budget and joins the group"

# A finite admin budget with another admin linked is corrected, and that admin's row stays.
litellm /budget/update "$(ID="$admin_budget" yq --null-input --output-format json --indent 0 \
  '{"budget_id": strenv(ID), "max_budget": 5, "budget_duration": "1d"}')" >/dev/null
make_person admin-cell-second
before="$(kept "$new_fingerprint")"
run_task correction 0 admin-cell-second
[ "$(budget_field max_budget)" = null ] && [ "$(budget_field budget_duration)" = 1mo ] ||
  fail "the finite admin budget was not corrected to no limit and 1mo"
[ "$(kept "$new_fingerprint")" = "$before" ] && [ "$(budget_of "$new_fingerprint")" = "$admin_budget" ] ||
  fail "the other admin's row changed"
echo "a finite admin budget is corrected to no limit and 1mo, and the other admin's row stays"

# A customer on the person budget and one with no budget, each with spend, move with it unchanged; a call past the person
# budget is refused for the ordinary person and passes for the admin.
model="$(litellm /v1/models | yq --input-format json '[.data[].id | select(test("^text/"))] | .[0]')"
app_key="$(litellm /key/generate "$(MODEL="$model" yq --null-input --output-format json --indent 0 \
  '{"key_alias": "admin-cell", "models": [strenv(MODEL)], "metadata": {"allow_client_mock_response": true}}')" |
  yq --input-format json '.key')"
forbidden+=("$app_key")
# call_probe <fingerprint>: sets call_http to the status of a mocked completion by the person with the app key and
# call_cause to person-limit when the refusal is LiteLLM's budget_exceeded error for an end user, else other. The reply
# is read for its type and the start of its message and never printed, since the message names the end user.
call_probe() {
  local result body
  result="$(printf 'header = "Authorization: Bearer %s"\n' "$app_key" |
    curl --silent --max-time 30 --config - --write-out '\n%{http_code}' \
      --header 'Content-Type: application/json' --data "$(MODEL="$model" FP="$1" yq --null-input --output-format json --indent 0 \
      '{"model": strenv(MODEL), "messages": [{"role": "user", "content": "probe"}], "user": strenv(FP), "mock_response": "ok"}')" \
      "http://127.0.0.1:$litellm_port/v1/chat/completions")"
  call_http="${result##*$'\n'}"
  body="${result%$'\n'*}"
  call_cause="$(jq --raw-output 'if .error.type == "budget_exceeded" and (.error.message | startswith("ExceededBudget: End User=")) then "person-limit" else "other" end' <<<"$body" 2>/dev/null)" ||
    call_cause=other
}
# refused_by_person_limit <fingerprint>: whether a call is refused and the refusal comes from the person limit.
refused_by_person_limit() { call_probe "$1"; [ "$call_http" != 200 ] && [ "$call_cause" = person-limit ]; }
# admitted <fingerprint>: whether a call passes.
admitted() { call_probe "$1"; [ "$call_http" = 200 ]; }
make_person admin-cell-moved
moved_fingerprint="$fingerprint"
new_customer "$moved_fingerprint" "{\"budget_id\": \"$person_budget_id\", \"spend\": 5, \"alias\": \"kept\"}"
make_person admin-cell-unlinked
unlinked_fingerprint="$fingerprint"
new_customer "$unlinked_fingerprint" '{"spend": 5, "alias": "kept"}'
make_person admin-cell-ordinary
ordinary_fingerprint="$fingerprint"
new_customer "$ordinary_fingerprint" "{\"budget_id\": \"$person_budget_id\", \"spend\": 5}"
refused_by_person_limit "$moved_fingerprint" && refused_by_person_limit "$ordinary_fingerprint" ||
  fail "a call past the person budget was not refused by the person limit before the person was an admin"
[ "$(budget_of "$moved_fingerprint")" = "$person_budget_id" ] && [ "$(budget_of "$unlinked_fingerprint")" = null ] ||
  fail "the starting budgets are not the person budget and none"
for person in moved unlinked; do
  fingerprint_name="${person}_fingerprint"
  before="$(kept "${!fingerprint_name}")"
  run_task "$person" 0 "admin-cell-$person"
  [ "$(budget_of "${!fingerprint_name}")" = "$admin_budget" ] && [ "$(kept "${!fingerprint_name}")" = "$before" ] ||
    fail "the $person customer is not on $admin_budget or its spend or alias changed"
  [ "$(yq --input-format json '.spend' <<<"$before")" = 5 ] || fail "the $person customer has no spend to keep"
done
echo "a row on the person budget and one with no budget move to the admin budget with spend and alias unchanged"
admitted "$moved_fingerprint" && admitted "$unlinked_fingerprint" || fail "a call past the person budget did not pass for an admin"
refused_by_person_limit "$ordinary_fingerprint" || fail "the ordinary person's call was not refused by the person limit"
echo "a call past the person budget passes for an admin and is refused for the ordinary person"

run_task second-run 0 admin-cell-moved
grep -q '^litellm:admin: admin-cell-moved unchanged$' <<<"$output" || fail "a second run did not print unchanged: $output"
echo "a second run prints unchanged, and no output holds an id, a fingerprint or a key"
