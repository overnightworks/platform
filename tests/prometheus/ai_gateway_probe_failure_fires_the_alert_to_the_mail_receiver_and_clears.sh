#!/usr/bin/env bash
# Proves docs/operations.md OPS-17: with the gateway's front stopped, Gatus' probe fails, AiGatewayProbeFailing goes
# pending and, after the rule's ten minutes, fires; Alertmanager lists it as active for the receiver mail and makes the
# send, which fails at a smarthost that cannot be looked up. With the front back the alert clears in Prometheus and in
# Alertmanager. The resolved mail is sent only after a firing mail succeeded, so it is the PC's synthetic alert's proof.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=prometheus_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/prometheus_api.sh"

stopped_replicas=""
# The layer's Kustomization would restore the replicas at its next interval, inside the ten minutes, so it is suspended
# while the front is stopped; the cell brings both back on every exit.
restore_gateway() {
  if [ -n "$stopped_replicas" ]; then
    kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas="$stopped_replicas" || true
    kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m || true
  fi
  set_layer_suspended false || true
}
trap restore_gateway EXIT
set_layer_suspended() {
  kubectl -n flux-system patch kustomization "$GATEWAY_KUSTOMIZATION" --type=merge --patch "{\"spec\":{\"suspend\":$1}}" >/dev/null
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
sends="alertmanager_notifications_total{integration=\"email\"}"
one_more_send() { [ "$(alertmanager_metric "$sends")" -gt "$sends_before" ]; }

kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m
until_true 360 "Prometheus reads the healthy probe of $GATEWAY_ENDPOINT from Gatus" probe_reads 1
alert_is_none || fail "AiGatewayProbeFailing is active while the gateway is healthy"
echo "Prometheus reads $GATEWAY_ENDPOINT healthy from Gatus and AiGatewayProbeFailing is quiet"

stopped_replicas="$(kubectl -n "$GATEWAY_NAMESPACE" get deployment "$GATEWAY_DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
sends_before="$(alertmanager_metric "$sends")"
set_layer_suspended true
kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas=0
until_true 360 "AiGatewayProbeFailing is pending for $GATEWAY_ENDPOINT" alert_is pending
echo "AiGatewayProbeFailing is pending for $GATEWAY_ENDPOINT with $GATEWAY_DEPLOYMENT at 0"

# The ten minutes of the rule, a scrape and an evaluation of a minute each after Gatus' first failing result.
until_true 900 "AiGatewayProbeFailing fires for $GATEWAY_ENDPOINT" alert_is firing
until_true 120 "Alertmanager lists AiGatewayProbeFailing as active for the receiver mail" alertmanager_routes_to_mail
until_true 120 "Alertmanager makes the send of the fired alert" one_more_send
echo "AiGatewayProbeFailing fired for $GATEWAY_ENDPOINT, Alertmanager lists it for the receiver mail and made the send"

kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas="$stopped_replicas"
kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m
stopped_replicas=""
set_layer_suspended false
until_true 360 "Prometheus reads the probe of $GATEWAY_ENDPOINT healthy again" probe_reads 1
until_true 120 "AiGatewayProbeFailing clears in Prometheus" alert_is_none
until_true 120 "AiGatewayProbeFailing clears in Alertmanager" alertmanager_lists_none
echo "AiGatewayProbeFailing cleared in Prometheus and Alertmanager with $GATEWAY_DEPLOYMENT Ready"
