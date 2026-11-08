#!/usr/bin/env bash
# In k3d: the table in the ConfigMap litellm-keys drives LiteLLM's person budget and the app keys through
# `mise run litellm:keys` and `mise run litellm:key`: --plan lists the differences, exits 2 and changes no row; a row
# without a key is named and the run ends 1; the numbers reach a key the command did not make and a second run changes
# nothing; a changed budget changes only that field and keeps the period's reset; the person budget takes its declared
# number under the id LiteLLM's configuration names; litellm:key registers the value of the app's Secret so that it
# passes the front, a second run reports unchanged, and a changed value, one without sk-, a missing key and an app
# outside the table are refused and change no row; no output holds a value, the master key or the value's sha256. The
# rows carry the models LiteLLM lists and the routes the front's rules name, read from their owners.
# The Kustomization litellm is suspended meanwhile, so that it does not restore the table, and resumed on every exit.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The tasks fall back to the PC's kubeconfig, so the job's cluster is named for them.
export KUBECONFIG="$HOME/.kube/config"
namespace="$LITELLM_NAMESPACE"
app_namespace="$APP_NAMESPACE"
aliases=(hopin presentator songmaker)
forward="" local_port="" master_key=""
# admin <path> [<JSON body>]: the master key's call to LiteLLM, which prints the reply; the key goes through curl's stdin.
admin() {
  local body=()
  [ -z "${2-}" ] || body=(--data "$2")
  printf 'header = "Authorization: Bearer %s"\n' "$master_key" |
    curl --silent --show-error --fail-with-body --max-time 30 --config - \
      --header 'Content-Type: application/json' "${body[@]}" "http://127.0.0.1:$local_port$1"
}
# attempt <command>...: a cleanup step; one that fails is named and fails the cell after the rest ran.
attempt() {
  "$@" || {
    echo "::error::the cleanup step '$1 ${2-}' failed"
    deletion_failures=$((deletion_failures + 1))
  }
}
# admin_discard <path> [<JSON body>]: admin without its reply.
admin_discard() { admin "$@" >/dev/null; }
set_table() {
  kubectl --namespace "$namespace" patch configmap litellm-keys --type merge \
    --patch "$(TABLE="$1" yq --null-input --output-format json --indent 0 '{"data": {"keys.yaml": strenv(TABLE)}}')" >/dev/null
}
# Removes what the cell added on every exit: its keys, the person budget, the Secret's key and the table, then stops the
# port-forward the deletions need and resumes the Kustomization, which restores what Flux owns.
cleanup() {
  local cell_status=$? alias
  delete_object --namespace "$app_namespace" delete pod keys-client --ignore-not-found --wait --timeout=2m
  if [ -n "$local_port" ]; then
    for alias in "${aliases[@]}"; do
      attempt admin_discard /key/delete "$(ALIAS="$alias" yq --null-input --output-format json --indent 0 '{"key_aliases": [strenv(ALIAS)]}')"
    done
    attempt admin_discard /budget/delete "$(ID="$budget_id" yq --null-input --output-format json --indent 0 '{"id": strenv(ID)}')"
  fi
  [ -z "$forward" ] || kill "$forward" 2>/dev/null || true
  attempt kubectl --namespace "$app_namespace" patch secret "$app_namespace" --type merge \
    --patch '{"data":{"litellm_key":null}}' >/dev/null
  [ -z "$table_original" ] || attempt set_table "$table_original"
  attempt flux resume kustomization litellm
  end_deletions "$cell_status"
}
table_original="" budget_id=""
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for deployment in litellm litellm-front; do
  kubectl --namespace "$namespace" rollout status "deployment/$deployment" --timeout=5m
done

table_original="$(kubectl --namespace "$namespace" get configmap litellm-keys -o jsonpath='{.data.keys\.yaml}')"
period="$(yq '.period' <<<"$table_original")"
person_budget="$(yq '.person_budget' <<<"$table_original")"
config_map="$(kubectl --namespace "$namespace" get deployment litellm \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}')"
budget_id="$(kubectl --namespace "$namespace" get configmap "$config_map" -o jsonpath='{.data.config\.yaml}' |
  yq '.litellm_settings.max_end_user_budget_id')"
front_port="$(kubectl --namespace "$namespace" get service litellm-front -o jsonpath='{.spec.ports[0].port}')"
front_url="http://litellm-front.$namespace.svc.cluster.local:$front_port"

master_key="$(kubectl --namespace "$namespace" get secret litellm -o jsonpath='{.data.master_key}' | base64 --decode)"
echo "::add-mask::$master_key"
forbidden=()
litellm_port="$(kubectl --namespace "$namespace" get service litellm -o jsonpath='{.spec.ports[0].port}')"
forward_log="$RUNNER_TEMP/litellm-keys-port-forward.log"
kubectl --namespace "$namespace" port-forward service/litellm ":$litellm_port" >"$forward_log" 2>&1 &
forward=$!
for _ in $(seq 30); do grep -q '^Forwarding from 127.0.0.1:' "$forward_log" && break; sleep 1; done
local_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -n 1)"
[ -n "$local_port" ] || fail "kubectl port-forward to the Service litellm did not start"
flux suspend kustomization litellm
# The empty copy of a fresh claim: LiteLLM migrates when it starts, so the budget list answers once it has.
for _ in $(seq 60); do admin /budget/list >/dev/null 2>&1 && break; sleep 2; done
[ "$(admin /budget/list | yq --input-format json 'length')" = 0 ] || fail "the cell expects a LiteLLM without budgets"

# forbid <value>: no output of a task may hold the value or its sha256.
forbid() {
  local hash
  hash="$(printf '%s' "$1" | sha256sum)"
  forbidden+=("$1" "${hash%% *}")
}
forbid "$master_key"
# run_task <case name> <expected exit> <task argument>...: runs the task, which must end as expected; its output is
# checked for a value before anything of it is printed.
run_task() {
  local case_name="$1" expected="$2" task_status=0 value
  shift 2
  output="$(mise run "$@" 2>&1)" || task_status=$?
  for value in "${forbidden[@]}"; do
    case "$output" in *"$value"*) fail "$case_name: the output of $* holds a value, the master key or a value's sha256" ;; esac
  done
  [ "$task_status" = "$expected" ] || fail "$case_name: $* ended $task_status, not $expected: $output"
}
# snapshot: the app rows' fields and hashes, sorted, as one JSON line.
snapshot() {
  admin '/key/list?return_full_object=true&size=100' | yq --input-format json --output-format json --indent 0 '
    [.keys[] | select(.key_alias == "hopin" or .key_alias == "presentator" or .key_alias == "songmaker") |
    pick(["key_alias", "token", "max_budget", "budget_duration", "max_parallel_requests", "models", "allowed_routes", "budget_reset_at"])] |
    sort_by(.key_alias)'
}
# row <alias> <field>: a field of the app's row.
row() {
  admin '/key/list?return_full_object=true&size=100' |
    yq --input-format json ".keys[] | select(.key_alias == \"$1\") | .$2"
}

# row_list <alias> <field>: a list field of the app's row, sorted and joined.
row_list() {
  admin '/key/list?return_full_object=true&size=100' |
    yq --input-format json ".keys[] | select(.key_alias == \"$1\") | .$2 | sort | join(\",\")"
}
# The owners of the rows' models and routes: what LiteLLM lists, and the paths the front's rules match.
expected_models="$(admin /v1/models | yq --input-format json '[.data[].id] | sort | join(",")')"
front_routes_map="$(kubectl --namespace "$namespace" get deployment litellm-front \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="routes")].configMap.name}')"
expected_routes="$(kubectl --namespace "$namespace" get configmap "$front_routes_map" -o jsonpath='{.data.route\.yml}' |
  grep -o 'Path([`][^`]*[`])' | sed 's/^Path([`]//; s/[`])$//' | sort | paste -sd,)"
[ -n "$expected_models" ] && [ -n "$expected_routes" ] || fail "LiteLLM lists no model or the front's rules name no route"

# equal_numbers <a> <b>: whether two numbers are equal as numbers, however each is written.
equal_numbers() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && b != "" && a + 0 == b + 0) }'; }

# The table without hopin, whose key does not exist yet; rows made with the master key stand in for the loaded copy,
# with numbers other than the table's.
set_table "$(yq 'del(.apps.hopin)' <<<"$table_original")"
admin /budget/new "$(ID="$budget_id" yq --null-input --output-format json --indent 0 \
  '{"budget_id": strenv(ID), "max_budget": 99, "budget_duration": "1d"}')" >/dev/null
admin /key/generate '{"key_alias": "presentator", "max_budget": 7, "budget_duration": "1d", "max_parallel_requests": 2}' >/dev/null
admin /key/generate '{"key_alias": "songmaker", "max_budget": 3}' >/dev/null
before="$(snapshot)"

run_task plan 2 litellm:keys --plan
grep -q "budget $budget_id max_budget 99 -> " <<<"$output" && grep -q 'key presentator max_budget 7 -> ' <<<"$output" &&
  grep -q 'key songmaker max_budget 3 -> ' <<<"$output" || fail "--plan did not list the differences: $output"
[ "$(snapshot)" = "$before" ] || fail "--plan changed a row"
equal_numbers "$(admin /budget/list | yq --input-format json ".[] | select(.budget_id == \"$budget_id\") | .max_budget")" 99 ||
  fail "--plan changed the person budget"
echo "--plan lists the differences, exits 2 and changes no row"

run_task apply 0 litellm:keys
run_task second-apply 0 litellm:keys
grep -q ' 0 changes made' <<<"$output" || fail "a second run did not print 0 changes: $output"
run_task second-plan 0 litellm:keys --plan
for alias in presentator songmaker; do
  equal_numbers "$(row "$alias" max_budget)" "$(ALIAS="$alias" yq '.apps[strenv(ALIAS)].budget' <<<"$table_original")" &&
    equal_numbers "$(row "$alias" max_parallel_requests)" "$(ALIAS="$alias" yq '.apps[strenv(ALIAS)].parallel' <<<"$table_original")" &&
    [ "$(row "$alias" budget_duration)" = "$period" ] || fail "$alias's row is not the table's"
  [ "$(row_list "$alias" models)" = "$expected_models" ] && [ "$(row_list "$alias" allowed_routes)" = "$expected_routes" ] ||
    fail "$alias's row holds other models or routes than LiteLLM lists and the front's rules name"
done
budget_row="$(admin /budget/list | yq --input-format json ".[] | select(.budget_id == \"$budget_id\")")"
equal_numbers "$(yq '.max_budget' <<<"$budget_row")" "$person_budget" && [ "$(yq '.budget_duration' <<<"$budget_row")" = "$period" ] ||
  fail "the person budget $budget_id is not the table's $person_budget per $period"
echo "the table's numbers reach keys the command did not make and the person budget; a second run changes nothing"

# A changed budget changes that field alone, and the period's reset stays.
reset_before="$(row presentator budget_reset_at)"
[[ $reset_before =~ ^[0-9]{4}- ]] || fail "presentator's row has no reset time: '$reset_before'"
raised="$(yq '.apps.presentator.budget + 1' <<<"$table_original")"
set_table "$(RAISED="$raised" yq 'del(.apps.hopin) | .apps.presentator.budget = (strenv(RAISED) | to_number)' <<<"$table_original")"
run_task budget-change 0 litellm:keys
[ "$(grep -c '^litellm:keys: key ' <<<"$output")" = 1 ] && grep -q "key presentator max_budget .* -> $raised\$" <<<"$output" ||
  fail "a changed budget did not change that field alone: $output"
equal_numbers "$(row presentator max_budget)" "$raised" && [ "$(row presentator budget_reset_at)" = "$reset_before" ] ||
  fail "the changed budget is not $raised, or the reset moved from $reset_before"
echo "a changed budget changes only that field and the reset stays"

# A row without a key is named, the run ends 1 and the other rows are still made equal.
set_table "$table_original"
run_task row-without-key 1 litellm:keys
grep -q 'key hopin: none; run mise run litellm:key hopin' <<<"$output" || fail "the row without a key is not named: $output"
for alias in presentator songmaker; do
  equal_numbers "$(row "$alias" max_budget)" "$(ALIAS="$alias" yq '.apps[strenv(ALIAS)].budget' <<<"$table_original")" ||
    fail "the run that named hopin's missing key did not make $alias's row equal to the table"
done
echo "a row without a key is named, the run ends 1 and the other rows are made equal"

# litellm:key registers the value of the app's Secret; the Secret takes its key by stdin, so no argument holds it.
app_key="sk-$(openssl rand -hex 24)"
echo "::add-mask::$app_key"
forbid "$app_key"
put_secret_key() {
  printf '{"data":{"litellm_key":"%s"}}' "$(printf '%s' "$1" | base64 --wrap=0)" |
    kubectl --namespace "$app_namespace" patch secret "$app_namespace" --type merge --patch-file /dev/stdin >/dev/null
}
put_secret_key "$app_key"
run_task registration 0 litellm:key hopin
equal_numbers "$(row hopin max_budget)" "$(yq '.apps.hopin.budget' <<<"$table_original")" || fail "hopin's row is not the table's"
run_task after-registration 0 litellm:keys --plan
grep -q ' 0 changes planned' <<<"$output" || fail "the new row differs from the table: $output"
client_pod="${CLIENT_POD//@NAME@/keys-client}"
client_pod="${client_pod//@IMAGE@/$CLIENT_IMAGE}"
# The Pod reads the value from the Secret through the kubelet, so neither its spec nor an argument holds it.
client_pod="$(URL="$front_url/v1/models" SECRET="$app_namespace" yq '
  .spec.containers[0].env = [{"name": "LITELLM_KEY", "valueFrom": {"secretKeyRef": {"name": strenv(SECRET), "key": "litellm_key"}}}] |
  .spec.containers[0].args = ["--silent", "--output", "/dev/null", "--write-out", "%{http_code}",
  "--max-time", "10", "--retry", "5", "--retry-connrefused", "--retry-delay", "2", "--retry-max-time", "30",
  "--header", "Authorization: Bearer $(LITELLM_KEY)", strenv(URL)]' <<<"$client_pod")"
printf '%s\n' "$client_pod" | kubectl --namespace "$app_namespace" create -f - >/dev/null
kubectl --namespace "$app_namespace" wait pod/keys-client --timeout=3m \
  --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' >/dev/null
client_status="$(kubectl --namespace "$app_namespace" logs pod/keys-client)"
kubectl --namespace "$app_namespace" delete pod keys-client --wait --timeout=2m >/dev/null
[ "$client_status" = 200 ] || fail "the front answered a Pod in $app_namespace with $client_status, not 200, for the registered value"
echo "litellm:key makes the row with the table's fields and a Pod in $app_namespace gets 200 from the front with the value"

run_task unchanged 0 litellm:key hopin
grep -q 'hopin unchanged' <<<"$output" || fail "a second litellm:key did not print unchanged: $output"
before="$(snapshot)"

# Each refusal changes no row.
other_key="sk-$(openssl rand -hex 24)"
echo "::add-mask::$other_key"
forbid "$other_key"
put_secret_key "$other_key"
run_task changed-value 1 litellm:key hopin
grep -q 'another key value holds the alias hopin' <<<"$output" || fail "a changed value was not refused as such: $output"
no_prefix_key="no-prefix-$(openssl rand -hex 24)"
echo "::add-mask::$no_prefix_key"
forbid "$no_prefix_key"
put_secret_key "$no_prefix_key"
run_task no-prefix 1 litellm:key hopin
grep -q 'starting with sk-' <<<"$output" || fail "a value without sk- was not refused as such: $output"
kubectl --namespace "$app_namespace" patch secret "$app_namespace" --type merge --patch '{"data":{"litellm_key":null}}' >/dev/null
run_task no-key 1 litellm:key hopin
grep -q 'has no litellm_key' <<<"$output" || fail "a Secret without the key was not refused as such: $output"
run_task outside-table 1 litellm:key not-in-the-table
grep -q 'has no row in the table' <<<"$output" || fail "an app outside the table was not refused as such: $output"
[ "$(snapshot)" = "$before" ] || fail "a refusal changed a row"
echo "a changed value, one without sk-, a Secret without the key and an app outside the table are refused and change no row"
echo "no output of any run holds a key's value, the master key or a value's sha256"
