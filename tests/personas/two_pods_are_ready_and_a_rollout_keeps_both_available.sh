#!/usr/bin/env bash
# Usage: PERSONAS_NAMESPACE=personas PERSONAS_MANIFEST=apps/personas/personas.yaml PERSONAS_CONFIG_FILE=apps/personas/personas.toml \
#   tests/personas/two_pods_are_ready_and_a_rollout_keeps_both_available.sh
# The runner's Deployment is held at 0 replicas in k3d, whose pods would call the PC's apps with dummy secrets. This cell
# makes a Deployment of its own from the committed manifest, which keeps its replicas, strategy, pod template and mounts,
# and from a configuration derived from the committed one that sends its one agent's token request and its one app to
# a closed loopback port, so no pod calls anything outside: a pod is Ready once a round of its contention for the agent
# answered, whether it holds him or not. It proves that both pods turn Ready, and that a rollout restart keeps every
# replica available in every status the Deployment reports from the restart's start to its end. Its objects are gone on
# every exit.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

proof=personas-two-pods
: "${PERSONAS_NAMESPACE:?the namespace of the runner}"
: "${PERSONAS_MANIFEST:?the committed manifest of the Deployment of the runner}"
: "${PERSONAS_CONFIG_FILE:?the committed configuration of the runner}"
in_namespace() { kubectl --namespace "$PERSONAS_NAMESPACE" "$@"; }

status_log="$(mktemp)"
watch_pid=""
cleanup() {
  local cell_status=$?
  [ -z "$watch_pid" ] || kill "$watch_pid" 2>/dev/null || true
  rm -f "$status_log"
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
[ "$replicas" -ge 2 ] || fail "the committed Deployment runs $replicas replicas, not two or more"

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

# A watch started before the restart reports every change of the Deployment's status as one line of generation,
# observed generation, replicas, updated replicas and available replicas, an omitted count being empty; a drop below the
# replicas that recovers between two reads is a reported line all the same. The restart is complete when this same watch
# reports the restarted generation observed with every replica updated and available and no old pod left, so that no
# line queued behind it is missed. It is kubectl itself that runs in the background, so that killing its pid ends the
# watch.
restart_is_reported_complete() {
  awk -F, -v first="$first_generation" -v replicas="$replicas" \
    'END { exit !($1 > first && $2 == $1 && $3 == replicas && $4 == replicas && $5 == replicas) }' "$status_log"
}
first_generation="$(in_namespace get deployment "$proof" -o jsonpath='{.metadata.generation}')"
kubectl --namespace "$PERSONAS_NAMESPACE" get deployment "$proof" --watch \
  -o jsonpath='{.metadata.generation},{.status.observedGeneration},{.status.replicas},{.status.updatedReplicas},{.status.availableReplicas}{"\n"}' >"$status_log" &
watch_pid=$!
until_true 30 "the watch of $proof reported its first status" [ -s "$status_log" ]
in_namespace rollout restart "deployment/$proof" >/dev/null
until_true 300 "the watch of $proof reported the restart complete with all $replicas replicas available" restart_is_reported_complete
kill -0 "$watch_pid" 2>/dev/null || fail "the watch of $proof ended before the rollout restart did"
lowest="$(awk -F, 'NR == 1 || $5 + 0 < lowest { lowest = $5 + 0 } END { print lowest }' "$status_log")"
[ "$lowest" -ge "$replicas" ] || fail "the Deployment $proof had $lowest of $replicas pods available during the rollout restart"
ready="$(in_namespace get deployment "$proof" -o jsonpath='{.status.readyReplicas}')"
[ "$ready" = "$replicas" ] || fail "the Deployment $proof has $ready Ready pods after the rollout, not $replicas"
echo "the Deployment $proof had every replica available in all $(wc -l <"$status_log") reported statuses of the rollout restart, and has $ready Ready again"
