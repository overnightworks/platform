#!/usr/bin/env bash
# restricted_pod_lists_the_card.sh: on the PC, after Flux applied the layer nvidia, shows that the node offers
# nvidia.com/gpu 1 and that a Pod in a throwaway Namespace that enforces restricted, at uid 1000 with the RuntimeClass
# nvidia and the limit nvidia.com/gpu 1, lists exactly one card. The Pod runs the image of the device plugin's DaemonSet,
# a listed vendor ref, with nvidia-smi -L as the runtime injects it. It prints counts and names, never nvidia-smi's lines,
# which carry the card's UUID. Reads through the PC's k3s kubeconfig unless KUBECONFIG is set; runs with the locked
# tools: mise exec -- tests/nvidia/restricted_pod_lists_the_card.sh.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=gpu_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/gpu_pod.sh"
plugin_namespace=nvidia
proof_namespace=nvidia-card-proof
pod=list-the-card
remove_objects() {
  local cell_status=$?
  delete_object delete namespace --ignore-not-found --wait --timeout=2m "$proof_namespace"
  end_deletions "$cell_status"
}
trap remove_objects EXIT

allocatable="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}')"
[ "$allocatable" = 1 ] || fail "the nodes offer nvidia.com/gpu '$allocatable', not exactly 1 on one node"
echo "the node offers nvidia.com/gpu 1"

image="$(kubectl -n "$plugin_namespace" get daemonset nvidia-device-plugin-daemonset \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
kubectl create namespace "$proof_namespace"
kubectl label namespace "$proof_namespace" pod-security.kubernetes.io/enforce=restricted
kubectl -n "$proof_namespace" wait serviceaccount/default --for=create --timeout=1m
gpu_pod "$pod" "$image" | kubectl -n "$proof_namespace" create -f -
if ! kubectl -n "$proof_namespace" wait "pod/$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m; then
  echo "pod/$pod ended in phase $(kubectl -n "$proof_namespace" get "pod/$pod" -o jsonpath='{.status.phase}'); its events:"
  kubectl -n "$proof_namespace" get events -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers
  fail "the restricted Pod did not run nvidia-smi -L to its end"
fi
cards="$(kubectl -n "$proof_namespace" logs "pod/$pod" | grep -c '^GPU [0-9]*:' || true)"
[ "$cards" = 1 ] || fail "the restricted Pod listed $cards cards, not 1"
echo "a restricted Pod at uid 1000 with the class nvidia and nvidia.com/gpu 1 lists $cards card"
