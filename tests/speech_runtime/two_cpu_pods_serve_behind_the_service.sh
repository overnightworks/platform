#!/usr/bin/env bash
# At the replica count `gpu:use songs` sets, speech's CPU image runs two Ready pods that both stand behind the Service's
# endpoints and each answer the readiness probe's own check, and a rollout restart leaves the Service at least one Ready
# endpoint from its start to its end. The cell sets the count itself, since k3d has no card for `gpu:use` to wait on,
# and puts the Deployment back as it found it.
# Usage: mise exec -- tests/speech_runtime/two_cpu_pods_serve_behind_the_service.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"

namespace=speech-runtime
deployment=speech-runtime
service=speech-runtime
pods_wanted=2

found_replicas="$(kubectl --namespace "$namespace" get "deployment/$deployment" -o jsonpath='{.spec.replicas}')"
restore() {
  kubectl --namespace "$namespace" scale "deployment/$deployment" --replicas="$found_replicas" >/dev/null || true
}
trap restore EXIT

# ready_endpoints: the names of the pods the Service's endpoint slices list as ready.
ready_endpoints() {
  kubectl --namespace "$namespace" get endpointslices --selector "kubernetes.io/service-name=$service" \
    -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.targetRef.name}{"\n"}{end}'
}
ready_endpoint_count() { ready_endpoints | grep -c . || true; }
two_ready_endpoints() { [ "$(ready_endpoint_count)" -eq "$pods_wanted" ]; }

kubectl --namespace "$namespace" scale "deployment/$deployment" --replicas="$pods_wanted" >/dev/null
kubectl --namespace "$namespace" wait "deployment/$deployment" \
  --for=jsonpath='{.status.readyReplicas}'="$pods_wanted" --timeout=5m >/dev/null
until_true 120 "the Service $service lists $pods_wanted Ready endpoints" two_ready_endpoints
echo "the Service $service lists $pods_wanted Ready endpoints"

# Each endpoint's pod answers the check the Deployment's readiness probe runs, which the cell reads from the Deployment.
probe_command=()
while IFS= read -r word; do
  probe_command+=("$word")
done < <(kubectl --namespace "$namespace" get "deployment/$deployment" \
  -o jsonpath='{range .spec.template.spec.containers[0].readinessProbe.exec.command[*]}{@}{"\n"}{end}')
[ "${#probe_command[@]}" -gt 0 ] || fail "the Deployment $deployment has no exec readiness probe"
while IFS= read -r pod; do
  kubectl --namespace "$namespace" exec "$pod" -- "${probe_command[@]}" ||
    fail "the pod $pod behind the Service $service does not pass its readiness check"
  echo "the pod $pod passes its readiness check"
done < <(ready_endpoints)

# A rollout restart: the cell polls the endpoints until the rollout ends and fails on the first poll without a Ready one.
kubectl --namespace "$namespace" rollout restart "deployment/$deployment" >/dev/null
kubectl --namespace "$namespace" rollout status "deployment/$deployment" --timeout=10m >/dev/null &
rollout_pid=$!
polls=0
deadline=$((SECONDS + 600))
while kill -0 "$rollout_pid" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || fail "the rollout of $deployment did not end within 10 minutes"
  [ "$(ready_endpoint_count)" -ge 1 ] || fail "the Service $service had no Ready endpoint during the rollout restart"
  polls=$((polls + 1))
  sleep 1
done
wait "$rollout_pid" || fail "the rollout restart of $deployment did not complete"
until_true 120 "the Service $service lists $pods_wanted Ready endpoints after the rollout" two_ready_endpoints
echo "the Service $service kept a Ready endpoint through $polls polls of the rollout restart and lists $pods_wanted again"
