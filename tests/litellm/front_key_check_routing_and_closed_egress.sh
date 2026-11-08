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
deployment_config_map() {
  kubectl --namespace "$namespace" get deployment "$1" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name==\"$2\")].configMap.name}"
}
allowed_config="$(kubectl --namespace "$namespace" get configmap "$(deployment_config_map agent-egress allowed)" \
  -o jsonpath='{.data.allowed\.yml}')"
allowed_hosts="$(yq '[.tcp.routers[].rule | capture("^HostSNI[(]`(?P<host>[^`]+)`[)]$").host] | sort | .[]' \
  <<<"$allowed_config")"
alias_hosts="$(yq '.[0].hostnames | sort | .[]' <<<"$host_aliases")"
[ "$alias_hosts" = "$allowed_hosts" ] ||
  fail "LiteLLM's hostAliases name [${alias_hosts//$'\n'/ }], agent-egress's routers allow [${allowed_hosts//$'\n'/ }]"
echo "LiteLLM's hostAliases name exactly the SNIs agent-egress allows: ${alias_hosts//$'\n'/ }"
# Both Traefiks of the layer run the image of the cluster's ingress, whose owner is infrastructure/traefik/values.yaml.
traefik_image="$(yq '.image.registry + "/" + .image.repository + ":" + .versionOverride + "@" + .image.digest' \
  infrastructure/traefik/values.yaml)"
for deployment in litellm-front agent-egress; do
  image="$(kubectl --namespace "$namespace" get deployment "$deployment" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [ "$image" = "$traefik_image" ] ||
    fail "$deployment runs $image, not $traefik_image of infrastructure/traefik/values.yaml"
done
echo "litellm-front and agent-egress run $traefik_image, the image of infrastructure/traefik/values.yaml"

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
budget_made="$(admin /budget/new \
  "$(BUDGET="$budget" yq --null-input --output-format json '{"budget_id": strenv(BUDGET)}')" |
  yq --input-format json '.budget_id')"
[ "$budget_made" = "$budget" ] || fail "the master key made the budget $budget_made, not $budget"
key_made="$(admin /key/generate "$(MODEL="$model" yq --null-input --output-format json '{"models": [strenv(MODEL)]}')")"
app_key="$(yq --input-format json '.key' <<<"$key_made")"
[ -n "$app_key" ] && [ "$app_key" != null ] || fail "the master key made no key"
echo "::add-mask::$app_key"
# yq compares scalars, not arrays, with ==.
[ "$(MODEL="$model" yq --input-format json '(.models | length) == 1 and .models[0] == strenv(MODEL)' \
  <<<"$key_made")" = true ] ||
  fail "the master key made a key for $(yq --input-format json --output-format json --indent 0 '.models' \
    <<<"$key_made"), not [$model]"
echo "the master key made the person budget $budget and a key for $model"

client_pod_template="${CLIENT_POD//@IMAGE@/${CLIENT_IMAGE}}"
# kube-router refuses a new Pod's connection until its address joins the sets a policy admits, so every request retries
# a refused connection, as CLIENT_POD's own arguments do; a denial then holds past that delay too.
retry=(--retry 5 --retry-connrefused --retry-delay 2 --retry-max-time 30)
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
  run_client "$namespace" litellm-client '{}' --silent --max-time 90 "${retry[@]}" --write-out '\n%{http_code}' "$@" \
    "$url"
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
# front_refused <request>: the last call got the front's own 404, Go's text, which none of LiteLLM's answers is; a
# wrong method on one of the three paths would get LiteLLM's 401 or 405 if the front passed it.
front_refused() {
  [ "$status" = 404 ] && grep -qx '404 page not found' <<<"$answer" ||
    fail "$1 through the front got $status, not the front's 404"
}
call "$APP_NAMESPACE" "$front_url/v1/chat/completions"
front_refused "GET /v1/chat/completions"
call "$APP_NAMESPACE" "$front_url/v1/images/generations"
front_refused "GET /v1/images/generations"
post "$front_url/v1/models" '{}'
front_refused "POST /v1/models"
post "$front_url/key/generate" '{}' --header "Authorization: Bearer $master_key"
front_refused "POST /key/generate with the master key"
echo "GET on the two POST routes, POST /v1/models and POST /key/generate with the master key get the front's 404"
# A query string gets query-refused's 400 on both of query-caught's redirects, 302 for a GET and 307 for a POST; each
# request is one LiteLLM would answer with 200.
mock="mocked-$(openssl rand -hex 8)"
call "$APP_NAMESPACE" "$front_url/v1/models?model=$model" "${authorized[@]}"
[ "$status" = 400 ] || fail "GET /v1/models with a query string through the front got $status, not 400"
post "$front_url/v1/chat/completions?model=$model" "$(completion "$mock")" "${authorized[@]}"
[ "$status" = 400 ] || fail "POST /v1/chat/completions with a query string through the front got $status, not 400"
echo "a query string gets 400 through the front on a GET and on a POST"
post "$front_url/v1/chat/completions" "$(completion "$mock")" "${authorized[@]}"
[ "$status" = 200 ] && [ "$(yq --input-format json '.choices[0].message.content' <<<"$answer")" = "$mock" ] ||
  fail "a mocked completion with the key through the front got $status without the mocked answer"
echo "a completion with the key made by the master key gets the mock_response answer through the front"

# C2: outside the three app namespaces no pod reaches the front, and only the front reaches LiteLLM.
# expect_denied <source namespace> <url>: a client Pod without labels in the namespace gets no answer from the URL but
# one from the API server, so neither a broken Pod nor its DNS passes as the denial.
control_url="http://kubernetes.default.svc.cluster.local:$(service_port kubernetes default)/"
expect_denied() {
  run_client "$1" litellm-client '{}' --silent --connect-timeout 5 --max-time 10 "${retry[@]}" \
    --write-out '%{http_code}\n' --output /dev/null "$2" --output /dev/null "$control_url"
  [[ $output =~ ^000$'\n'[1-5][0-9][0-9]$ ]] ||
    fail "a pod in $1 got [${output//$'\n'/ }] from $2 and the API server, not 000 and an answer"
}
kubectl create namespace "$OTHER_NAMESPACE"
for source in "$OTHER_NAMESPACE" "$namespace"; do expect_denied "$source" "$front_url/v1/models"; done
for source in "$APP_NAMESPACE" "$namespace"; do expect_denied "$source" "$litellm_url/health/liveliness"; done
kubectl delete namespace "$OTHER_NAMESPACE" --wait --timeout=2m
echo "pods in $OTHER_NAMESPACE and $namespace get no answer from the front, in $APP_NAMESPACE and $namespace none from" \
  "LiteLLM, and each an answer from the API server"
post "$front_url/v1/chat/completions" "$(completion)" "${authorized[@]}"
[[ $status == 5?? ]] || fail "a real completion through the front got $status, not an upstream error"
echo "a real completion through the front ends in LiteLLM's $status"

# A Pod with a workload's labels in LiteLLM's namespace meets that workload's policy; it also matches the workload's
# Service while it runs, so no request to that Service runs beside it.
targets=("postgres.$namespace.svc.cluster.local:$(service_port postgres "$namespace")" "$egress_address:$egress_port"
  "kubernetes.default.svc.cluster.local:$(service_port kubernetes default)" "$provider_host:443")
# One line, as run_client passes each argument as a line. A target is closed only when curl tried an address and
# connected to none, so a name DNS does not resolve under the policy is unresolved, not closed.
reach_script='for target; do result="$(curl --verbose --silent --output /dev/null --write-out "connects=%{num_connects}" --connect-timeout 5 --max-time 8 --retry 5 --retry-connrefused --retry-delay 2 --retry-max-time 12 "http://$target/" 2>&1)"; case "$result" in *connects=1*) echo "$target open" ;; *"Trying "*) echo "$target closed" ;; *) echo "$target unresolved" ;; esac; done'
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
expect_reach '{"app.kubernetes.io/name": "litellm-front"}' closed closed closed closed
expect_reach '{}' open closed open open
echo "LiteLLM reaches only its Postgres and agent-egress, agent-egress and the front no target, though DNS resolves for" \
  "both, a Pod without labels all but agent-egress"

# The gateway's own TLS alert ends a handshake whose SNI no router allows. The provider's SNI passes to a dial of the
# provider's resolved address, which the closed egress fails: the gateway logs that dial's error and closes the
# handshake without an alert. curl waits past Traefik's 30 s dial timeout, so a dropped dial ends in the gateway too.
# Exit 35 is curl's failed handshake: a refused connection to the gateway (7), a certificate (60) or a timeout (28)
# fail the cell, and so does a dial error that names a DNS lookup.
sni_handshake() {
  run_client "$namespace" litellm-sni '{"app.kubernetes.io/name": "litellm"}' --silent --show-error --output /dev/null \
    --max-time 45 "${retry[@]}" --resolve "$1:$egress_port:$egress_address" "https://$1:$egress_port/"
}
sni_handshake "$THIRD_SNI"
[ "$exit_code" = 35 ] && grep -q alert <<<"$output" ||
  fail "the SNI $THIRD_SNI did not end in the gateway's alert: exit $exit_code"
dial_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sni_handshake "$provider_host"
[ "$exit_code" = 35 ] && ! grep -q alert <<<"$output" ||
  fail "the SNI $provider_host got an alert, an answer or no handshake end from the gateway: exit $exit_code"
dial_error="$(kubectl --namespace "$namespace" logs deployment/agent-egress --since-time="$dial_start" |
  grep 'Error while dialing backend' || true)"
grep -Eq "dial tcp [^ ]+:443: " <<<"$dial_error" && ! grep -q lookup <<<"$dial_error" ||
  fail "agent-egress logged no failed dial of a resolved provider address: [$dial_error]"
echo "agent-egress ends the SNI $THIRD_SNI with its alert and passes $provider_host to a dial the closed egress fails:"
printf '%s\n' "$dial_error"

# LiteLLM's start check, read from the live Deployment, runs in a client Pod under the same busybox sh with fake
# values: every key or password that is empty, ends in a newline or holds a space or a non-ASCII byte, and a password
# outside A-Z a-z 0-9 - _, ends the start naming only its variable; a good set reaches the exec with no core dump
# allowed, which a stand-in litellm on the PATH reports. The Pod's hard core limit must allow a dump, or that 0 would
# prove nothing about the start's own. The Pod prints names and exit codes, never a value.
start_command="$(kubectl --namespace "$namespace" get deployment litellm -o json |
  yq --output-format json --indent 0 '.spec.template.spec.containers[] | select(.name == "litellm") | .command')"
[ "$(yq '.[0:2] | join(" ")' <<<"$start_command")" = "/bin/sh -c" ] ||
  fail "LiteLLM's command is $start_command, not /bin/sh -c and its start"
start_check_driver="$(cat <<'EOF'
start="$(printf %s "$1" | base64 -d)"
good=fake-value_0
newline='
'
non_ascii="$(printf 'fake\303\251')"
stand_in="$(mktemp -d)"
printf '#!/bin/sh\necho "reached the exec with core limit $(ulimit -c)"\n' > "$stand_in/litellm"
chmod +x "$stand_in/litellm"
# The start inherits the highest core limit the Pod may set, so only its own limit makes the stand-in report 0.
ulimit -S -c "$(ulimit -H -c)"
# attempt <case> <variable> <value>: the start with every variable good but the one named; prints the case, the
# variable, the start's exit and whether its error begins by naming that variable.
attempt() {
  errors="$(env ANTHROPIC_API_KEY="$good" OPENAI_API_KEY="$good" LITELLM_MASTER_KEY="$good" \
    DATABASE_PASSWORD="$good" "$2=$3" PATH="$stand_in:$PATH" sh -c "$start" 2>&1 > /dev/null)"
  code=$?
  case "$errors" in "litellm: $2 "*) named=named ;; *) named=unnamed ;; esac
  echo "$1 $2 $code $named"
}
for variable in ANTHROPIC_API_KEY OPENAI_API_KEY LITELLM_MASTER_KEY DATABASE_PASSWORD; do
  attempt empty "$variable" ""
  attempt newline "$variable" "$good$newline"
  attempt space "$variable" "fake value"
  attempt non-ascii "$variable" "$non_ascii"
done
attempt url-unsafe DATABASE_PASSWORD "fake/value"
[ "$(ulimit -H -c)" != 0 ] && echo "the Pod may dump cores" || echo "the Pod may dump no core"
echo "good $(env ANTHROPIC_API_KEY="$good" OPENAI_API_KEY="$good" LITELLM_MASTER_KEY="$good" \
  DATABASE_PASSWORD="$good" PATH="$stand_in:$PATH" sh -c "$start" 2> /dev/null)"
EOF
)"
run_client "$namespace" litellm-start '{}' sh -c 'driver="$(printf %s "$1" | base64 -d)"; shift; eval "$driver"' sh \
  "$(base64 --wrap=0 <<<"$start_check_driver")" "$(yq '.[2]' <<<"$start_command" | base64 --wrap=0)"
expected=""
for variable in ANTHROPIC_API_KEY OPENAI_API_KEY LITELLM_MASTER_KEY DATABASE_PASSWORD; do
  for case_name in empty newline space non-ascii; do expected+="$case_name $variable 1 named"$'\n'; done
done
expected+="url-unsafe DATABASE_PASSWORD 1 named"$'\n'"the Pod may dump cores"$'\n'
expected+="good reached the exec with core limit 0"
[ "$exit_code" = 0 ] && [ "$output" = "$expected" ] || fail "LiteLLM's start check answered, exit $exit_code:
$output"
echo "LiteLLM's start refuses each bad key and password naming only its variable, and a good set reaches the exec" \
  "with core limit 0"
