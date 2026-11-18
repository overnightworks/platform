#!/usr/bin/env bash
# Usage: PERSONAS_NAMESPACE=personas PERSONAS_MANIFEST=apps/personas/personas.yaml PERSONAS_CONFIG_FILE=apps/personas/personas.toml \
#   tests/personas/two_pods_are_ready_and_a_rollout_keeps_both_available.sh
# The runner's Deployment is held at 0 replicas in k3d, whose pods would call the PC's apps with dummy secrets. This cell
# makes a Deployment of its own from the committed manifest, which keeps its replicas, strategy, pod template and mounts,
# and from a configuration derived from the committed one that sends its one agent's token request and its one app to
# a closed loopback port, so no pod calls anything outside: a pod is Ready once a round of its contention for the agent
# answered, whether it holds him or not. It proves that both pods turn Ready, and that a rollout restart keeps every
# replica available from its start to its end and never runs more pods than replicas plus the surge. Its
# objects are gone on every exit.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

proof=personas-two-pods
: "${PERSONAS_NAMESPACE:?the namespace of the runner}"
: "${PERSONAS_MANIFEST:?the committed manifest of the Deployment of the runner}"
: "${PERSONAS_CONFIG_FILE:?the committed configuration of the runner}"
in_namespace() { kubectl --namespace "$PERSONAS_NAMESPACE" "$@"; }

cleanup() {
  local cell_status=$?
  delete_object --namespace "$PERSONAS_NAMESPACE" delete deployment "$proof" --ignore-not-found --wait --timeout=3m
  delete_object --namespace "$PERSONAS_NAMESPACE" delete configmap "$proof" --ignore-not-found
  end_deletions "$cell_status"
}
trap cleanup EXIT

deployment="$(PROOF="$proof" yq 'select(.kind == "Deployment")
  | .metadata.name = strenv(PROOF)
  | del(.metadata.annotations)
  | .spec.selector.matchLabels.proof = strenv(PROOF)
  | .spec.template.metadata.labels.proof = strenv(PROOF)
  | (.spec.template.spec.volumes[] | select(.name == "config") | .configMap.name) = strenv(PROOF)' "$PERSONAS_MANIFEST")"
replicas="$(yq '.spec.replicas' <<<"$deployment")"
max_surge="$(yq '.spec.strategy.rollingUpdate.maxSurge' <<<"$deployment")"
[ "$replicas" -ge 2 ] || fail "the committed Deployment runs $replicas replicas, not two or more"
max_pods=$((replicas + max_surge))

# The committed file's [database] and [memory], so the pods hold the connections the budget counts; its apps and agents
# are replaced by one of each that no network reaches.
in_namespace create configmap "$proof" --from-file=personas.toml=<(yq -p toml -o toml '
  .token_endpoint = "http://127.0.0.1:9/token"
  | .apps = [{"mcp_url": "http://127.0.0.1:9/mcp", "scope": "mcp-proof"}]
  | .agents = [.agents[0] | {"client_id": .client_id, "secret_file": .secret_file}]
  | del(.gateway)' "$PERSONAS_CONFIG_FILE")
in_namespace create --filename - <<<"$deployment"
# Two pods are scheduled and migrate the database in their init containers, which the other cell's migrate also does.
in_namespace rollout status "deployment/$proof" --timeout=5m
ready="$(in_namespace get deployment "$proof" -o jsonpath='{.status.readyReplicas}')"
[ "$ready" = "$replicas" ] || fail "the Deployment $proof has $ready Ready pods, not $replicas"
echo "the Deployment $proof has $ready of $replicas pods Ready"

# available_and_pods: the Deployment's available replicas and its pods, an omitted count being 0; the delimiter keeps an
# omitted first field from shifting the second into its column.
available_and_pods() {
  in_namespace get deployment "$proof" -o jsonpath='{.status.availableReplicas}{"|"}{.status.replicas}' | awk -F'|' '{ print $1 + 0, $2 + 0 }'
}
in_namespace rollout restart "deployment/$proof" >/dev/null
in_namespace rollout status "deployment/$proof" --timeout=5m >/dev/null &
rollout_pid=$!
polls=0 peak=0
deadline=$((SECONDS + 300))
while kill -0 "$rollout_pid" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || fail "the rollout of $proof did not end within 5 minutes"
  read -r available pods < <(available_and_pods)
  [ "$available" -ge "$replicas" ] || fail "the Deployment $proof had $available of $replicas pods available during the rollout restart"
  [ "$pods" -le "$max_pods" ] || fail "the Deployment $proof ran $pods pods during the rollout restart, above $replicas replicas and a surge of $max_surge"
  [ "$pods" -le "$peak" ] || peak="$pods"
  polls=$((polls + 1))
  sleep 1
done
wait "$rollout_pid" || fail "the rollout restart of $proof did not complete"
ready="$(in_namespace get deployment "$proof" -o jsonpath='{.status.readyReplicas}')"
[ "$ready" = "$replicas" ] || fail "the Deployment $proof has $ready Ready pods after the rollout, not $replicas"
echo "the Deployment $proof kept an available pod through $polls polls of the rollout restart, ran at most $peak pods, and has $ready Ready again"
