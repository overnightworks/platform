#!/usr/bin/env bash
# Proves the path of docs/operations.md OPS-17: with the gateway's front stopped, Gatus' probe fails, AiGatewayProbeFailing
# goes pending and, after its `for`, fires; Alertmanager lists it as active for the receiver mail and makes the send,
# which fails at a smarthost that cannot be looked up. With the front back the alert clears in Prometheus and in
# Alertmanager. The resolved mail is sent only after a firing mail succeeded, so it is the PC's synthetic alert's proof.
# The cell shortens the `for` in this test cluster and waits for the duration Prometheus has loaded; that the shipped
# rule waits ten minutes is proven by promtool in tests/prometheus/rules_test.yml.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=prometheus_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/prometheus_api.sh"

stopped_replicas=""
# The layer's Kustomization would restore the replicas at its next interval, inside the rule's wait, and the root
# Kustomization re-applies the layer's without `suspend` at its own, and the prometheus Kustomization would re-apply the
# shipped rule, so all three are suspended while the cell runs; the cell brings all back on every exit, and Flux then
# applies the shipped rule again.
restore_gateway() {
  if [ -n "$stopped_replicas" ]; then
    kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas="$stopped_replicas" || true
    kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m || true
  fi
  resume_flux || true
}
trap restore_gateway EXIT
set_suspended() {
  kubectl -n flux-system patch kustomization "$2" --type=merge --patch "{\"spec\":{\"suspend\":$1}}" >/dev/null
}
# Resumes the three Kustomizations and asks the prometheus one to apply the shipped rule now.
resume_flux() {
  set_suspended false "$GATEWAY_KUSTOMIZATION"
  set_suspended false flux-system
  set_suspended false "$PROMETHEUS_KUSTOMIZATION"
  kubectl -n flux-system annotate kustomization "$PROMETHEUS_KUSTOMIZATION" --overwrite "reconcile.fluxcd.io/requestedAt=$(date +%s)"
}

probe_success="gatus_results_endpoint_success{name=\"$GATEWAY_ENDPOINT\"}"
probe_reads() { [ "$(query "$probe_success" | yq -p=json '.value[1]')" = "$1" ]; }
alert_is() {
  api alerts | yq -p=json -e ".data.alerts[] | select(.state == \"$1\" and .labels.alertname == \"AiGatewayProbeFailing\" and .labels.name == \"$GATEWAY_ENDPOINT\")" >/dev/null 2>&1
}
alert_is_none() {
  local alerts
  alerts="$(api alerts)" || return 1
  ! yq -p=json -e '.data.alerts[] | select(.labels.alertname == "AiGatewayProbeFailing")' <<<"$alerts" >/dev/null 2>&1
}
# Alertmanager's active alerts of the rule, read in its pod, where no NetworkPolicy stands between.
alertmanager_alerts() {
  kubectl -n "$PROMETHEUS_NAMESPACE" exec prometheus-alertmanager-0 -c alertmanager -- \
    wget -qO- 'http://127.0.0.1:9093/api/v2/alerts?filter=alertname%3D%22AiGatewayProbeFailing%22'
}
alertmanager_routes_to_mail() {
  alertmanager_alerts | yq -p=json -e '.[] | select(.status.state == "active" and .receivers[0].name == "mail")' >/dev/null 2>&1
}
alertmanager_lists_none() {
  local alerts
  alerts="$(alertmanager_alerts)" || return 1
  [ "$(yq -p=json '[.[] | select(.status.state == "active")] | length' <<<"$alerts")" = 0 ]
}
# The loaded `for` of the rule in seconds, as Prometheus reports it.
loaded_rule_duration() {
  api rules | yq -p=json -e '.data.groups[].rules[] | select(.name == "AiGatewayProbeFailing") | .duration'
}
loaded_duration_is() { [ "$(loaded_rule_duration)" = "$1" ]; }
# The rules.yml of the ConfigMap with the `for` of AiGatewayProbeFailing alone set to $1.
rules_with_gateway_for() {
  kubectl -n "$PROMETHEUS_NAMESPACE" get configmap prometheus-rules -o yaml |
    yq ".data.\"rules.yml\" | from_yaml | (.groups[].rules[] | select(.alert == \"AiGatewayProbeFailing\") | .for) = \"$1\" | to_yaml"
}
shortened_for=2m
shortened_seconds=120
# Gatus' probe, Prometheus' scrape and an evaluation of the rule, each of about a minute, come after the `for`.
margin_seconds=300

sends="alertmanager_notifications_total{integration=\"email\"}"
one_more_send() { [ "$(alertmanager_metric "$sends")" -gt "$sends_before" ]; }

kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m
until_true 360 "Prometheus reads the healthy probe of $GATEWAY_ENDPOINT from Gatus" probe_reads 1
# A gateway that was still settling leaves a pending alert, which the next evaluation drops once the probe reads healthy.
until_true 360 "AiGatewayProbeFailing is gone while the gateway is healthy" alert_is_none
echo "Prometheus reads $GATEWAY_ENDPOINT healthy from Gatus and AiGatewayProbeFailing is quiet"

shipped_duration="$(loaded_rule_duration)"
set_suspended true "$PROMETHEUS_KUSTOMIZATION"
rules_json="$(PATCHED_RULES="$(rules_with_gateway_for "$shortened_for")" yq -n -o=json '.data."rules.yml" = strenv(PATCHED_RULES)')"
kubectl -n "$PROMETHEUS_NAMESPACE" patch configmap prometheus-rules --type=merge --patch "$rules_json" >/dev/null
# The mount syncs and the reloader reloads within a few minutes.
until_true 240 "Prometheus has loaded the shortened for of AiGatewayProbeFailing" loaded_duration_is "$shortened_seconds"
loaded_duration="$(loaded_rule_duration)"
echo "Prometheus has loaded AiGatewayProbeFailing with a for of $loaded_duration seconds in place of the shipped $shipped_duration"

stopped_replicas="$(kubectl -n "$GATEWAY_NAMESPACE" get deployment "$GATEWAY_DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
sends_before="$(alertmanager_metric "$sends")"
set_suspended true flux-system
set_suspended true "$GATEWAY_KUSTOMIZATION"
kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas=0
until_true 360 "AiGatewayProbeFailing is pending for $GATEWAY_ENDPOINT" alert_is pending
echo "AiGatewayProbeFailing is pending for $GATEWAY_ENDPOINT with $GATEWAY_DEPLOYMENT at 0"

until_true $((loaded_duration + margin_seconds)) "AiGatewayProbeFailing fires for $GATEWAY_ENDPOINT" alert_is firing
until_true 120 "Alertmanager lists AiGatewayProbeFailing as active for the receiver mail" alertmanager_routes_to_mail
until_true 120 "Alertmanager makes the send of the fired alert" one_more_send
echo "AiGatewayProbeFailing fired for $GATEWAY_ENDPOINT, Alertmanager lists it for the receiver mail and made the send"

kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas="$stopped_replicas"
kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m
stopped_replicas=""
resume_flux
until_true 360 "Prometheus reads the probe of $GATEWAY_ENDPOINT healthy again" probe_reads 1
until_true 120 "AiGatewayProbeFailing clears in Prometheus" alert_is_none
until_true 120 "AiGatewayProbeFailing clears in Alertmanager" alertmanager_lists_none
echo "AiGatewayProbeFailing cleared in Prometheus and Alertmanager with $GATEWAY_DEPLOYMENT Ready"
until_true 300 "Flux has applied the shipped rule again" loaded_duration_is "$shipped_duration"
echo "AiGatewayProbeFailing is back at the shipped for of $(loaded_rule_duration) seconds"
