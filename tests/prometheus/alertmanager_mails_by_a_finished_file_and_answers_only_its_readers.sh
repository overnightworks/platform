#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
# No line of this cell prints the Secret alertmanager's values, the finished file or Alertmanager's status API, which
# shows the address: every command that reads them discards its output and the cell reports names, counts and verdicts.
pod=prometheus-alertmanager-0
address="prometheus-alertmanager.${PROMETHEUS_NAMESPACE}.svc"
alertmanager_url="http://$address:9093"
finished_file=/run/alertmanager/alertmanager.yml
probe_secret=alertmanager-probe
init_probe=alertmanager-init-probe
pending_probe=flux-controller-pending-probe
alert_name=AlertmanagerCell

remove_probes() {
  local status=$?
  delete_object -n flux-system delete pod --ignore-not-found --wait --timeout=2m "$pending_probe"
  delete_object -n "$PROMETHEUS_NAMESPACE" delete pod --ignore-not-found --wait --timeout=2m "$init_probe" alertmanager-labelled
  delete_object -n "$PROMETHEUS_NAMESPACE" delete secret --ignore-not-found "$probe_secret"
  delete_object delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
  end_deletions "$status"
}
trap remove_probes EXIT

# until_true <seconds> <description> <command>...: the command passes within the time, tried every 5 seconds.
until_true() {
  local deadline=$((SECONDS + $1)) description="$2"
  shift 2
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "within the time: $description"
    sleep 5
  done
}
# api <path>: Prometheus' answer through the API server's proxy, which no NetworkPolicy of the pod network stops.
api() { kubectl get --raw "/api/v1/namespaces/$PROMETHEUS_NAMESPACE/services/prometheus-server:80/proxy/api/v1/$1"; }
# in_pod <command>...: runs in Alertmanager's container.
in_pod() { kubectl -n "$PROMETHEUS_NAMESPACE" exec "$pod" -c alertmanager -- "$@"; }
# metric <series selector>: the value of one of Alertmanager's own series, 0 while it has none.
metric() {
  in_pod wget -qO- http://127.0.0.1:9093/metrics | awk -v series="$1" 'index($0, series " ") == 1 {value = $2} END {print value + 0}'
}

kubectl -n "$PROMETHEUS_NAMESPACE" rollout status statefulset/prometheus-alertmanager --timeout=5m
user_id="$(in_pod id -u)"
[ "$user_id" != 0 ] || fail "Alertmanager runs as root"
echo "the StatefulSet of Alertmanager is Ready as the non-root user $user_id"

# The claim holds the notification log, which keeps a restart from mailing every firing alert again.
claim="$(kubectl -n "$PROMETHEUS_NAMESPACE" get pod "$pod" \
  -o jsonpath='{.spec.volumes[?(@.name=="storage")].persistentVolumeClaim.claimName}')"
read -r phase volume prune < <(kubectl -n "$PROMETHEUS_NAMESPACE" get pvc "$claim" \
  -o jsonpath='{.status.phase} {.spec.volumeName} {.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}')
reclaim_policy="$(kubectl get pv "$volume" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
[ "$phase|$prune|$reclaim_policy" = "Bound|disabled|Retain" ] ||
  fail "the claim $PROMETHEUS_NAMESPACE/$claim reads '$phase|$prune|$reclaim_policy', not Bound|disabled|Retain"
echo "the claim $PROMETHEUS_NAMESPACE/$claim is Bound on a Retain volume with prune disabled"

# Prometheus finds the pod through its generated alerting block, and the policy lets its alerts through.
one_alertmanager_is_active() {
  [ "$(api alertmanagers | yq -p=json '.data.activeAlertmanagers | length')" = 1 ]
}
until_true 120 "Prometheus lists one active Alertmanager" one_alertmanager_is_active
echo "Prometheus lists one active Alertmanager"

# The finished file loads, and an alert of each rule's name goes to the route's receiver, which is all amtool prints.
in_pod amtool check-config "$finished_file" >/dev/null 2>&1 || fail "amtool refuses the finished file"
receiver="$(yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-alertmanager") | .data["alertmanager.yml"] | from_yaml | .route.receiver' \
  infrastructure/prometheus/rendered.yaml)"
rule_names="$(yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-rules") | .data["rules.yml"] | from_yaml | .groups[].rules[] | select(.alert) | .alert' \
  infrastructure/prometheus/rules.yaml)"
for rule_name in $rule_names; do
  routed="$(in_pod amtool config routes test --config.file="$finished_file" "alertname=$rule_name" 2>/dev/null)" ||
    fail "amtool could not route $rule_name"
  [ "$routed" = "$receiver" ] || fail "an alert of $rule_name goes to '$routed', not to $receiver"
done
echo "amtool accepts the finished file and routes an alert of each rule (${rule_names//$'\n'/ }) to $receiver"

# The init container, built from the StatefulSet's own, refuses each bad value and names only the key. The probe's Secret
# holds values no other cell uses, which must not reach the log.
kubectl -n "$PROMETHEUS_NAMESPACE" get statefulset prometheus-alertmanager -o yaml > "$RUNNER_TEMP/alertmanager-statefulset.yaml"
init_probe_pod() {
  NAME="$init_probe" SECRET="$probe_secret" yq '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
    "spec": (.spec.template.spec | .containers = [.initContainers[0]] | del(.initContainers) | .restartPolicy = "Never" |
      (.containers[0].env[].valueFrom.secretKeyRef.name) = strenv(SECRET))}' "$RUNNER_TEMP/alertmanager-statefulset.yaml"
}
# run_init_probe <key> <value of that key>: the exit code in exit_code and the log in output; the other keys are good.
run_init_probe() {
  local key="$1" value="$2"
  kubectl -n "$PROMETHEUS_NAMESPACE" delete secret --ignore-not-found "$probe_secret" >/dev/null
  kubectl -n "$PROMETHEUS_NAMESPACE" create secret generic "$probe_secret" \
    --from-literal=smarthost=probe-smarthost.invalid:587 --from-literal=username=probe-username@mail.invalid \
    --from-literal=to=probe-recipient@mail.invalid --from-literal=password=probe-password-value >/dev/null
  if [ -n "$key" ]; then
    kubectl -n "$PROMETHEUS_NAMESPACE" patch secret "$probe_secret" --type merge \
      -p "{\"stringData\": {\"$key\": \"$value\"}}" >/dev/null
  fi
  init_probe_pod | kubectl -n "$PROMETHEUS_NAMESPACE" create -f - >/dev/null
  kubectl -n "$PROMETHEUS_NAMESPACE" wait "pod/$init_probe" --timeout=2m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' >/dev/null ||
    fail "the init probe Pod did not run to its end"
  exit_code="$(kubectl -n "$PROMETHEUS_NAMESPACE" get pod "$init_probe" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  output="$(kubectl -n "$PROMETHEUS_NAMESPACE" logs "$init_probe")"
  kubectl -n "$PROMETHEUS_NAMESPACE" delete pod "$init_probe" --wait --timeout=2m >/dev/null
}
run_init_probe "" ""
[ "$exit_code" = 0 ] || fail "the init container refused a good set of values"
echo "the init container accepts a good set of values"
for refusal in "smarthost:" "smarthost:no-port.invalid" "smarthost:probe-smarthost.invalid:587junk" \
  "smarthost:probe-smarthost.invalid:587:1" "smarthost:probe-smarthost.invalid:" "username:" "username:bad\\\"name" "to:" "password:"; do
  key="${refusal%%:*}"
  run_init_probe "$key" "${refusal#*:}"
  [ "$exit_code" != 0 ] || fail "the init container accepted a bad $key"
  [[ $output == *"key $key "* ]] || fail "the init container's refusal of a bad $key does not name it"
  for value in probe-smarthost.invalid probe-username probe-recipient probe-password-value no-port.invalid; do
    [[ $output != *"$value"* ]] || fail "the init container's refusal of a bad $key holds a value of the Secret"
  done
  echo "the init container refuses a bad $key, names only the key and exits $exit_code"
done

# A fired alert is sent on its first flush, and every later flush of a failing send follows one group_interval after the
# one before, so the sends are bounded by the time since the alert was posted. The smarthost cannot be looked up, so the
# send fails and shows in the counters and the log. alertmanager_notifications_total counts one per flush of the group and not
# one per retry, which alertmanager_notification_requests_total counts, and both are Alertmanager's own and not the
# synthetic alert's: a firing rule of the cluster would add to them. The alert's state is read from the API by its name.
# A resolved alert is sent only after its firing alert was, so against a smarthost that never answers the resolved mail
# is not attempted: its proof is the PC's.
# route_seconds <key>: the route's duration of that key in the render, in whole seconds.
route_seconds() {
  local duration
  duration="$(yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-alertmanager") | .data["alertmanager.yml"] | from_yaml | .route.'"$1" \
    infrastructure/prometheus/rendered.yaml)"
  [[ $duration =~ ^[0-9]+s$ ]] || fail "the route's $1 is '$duration', not a whole number of seconds" >&2
  echo "${duration%s}"
}
group_wait="$(route_seconds group_wait)"
group_interval="$(route_seconds group_interval)"
sends="alertmanager_notifications_total{integration=\"email\"}"
attempts="alertmanager_notification_requests_total{integration=\"email\"}"
kubectl create namespace "$OTHER_NAMESPACE"
sends_before="$(metric "$sends")"
attempts_before="$(metric "$attempts")"
alert() {
  printf '[{"labels": {"alertname": "%s"}, "annotations": {"summary": "a synthetic alert"}, "startsAt": "%s"%s}]' \
    "$alert_name" "$1" "${2:+, \"endsAt\": \"$2\"}"
}
# active_synthetic_alerts <count>: Alertmanager lists exactly that many active alerts named alert_name.
active_synthetic_alerts() {
  request_body "$PROMETHEUS_NAMESPACE" alert-reader "$address" \
    "$alertmanager_url/api/v2/alerts?filter=alertname%3D%22$alert_name%22"
  [ "$(yq -p=json '[.[] | select(.status.state == "active")] | length' <<<"$status")" = "$1" ]
}
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
posted_after=$SECONDS
request "$PROMETHEUS_NAMESPACE" alert-fires "$address" "$alertmanager_url/api/v2/alerts" \
  --request POST --header 'Content-Type: application/json' --data "$(alert "$started_at")"
[ "$status" = 200 ] || fail "a Pod in $PROMETHEUS_NAMESPACE got '$status' posting a synthetic alert, not 200"
until_true 60 "Alertmanager lists the synthetic alert as active" active_synthetic_alerts 1
one_send_was_made() { [ "$(metric "$sends")" -ge $((sends_before + 1)) ]; }
until_true 120 "the fired alert makes a send" one_send_was_made
sends_made=$(($(metric "$sends") - sends_before))
elapsed=$((SECONDS - posted_after))
flushes_possible=$((1 + (elapsed > group_wait ? (elapsed - group_wait) / group_interval : 0)))
[ "$sends_made" -le "$flushes_possible" ] ||
  fail "$sends_made sends within $elapsed seconds of the alert, while at most $flushes_possible flushes fit"
[ "$(metric "$attempts")" -ge $((attempts_before + 1)) ] || fail "the send made no attempt"
echo "a synthetic alert posted from a Pod in $PROMETHEUS_NAMESPACE fires and its sends stay within one per flush, which fail at the smarthost"
request "$PROMETHEUS_NAMESPACE" alert-resolves "$address" "$alertmanager_url/api/v2/alerts" \
  --request POST --header 'Content-Type: application/json' --data "$(alert "$started_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
[ "$status" = 200 ] || fail "a Pod in $PROMETHEUS_NAMESPACE got '$status' posting the resolution, not 200"
until_true 60 "the resolved alert leaves the active alerts" active_synthetic_alerts 0
echo "the same alert with an end resolves"

# Only Prometheus' own namespace and gatus reach the port, and a Pod there proves the address is right.
for namespace in "$PROMETHEUS_NAMESPACE" "$READER_NAMESPACE"; do
  request "$namespace" alertmanager-reader "$address" "$alertmanager_url/-/ready"
  [ "$status" = 200 ] || fail "a Pod in namespace $namespace got '$status' from Alertmanager, not 200"
  echo "a Pod in namespace $namespace gets 200 from Alertmanager"
done
request "$OTHER_NAMESPACE" alertmanager-stranger "$address" "$alertmanager_url/-/ready"
[ "$status" = 000 ] || fail "a Pod in namespace $OTHER_NAMESPACE got '$status' from Alertmanager, not no answer"
echo "a Pod in namespace $OTHER_NAMESPACE gets no answer from Alertmanager"

# A Pod with Alertmanager's labels reaches neither the Service kubernetes, github.com nor a throwaway listener on
# port 587 inside the pod network, which only the policy's except keeps closed; a Pod without the labels reaches all
# three, so the probe itself works. A target is closed only when curl tried an address and connected to none, so a name
# DNS does not resolve is unresolved and fails the cell. kube-router judges a new Pod's traffic only once it has the
# Pod's rules, so until then a Pod with the labels still connects: each target is tried again until it is closed, for at
# most 60 seconds, and must then stay closed on three more tries. A target that never closes is open.
listener=alertmanager-listener
listener_image="$(kubectl -n "$PROMETHEUS_NAMESPACE" get statefulset prometheus-alertmanager \
  -o jsonpath='{.spec.template.spec.initContainers[0].image}')"
# Port 587 is below the unprivileged range, so the listener runs as root without any capability but the bind.
IMAGE="$listener_image" NAME="$listener" yq --null-input '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
  "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false, "enableServiceLinks": false,
    "containers": [{"name": "listener", "image": strenv(IMAGE), "command": ["httpd", "-f", "-p", "587", "-h", "/tmp"],
      "securityContext": {"allowPrivilegeEscalation": false, "runAsUser": 0,
        "capabilities": {"drop": ["ALL"], "add": ["NET_BIND_SERVICE"]}}}]}}' |
  kubectl -n "$OTHER_NAMESPACE" create -f - >/dev/null
kubectl -n "$OTHER_NAMESPACE" wait "pod/$listener" --timeout=2m --for=jsonpath='{.status.containerStatuses[0].started}'=true >/dev/null
listener_target="http://$(kubectl -n "$OTHER_NAMESPACE" get pod "$listener" -o jsonpath='{.status.podIP}'):587/"
reach_script='probe() {
  result="$(curl --verbose --silent --output /dev/null --write-out "connects=%{num_connects}" --connect-timeout 5 --max-time 8 "$1" 2>&1)"
  case "$result" in *connects=1*) echo open ;; *"Trying "*) echo closed ;; *) echo unresolved ;; esac
}
expected="$1"
shift
for target; do
  state="$(probe "$target")"
  deadline=$(($(date +%s) + 60))
  while [ "$state" != "$expected" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 3; state="$(probe "$target")"; done
  if [ "$expected" = closed ] && [ "$state" = closed ]; then
    for _ in 1 2 3; do
      sleep 2
      again="$(probe "$target")"
      [ "$again" = closed ] || state="$again"
    done
  fi
  echo "$target $state"
done'
kubernetes_target="https://kubernetes.default.svc.cluster.local:$(kubectl -n default get service kubernetes -o jsonpath='{.spec.ports[0].port}')/"
reach_targets=("$kubernetes_target" https://github.com/ "$listener_target")
# reach <labels as JSON> <expected state of each target>: a client Pod with the labels in Alertmanager's namespace.
reach() {
  local labels="$1" state="$2" expected="" client_pod target
  client_pod="${CLIENT_POD//@IMAGE@/${CLIENT_IMAGE}}"
  client_pod="$(NAME=alertmanager-labelled LABELS="$labels" SCRIPT="$reach_script" ARGUMENTS="$(printf '%s\n' "$state" "${reach_targets[@]}")" yq '.metadata.name = strenv(NAME) | .metadata.labels = (strenv(LABELS) | from_yaml) |
    .spec.containers[0].args = (["sh", "-c", strenv(SCRIPT), "sh"] + (strenv(ARGUMENTS) | split("\n")))' <<<"${client_pod//@NAME@/alertmanager-labelled}")"
  printf '%s\n' "$client_pod" | kubectl -n "$PROMETHEUS_NAMESPACE" create -f - >/dev/null
  kubectl -n "$PROMETHEUS_NAMESPACE" wait pod/alertmanager-labelled --timeout=6m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' >/dev/null ||
    fail "the client Pod alertmanager-labelled did not run to its end"
  output="$(kubectl -n "$PROMETHEUS_NAMESPACE" logs pod/alertmanager-labelled)"
  kubectl -n "$PROMETHEUS_NAMESPACE" delete pod alertmanager-labelled --wait --timeout=2m >/dev/null
  for target in "${reach_targets[@]}"; do expected+="${expected:+$'\n'}$target $state"; done
  [ "$output" = "$expected" ] || fail "a Pod with the labels $labels reaches [${output//$'\n'/; }], not [${expected//$'\n'/; }]"
}
reach '{}' open
reach '{"app.kubernetes.io/name": "alertmanager"}' closed
echo "a Pod with Alertmanager's labels reaches neither the Service kubernetes, github.com nor a listener on 587 in the pod network, and one without them all three"

# A Pod of flux-system that has not run keeps no target of the job flux-controllers. It stays Pending at a tag no
# registry holds, on a repository the policy of flux-system admits, and holds an address, which Prometheus' discovery
# needs to list it at all.
controller_image="$(kubectl -n flux-system get deployment source-controller -o jsonpath='{.spec.template.spec.containers[0].image}')"
probe_image="${controller_image%:*}:probe-tag-that-does-not-exist"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pending_probe
  namespace: flux-system
  labels:
    app: $pending_probe
spec:
  automountServiceAccountToken: false
  containers:
    - name: probe
      image: $probe_image
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      ports:
        - name: http-prom
          containerPort: 8080
YAML
pending_probe_has_an_address() {
  [ "$(kubectl -n flux-system get pod "$pending_probe" -o jsonpath='{.status.phase} {.status.podIP}' | wc -w)" = 2 ]
}
until_true 120 "the probe Pod in flux-system is Pending with an address" pending_probe_has_an_address
[ "$(kubectl -n flux-system get pod "$pending_probe" -o jsonpath='{.status.phase}')" = Pending ] ||
  fail "the probe Pod in flux-system is not Pending"
probe_is_dropped() {
  api 'targets?state=dropped' | PROBE="$pending_probe" yq -p=json -e \
    '.data.droppedTargets[] | select(.scrapePool == "flux-controllers" and .discoveredLabels["__meta_kubernetes_pod_name"] == strenv(PROBE))' \
    >/dev/null 2>&1
}
until_true 180 "the Pending Pod is listed under the dropped targets of flux-controllers" probe_is_dropped
[ "$(api "query?query=count(up{job=\"flux-controllers\",pod=\"$pending_probe\"})" | yq -p=json '.data.result | length')" = 0 ] ||
  fail "the Pending Pod has an up series"
echo "a Pod of flux-system that is Pending is a dropped target of flux-controllers and has no up series"
