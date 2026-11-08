#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=gpu_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/gpu_pod.sh"
remove_objects() {
  local cell_status=$?
  delete_object delete namespace --ignore-not-found --wait --timeout=2m "$RESTRICTED_NAMESPACE"
  end_deletions "$cell_status"
}
trap remove_objects EXIT

applied_revision="$(kubectl -n flux-system get kustomization nvidia -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization nvidia applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n flux-system wait kustomization/nvidia --for=condition=Ready --timeout=5m
desired="$(kubectl -n "$NVIDIA_NAMESPACE" get daemonset nvidia-device-plugin-daemonset \
  -o jsonpath='{.status.desiredNumberScheduled}')"
[ "$desired" = 0 ] || fail "the device plugin's DaemonSet wants $desired pods in k3d, which has no card, not 0"
echo "the Kustomization nvidia is Ready at the candidate and its DaemonSet wants $desired pods"

[ "$(kubectl get runtimeclass nvidia -o jsonpath='{.handler}')" = nvidia ] ||
  fail "the RuntimeClass nvidia does not have the handler nvidia"
echo "the RuntimeClass nvidia has the handler nvidia"

# The Namespace is the one without a Pod Security label, and the plugin is its only workload.
labels="$(kubectl get namespace "$NVIDIA_NAMESPACE" -o jsonpath='{.metadata.labels}')"
[[ $labels != *pod-security.kubernetes.io* ]] ||
  fail "the Namespace $NVIDIA_NAMESPACE carries a Pod Security label: $labels"
workloads="$(kubectl -n "$NVIDIA_NAMESPACE" get pods,deployments,statefulsets,daemonsets,replicasets,jobs,cronjobs -o name)"
[ "$workloads" = daemonset.apps/nvidia-device-plugin-daemonset ] ||
  fail "the Namespace $NVIDIA_NAMESPACE holds more than the plugin's DaemonSet: $(tr '\n' ' ' <<<"$workloads")"
echo "the Namespace $NVIDIA_NAMESPACE has no Pod Security label and holds only the plugin's DaemonSet"

# A Pod that meets restricted passes in a Namespace that enforces it, one at uid 0 does not.
image="$(kubectl -n "$NVIDIA_NAMESPACE" get daemonset nvidia-device-plugin-daemonset \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
kubectl create namespace "$RESTRICTED_NAMESPACE"
kubectl label namespace "$RESTRICTED_NAMESPACE" pod-security.kubernetes.io/enforce=restricted
kubectl -n "$RESTRICTED_NAMESPACE" wait serviceaccount/default --for=create --timeout=1m
gpu_pod restricted-gpu "$image" | kubectl -n "$RESTRICTED_NAMESPACE" create --dry-run=server -f -
echo "a restricted Pod with the class, uid 1000 and nvidia.com/gpu 1 passes server-side dry-run in $RESTRICTED_NAMESPACE"
if gpu_pod root-gpu "$image" | yq '.spec.securityContext.runAsUser = 0 | .spec.securityContext.runAsNonRoot = false' |
  kubectl -n "$RESTRICTED_NAMESPACE" create --dry-run=server -f - 2>/dev/null; then
  fail "a Pod at uid 0 passes dry-run in $RESTRICTED_NAMESPACE, so the dry-run judges nothing"
fi
echo "a Pod at uid 0 is refused there"
