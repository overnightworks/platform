#!/usr/bin/env bash
# Proves docs/operations.md OPS-17: Prometheus reads Gatus' result of the endpoint and AiGatewayProbeFailing
# goes pending for a failing probe and clears with it. The rule's ten minutes, firing and resolving are the promtool
# test's, and the mail is the Alertmanager cell's, so the cell does not wait out the duration.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=prometheus_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/prometheus_api.sh"

stopped_replicas=""
# Flux reverts a scale only at its next interval, so the cell brings the gateway back itself on every exit.
restore_gateway() {
  if [ -n "$stopped_replicas" ]; then
    kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas="$stopped_replicas" || true
    kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m || true
  fi
}
trap restore_gateway EXIT

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

kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m
until_true 360 "Prometheus reads the healthy probe of $GATEWAY_ENDPOINT from Gatus" probe_reads 1
alert_is_none || fail "AiGatewayProbeFailing is active while the gateway is healthy"
echo "Prometheus reads $GATEWAY_ENDPOINT healthy from Gatus and AiGatewayProbeFailing is quiet"

stopped_replicas="$(kubectl -n "$GATEWAY_NAMESPACE" get deployment "$GATEWAY_DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas=0
until_true 360 "AiGatewayProbeFailing is pending for $GATEWAY_ENDPOINT" alert_is pending
echo "AiGatewayProbeFailing is pending for $GATEWAY_ENDPOINT with $GATEWAY_DEPLOYMENT at 0"

kubectl -n "$GATEWAY_NAMESPACE" scale "deployment/$GATEWAY_DEPLOYMENT" --replicas="$stopped_replicas"
kubectl -n "$GATEWAY_NAMESPACE" rollout status "deployment/$GATEWAY_DEPLOYMENT" --timeout=5m
stopped_replicas=""
until_true 360 "Prometheus reads the probe of $GATEWAY_ENDPOINT healthy again" probe_reads 1
until_true 120 "AiGatewayProbeFailing clears" alert_is_none
echo "AiGatewayProbeFailing cleared with $GATEWAY_DEPLOYMENT Ready"
