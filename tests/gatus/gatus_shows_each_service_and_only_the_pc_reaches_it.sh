#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"

scratch="$(mktemp -d)"
forward_pid=""
stopped_replicas=""
# Flux reverts a scale only at its next interval, so the cell brings the service back itself on every exit, and the
# steps after it find it Ready.
cleanup() {
  [ -z "$forward_pid" ] || kill -- "-$forward_pid" 2>/dev/null || true
  if [ -n "$stopped_replicas" ]; then
    kubectl -n "$STOPPED_NAMESPACE" scale "deployment/$STOPPED_DEPLOYMENT" --replicas="$stopped_replicas" || true
    kubectl -n "$STOPPED_NAMESPACE" rollout status "deployment/$STOPPED_DEPLOYMENT" --timeout=5m || true
  fi
  kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE" || true
  rm -rf "$scratch"
}
trap cleanup EXIT

applied_revision="$(kubectl -n flux-system get kustomization gatus -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization gatus applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n gatus rollout status deployment/gatus --timeout=5m

port="$(kubectl -n gatus get service gatus -o jsonpath='{.spec.ports[0].port}')"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" setsid mise run gatus:open >"$scratch/forward.log" 2>&1 &
forward_pid=$!
local_port=""
for _ in $(seq 30); do
  local_port="$(sed -n 's#^gatus:open: open http://127\.0\.0\.1:\([0-9]*\)/;.*#\1#p' "$scratch/forward.log")"
  [ -z "$local_port" ] || break
  sleep 1
done
[ -n "$local_port" ] || fail "gatus:open printed no address: $(cat "$scratch/forward.log")"
statuses_url="http://127.0.0.1:$local_port/api/v1/endpoints/statuses"

# wait_for <healthy|unhealthy> <name>: Gatus asks each endpoint once a minute, so a state shows within two intervals.
wait_for() {
  local want="$1" name="$2" latest
  for _ in $(seq 40); do
    latest="$(curl --silent --max-time 5 "$statuses_url" |
      yq -p=json ".[] | select(.name == \"$name\") | .results[-1].success" || true)"
    case "$want:$latest" in
      healthy:true | unhealthy:false) return 0 ;;
    esac
    sleep 5
  done
  fail "Gatus did not show $name $want within 200 seconds; its last result reads '$latest'"
}

while read -r name; do
  wait_for healthy "$name"
done < <(yq '.endpoints[].name' infrastructure/gatus/gatus-config.yaml)
echo "every endpoint of infrastructure/gatus/gatus-config.yaml is healthy"

stopped_replicas="$(kubectl -n "$STOPPED_NAMESPACE" get deployment "$STOPPED_DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
kubectl -n "$STOPPED_NAMESPACE" scale "deployment/$STOPPED_DEPLOYMENT" --replicas=0
wait_for unhealthy "$STOPPED_ENDPOINT"
echo "$STOPPED_ENDPOINT turned unhealthy with $STOPPED_DEPLOYMENT at 0"
kubectl -n "$STOPPED_NAMESPACE" scale "deployment/$STOPPED_DEPLOYMENT" --replicas="$stopped_replicas"
kubectl -n "$STOPPED_NAMESPACE" rollout status "deployment/$STOPPED_DEPLOYMENT" --timeout=5m
stopped_replicas=""
wait_for healthy "$STOPPED_ENDPOINT"
echo "$STOPPED_ENDPOINT is healthy again and $STOPPED_DEPLOYMENT is Ready"

# No pod reaches the page.
kubectl create namespace "$OTHER_NAMESPACE"
request "$OTHER_NAMESPACE" gatus-denied-request gatus.gatus.svc "http://gatus.gatus.svc:$port/api/v1/endpoints/statuses"
{ [ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; }; } ||
  fail "a Pod in namespace $OTHER_NAMESPACE got '$status' from Gatus, curl exit code $exit_code, not no answer"
echo "a Pod in namespace $OTHER_NAMESPACE gets no answer from Gatus"
