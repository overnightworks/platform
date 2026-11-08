#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
namespace="$LITELLM_NAMESPACE"
for deployment in litellm litellm-front agent-egress; do
  kubectl --namespace "$namespace" rollout status "deployment/$deployment" --timeout=5m
done
service_port() { kubectl --namespace "$2" get service "$1" -o jsonpath='{.spec.ports[0].port}'; }
front_url="http://litellm-front.$namespace.svc.cluster.local:$(service_port litellm-front "$namespace")"
litellm_port="$(service_port litellm "$namespace")"
litellm_url="http://litellm.$namespace.svc.cluster.local:$litellm_port"
egress_address="$(kubectl --namespace "$namespace" get service agent-egress -o jsonpath='{.spec.clusterIP}')"
egress_port="$(service_port agent-egress "$namespace")"
host_aliases="$(kubectl --namespace "$namespace" get deployment litellm -o json | yq '.spec.template.spec.hostAliases')"
[ "$(yq '.[0].ip' <<<"$host_aliases")" = "$egress_address" ] ||
  fail "LiteLLM's hostAliases do not name agent-egress's address $egress_address"
provider_host="$(yq '.[0].hostnames[0]' <<<"$host_aliases")"
config_map="$(kubectl --namespace "$namespace" get deployment litellm \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}')"
config="$(kubectl --namespace "$namespace" get configmap "$config_map" -o jsonpath='{.data.config\.yaml}')"
model="$(yq '.model_list[0].model_name' <<<"$config")"
budget="$(yq '.litellm_settings.max_end_user_budget_id' <<<"$config")"

# The job's dummy master key, through a port-forward, which no NetworkPolicy sees, as the operator reaches LiteLLM.
master_key="$(kubectl --namespace "$namespace" get secret litellm -o jsonpath='{.data.master_key}' | base64 --decode)"
echo "::add-mask::$master_key"
forward_log="$RUNNER_TEMP/litellm-port-forward.log"
kubectl --namespace "$namespace" port-forward service/litellm ":$litellm_port" > "$forward_log" 2>&1 &
forward=$!
trap 'kill "$forward" 2>/dev/null || true' EXIT
for _ in $(seq 30); do grep -q '^Forwarding from 127.0.0.1:' "$forward_log" && break; sleep 1; done
local_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -n 1)"
[ -n "$local_port" ] || fail "kubectl port-forward to the Service litellm did not start"
admin() {
  curl --silent --show-error --fail-with-body --max-time 30 --header "Authorization: Bearer $master_key" \
    --header 'Content-Type: application/json' --data "$2" "http://127.0.0.1:$local_port$1"
}
BUDGET="$budget" admin /budget/new "$(yq --null-input --output-format json '{"budget_id": strenv(BUDGET)}')" > /dev/null
app_key="$(MODEL="$model" admin /key/generate "$(yq --null-input --output-format json '{"models": [strenv(MODEL)]}')" |
  yq --input-format json '.key')"
[ -n "$app_key" ] && [ "$app_key" != null ] || fail "the master key made no key"
echo "::add-mask::$app_key"
echo "the master key made the person budget $budget and a key for $model"

client_pod_template="${CLIENT_POD//@IMAGE@/${CLIENT_IMAGE}}"
# run_client <namespace> <name> <labels as JSON> <argument>...: a client Pod with the labels runs the image with the
# arguments (curl's, or a command) to its end and is deleted; sets output to what it printed and exit_code to its exit.
run_client() {
  local namespace="$1" name="$2" labels="$3" client_pod
  shift 3
  client_pod="$(NAME="$name" LABELS="$labels" ARGUMENTS="$(printf '%s\n' "$@")" yq '
    .metadata.name = strenv(NAME) | .metadata.labels = (strenv(LABELS) | from_yaml) |
    .spec.containers[0].args = (strenv(ARGUMENTS) | split("\n"))' <<<"${client_pod_template//@NAME@/${name}}")"
  printf '%s\n' "$client_pod" | kubectl --namespace "$namespace" create -f - > /dev/null
  kubectl --namespace "$namespace" wait "pod/$name" --timeout=3m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' > /dev/null ||
    fail "the client Pod $name in $namespace did not run to its end"
  exit_code="$(kubectl --namespace "$namespace" get "pod/$name" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  output="$(kubectl --namespace "$namespace" logs "pod/$name")"
  kubectl --namespace "$namespace" delete pod "$name" --wait --timeout=2m > /dev/null
}
# call <namespace> <url> [<curl argument>...]: one request from a client Pod without labels; sets answer to the body
# and status to the HTTP status, 000 when no answer came.
call() {
  local namespace="$1" url="$2"
  shift 2
  run_client "$namespace" litellm-client '{}' --silent --max-time 90 --write-out '\n%{http_code}' "$@" "$url"
  status="${output##*$'\n'}"
  answer="${output%"$status"}"
}
authorized=(--header "Authorization: Bearer $app_key")
# post <url> <body> [<curl argument>...]: a JSON POST from the app namespace.
post() { call "$APP_NAMESPACE" "$1" --header 'Content-Type: application/json' --data "$2" "${@:3}"; }
completion() {
  MODEL="$model" MOCK="${1-}" yq --null-input --output-format json --indent 0 '
    {"model": strenv(MODEL), "messages": [{"role": "user", "content": "probe"}], "user": "litellm-cells"} +
    ((strenv(MOCK) | select(. != "") | {"mock_response": .}) // {})'
}

# C1: the front passes its three routes to LiteLLM, whose key check answers a call without a key, and nothing else.
post "$front_url/v1/chat/completions" '{}'
chat_status="$status"
post "$front_url/v1/images/generations" '{}'
pictures_status="$status"
call "$APP_NAMESPACE" "$front_url/v1/models"
[ "$chat_status $pictures_status $status" = "401 401 401" ] ||
  fail "the three routes without a key got $chat_status $pictures_status $status through the front, not LiteLLM's 401"
echo "POST /v1/chat/completions, POST /v1/images/generations and GET /v1/models without a key get LiteLLM's 401"
post "$front_url/key/generate" '{}' --header "Authorization: Bearer $master_key"
[ "$status" = 404 ] || fail "POST /key/generate with the master key through the front got $status, not 404"
call "$APP_NAMESPACE" "$front_url/v1/models?model=$model" "${authorized[@]}"
[ "$status" = 400 ] || fail "GET /v1/models with a query string through the front got $status, not 400"
echo "POST /key/generate with the master key gets 404 and a query string 400 through the front"
mock="mocked-$(openssl rand -hex 8)"
post "$front_url/v1/chat/completions" "$(completion "$mock")" "${authorized[@]}"
[ "$status" = 200 ] && [ "$(yq --input-format json '.choices[0].message.content' <<<"$answer")" = "$mock" ] ||
  fail "a mocked completion with the key through the front got $status without the mocked answer"
echo "a completion with the key made by the master key gets the mock_response answer through the front"

# C2: outside the three app namespaces no pod reaches the front, and only the front reaches LiteLLM.
kubectl create namespace "$OTHER_NAMESPACE"
for source in "$OTHER_NAMESPACE" "$namespace"; do
  call "$source" "$front_url/v1/models" --connect-timeout 5
  [ "$status" = 000 ] || fail "a pod in $source got $status from the front"
done
for source in "$APP_NAMESPACE" "$namespace"; do
  call "$source" "$litellm_url/health/liveliness" --connect-timeout 5
  [ "$status" = 000 ] || fail "a pod in $source got $status from LiteLLM"
done
kubectl delete namespace "$OTHER_NAMESPACE" --wait --timeout=2m
echo "pods in $OTHER_NAMESPACE and $namespace get no answer from the front, in $APP_NAMESPACE and $namespace none from LiteLLM"
post "$front_url/v1/chat/completions" "$(completion)" "${authorized[@]}"
[[ $status == 5?? ]] || fail "a real completion through the front got $status, not an upstream error"
echo "a real completion through the front ends in LiteLLM's $status"

# A Pod with a workload's labels in LiteLLM's namespace meets that workload's policy; it also matches the workload's
# Service while it runs, so no request to that Service runs beside it.
targets=("postgres.$namespace.svc.cluster.local:$(service_port postgres "$namespace")" "$egress_address:$egress_port"
  "kubernetes.default.svc.cluster.local:$(service_port kubernetes default)" "$provider_host:443")
# One line, as run_client passes each argument as a line.
reach_script='for target; do if [ "$(curl --silent --output /dev/null --write-out "%{num_connects}" --connect-timeout 5 --max-time 8 "http://$target/")" = 1 ]; then echo "$target open"; else echo "$target closed"; fi; done'
# expect_reach <labels as JSON> <open|closed per target>...
expect_reach() {
  local labels="$1" expected="" index
  shift
  run_client "$namespace" litellm-reach "$labels" sh -c "$reach_script" sh "${targets[@]}"
  printf '%s\n' "$output"
  for index in "${!targets[@]}"; do expected+="${targets[$index]} ${*:index+1:1}"$'\n'; done
  [ "$output" = "${expected%$'\n'}" ] || fail "a Pod with the labels $labels does not reach exactly as its policy says"
}
expect_reach '{"app.kubernetes.io/name": "litellm"}' open open closed closed
expect_reach '{"app.kubernetes.io/name": "agent-egress"}' closed closed closed closed
expect_reach '{}' open closed open open
echo "LiteLLM reaches only its Postgres and agent-egress, agent-egress no target, a Pod without labels all but agent-egress"

# The gateway's own TLS alert ends a handshake whose SNI no router allows; the provider's SNI passes to a dial that the
# closed egress never completes.
sni_handshake() {
  run_client "$namespace" litellm-sni '{"app.kubernetes.io/name": "litellm"}' --silent --show-error --output /dev/null \
    --max-time 15 --resolve "$1:$egress_port:$egress_address" "https://$1:$egress_port/"
}
sni_handshake "$THIRD_SNI"
[ "$exit_code" != 0 ] && grep -q alert <<<"$output" ||
  fail "the SNI $THIRD_SNI did not end in the gateway's alert: exit $exit_code"
sni_handshake "$provider_host"
[ "$exit_code" != 0 ] && ! grep -q alert <<<"$output" ||
  fail "the SNI $provider_host got an alert or an answer from the gateway: exit $exit_code"
echo "agent-egress ends the SNI $THIRD_SNI with its alert and passes $provider_host to a dial that never completes"
