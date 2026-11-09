#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
workers=(music-worker scoring-worker)

cleanup() {
  kubectl --namespace "$SONGMAKER_NAMESPACE" delete pod scoring-egress-probe free-egress-probe --ignore-not-found --wait --timeout=2m
}
trap cleanup EXIT

# Both workers are the candidate's, Available with one Ready pod at a full app ref, so their probes of arq's health key
# passed, and neither asks for the GPU; what the images cost the runner is printed.
applied_revision="$(kubectl --namespace flux-system get kustomization songmaker -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization songmaker applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
for worker in "${workers[@]}"; do
  kubectl --namespace "$SONGMAKER_NAMESPACE" wait "deployment/$worker" --for=condition=Available --timeout=3m
  state="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get deployment "$worker" -o jsonpath='{.status.readyReplicas}|{.spec.strategy.type}')"
  [ "$state" = "1|Recreate" ] || fail "the Deployment $worker reads '$state', not one Ready pod and Recreate"
  image="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get deployment "$worker" -o jsonpath='{.spec.template.spec.containers[*].image}')"
  [[ $image =~ ^ghcr[.]io/${GITHUB_REPOSITORY_OWNER,,}/[^[:space:]:@]+:[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] ||
    fail "the Deployment $worker runs '$image', not one full app ref"
  resources="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get deployment "$worker" \
    -o jsonpath='{.spec.template.spec.containers[*].resources} {.spec.template.spec.initContainers[*].resources}')"
  [[ $resources != *nvidia.com/gpu* ]] || fail "the Deployment $worker asks for the GPU: $resources"
  echo "the Deployment $worker is Available with one Ready pod and Recreate, at $image, and asks for no GPU"
done
kubectl --namespace "$SONGMAKER_NAMESPACE" get events --field-selector reason=Pulled \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}'
df --human-readable /

# egress_probe <name> <labels as JSON>: a Pod with the labels tries each target for up to a minute, since a fresh Pod can be
# refused until the NetworkPolicy controller admits its address, and reports it closed only when the last try failed too;
# sets probe_log to one line per target.
postgres_target="postgres.$SONGMAKER_NAMESPACE.svc.cluster.local:$(kubectl --namespace "$SONGMAKER_NAMESPACE" get service postgres -o jsonpath='{.spec.ports[0].port}')"
redis_target="redis.$SONGMAKER_NAMESPACE.svc.cluster.local:$(kubectl --namespace "$SONGMAKER_NAMESPACE" get service redis -o jsonpath='{.spec.ports[0].port}')"
service_port="$(kubectl --namespace "${CLUSTER_SERVICE%/*}" get service "${CLUSTER_SERVICE#*/}" -o jsonpath='{.spec.ports[0].port}')"
service_target="${CLUSTER_SERVICE#*/}.${CLUSTER_SERVICE%/*}.svc.cluster.local:$service_port"
egress_probe() {
  NAME="$1" LABELS="$2" IMAGE="$PROBE_IMAGE" TARGETS="$postgres_target $redis_target $service_target $OUTSIDE_TARGET" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME), "labels": (strenv(LABELS) | from_yaml)},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "probe", "image": strenv(IMAGE),
         "command": ["sh", "-c", "for target; do state=closed; for try in 1 2 3 4 5 6 7 8 9 10 11 12; do if nc -z -w 2 \"${target%:*}\" \"${target##*:}\" 2>/dev/null; then state=open; break; fi; sleep 3; done; echo \"$target $state\"; done", "sh"] + (strenv(TARGETS) | split(" ")),
         "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]}}' |
    kubectl --namespace "$SONGMAKER_NAMESPACE" create -f -
  kubectl --namespace "$SONGMAKER_NAMESPACE" wait "pod/$1" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m
  probe_log="$(kubectl --namespace "$SONGMAKER_NAMESPACE" logs "pod/$1")"
  printf '%s\n' "$probe_log"
  kubectl --namespace "$SONGMAKER_NAMESPACE" delete pod "$1" --wait --timeout=2m
}

# A Pod with the scoring worker's labels reaches its Postgres and Redis and neither the API server nor the internet;
# one without them reaches all four, so the probe proves the policy.
scoring_labels="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get networkpolicy scoring-worker -o jsonpath='{.spec.podSelector.matchLabels}')"
egress_probe scoring-egress-probe "$scoring_labels"
[ "$probe_log" = "$postgres_target open"$'\n'"$redis_target open"$'\n'"$service_target closed"$'\n'"$OUTSIDE_TARGET closed" ] ||
  fail "a Pod with the scoring worker's labels $scoring_labels does not reach exactly Postgres and Redis"
egress_probe free-egress-probe '{}'
[ "$probe_log" = "$postgres_target open"$'\n'"$redis_target open"$'\n'"$service_target open"$'\n'"$OUTSIDE_TARGET open" ] ||
  fail "a Pod without the scoring worker's labels does not reach every target, so the probe proves no policy"
echo "a Pod with the scoring worker's labels resolves names and reaches Postgres and Redis, neither $CLUSTER_SERVICE nor $OUTSIDE_TARGET"
