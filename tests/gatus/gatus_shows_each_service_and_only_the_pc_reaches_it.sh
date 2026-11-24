#!/usr/bin/env bash
# Proves docs/operations.md OPS-2, OPS-3 and the push of the live check's rows (OPS-23).
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

# The tunnel endpoint asks cloudflared's /ready, which answers only while cloudflared holds an edge connection: it is
# healthy exactly while the Deployment has a ready replica, and the job's part applies no tunnel layer or holds it at 0.
tunnel_ready_replicas="$(kubectl -n "$TUNNEL_NAMESPACE" get deployment cloudflared --ignore-not-found -o jsonpath='{.status.readyReplicas}')"
tunnel_state=unhealthy
[ "${tunnel_ready_replicas:-0}" -eq 0 ] || tunnel_state=healthy
while read -r name; do
  if [ "$name" = "$TUNNEL_ENDPOINT" ]; then wait_for "$tunnel_state" "$name"; else wait_for healthy "$name"; fi
done < <(yq '.endpoints[].name' infrastructure/gatus/gatus-config.yaml)
echo "every other endpoint of infrastructure/gatus/gatus-config.yaml is healthy, and $TUNNEL_ENDPOINT is $tunnel_state with $((tunnel_ready_replicas + 0)) ready cloudflared replicas"

# Each row of the live check takes a push with the token of the Secret gatus-push, refuses another token with 401 and an
# unknown row with 404, shows the pushed result and, after a second push, its error. The token reaches curl on stdin only.
push_token="$(kubectl -n gatus get secret gatus-push -o go-template='{{ .data.token | base64decode }}')"
# push_status <key> <token> <query>: the status of one push.
push_status() {
  printf 'Authorization: Bearer %s\n' "$2" |
    curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' --request POST --header @- \
      "http://127.0.0.1:$local_port/api/v1/endpoints/$1/external?$3"
}
# pushed_result <key> <field>: that field of the row's newest result. The row's own page is asked, because Gatus serves
# the list of all statuses from a cache of a few seconds that still lacks a row pushed just now.
pushed_result() {
  curl --silent --max-time 5 "http://127.0.0.1:$local_port/api/v1/endpoints/$1/statuses" | yq -p=json ".results[-1].$2"
}
while read -r key; do
  [ "$(push_status "$key" "$push_token" success=true)" = 200 ] || fail "a push of true to $key was not accepted with 200"
  [ "$(pushed_result "$key" success)" = true ] || fail "Gatus shows no success after a push of true to $key"
  [ "$(push_status "$key" "$push_token" 'success=false&error=probe+error')" = 200 ] || fail "a push of false to $key was not accepted with 200"
  [ "$(pushed_result "$key" success)" = false ] && [ "$(pushed_result "$key" 'errors[0]')" = "probe error" ] ||
    fail "Gatus shows not the pushed failure and its error for $key"
  [ "$(push_status "$key" wrong-token success=true)" = 401 ] || fail "a push to $key with a wrong token was not refused with 401"
  [ "$(push_status "$key" "$push_token" success=true)" = 200 ] || fail "the closing push of true to $key was not accepted with 200"
done < <(yq '.external-endpoints[] | .group + "_" + (.name | sub(" ", "-"))' infrastructure/gatus/gatus-config.yaml)
[ "$(push_status live-check_no-such-app-sign-in "$push_token" success=true)" = 404 ] || fail "a push to an unknown row was not refused with 404"
echo "each external endpoint of infrastructure/gatus/gatus-config.yaml takes a push with the Secret's token, shows its result and error, and refuses a wrong token with 401 and an unknown row with 404"

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
# Only Prometheus' server pod gets through: a client Pod in Prometheus' own namespace carries no server labels.
request "$PROMETHEUS_NAMESPACE" gatus-denied-sibling-request gatus.gatus.svc "http://gatus.gatus.svc:$port/api/v1/endpoints/statuses"
{ [ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; }; } ||
  fail "a Pod in namespace $PROMETHEUS_NAMESPACE beside the server got '$status' from Gatus, curl exit code $exit_code, not no answer"
echo "a Pod in namespace $PROMETHEUS_NAMESPACE other than Prometheus' server gets no answer from Gatus"
