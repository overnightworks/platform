#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=gpu_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/gpu_pod.sh"
# Only a Namespace this run created is deleted; one that exists already makes the create fail and stays.
created_namespace=false
remove_objects() {
  local cell_status=$?
  if $created_namespace; then
    delete_object delete namespace --wait --timeout=2m "$RESTRICTED_NAMESPACE"
  fi
  end_deletions "$cell_status"
}
trap remove_objects EXIT
class="$(runtime_class_field .metadata.name)"

applied_revision="$(kubectl -n flux-system get kustomization nvidia -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization nvidia applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n flux-system wait kustomization/nvidia --for=condition=Ready --timeout=5m
desired="$(kubectl -n "$NVIDIA_NAMESPACE" get daemonset nvidia-device-plugin-daemonset \
  -o jsonpath='{.status.desiredNumberScheduled}')"
[ "$desired" = 0 ] || fail "the device plugin's DaemonSet wants $desired pods in k3d, which has no card, not 0"
echo "the Kustomization nvidia is Ready at the candidate and its DaemonSet wants $desired pods"

handler="$(runtime_class_field .handler)"
[ "$(kubectl get runtimeclass "$class" -o jsonpath='{.handler}')" = "$handler" ] ||
  fail "the live RuntimeClass $class does not have the committed handler $handler"
echo "the RuntimeClass $class has the committed handler $handler"

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
created_namespace=true
kubectl label namespace "$RESTRICTED_NAMESPACE" pod-security.kubernetes.io/enforce=restricted
kubectl -n "$RESTRICTED_NAMESPACE" wait serviceaccount/default --for=create --timeout=1m
gpu_pod restricted-gpu "$image" "$class" | kubectl -n "$RESTRICTED_NAMESPACE" create --dry-run=server -f -
echo "a restricted Pod with the class, uid 1000 and nvidia.com/gpu 1 passes server-side dry-run in $RESTRICTED_NAMESPACE"
root_pod="$(gpu_pod root-gpu "$image" "$class" |
  yq '.spec.securityContext.runAsUser = 0 | .spec.securityContext.runAsNonRoot = false')"
if output="$(kubectl -n "$RESTRICTED_NAMESPACE" create --dry-run=server -f - <<<"$root_pod" 2>&1)"; then
  fail "a Pod at uid 0 passes dry-run in $RESTRICTED_NAMESPACE, so the dry-run judges nothing"
fi
[[ $output == *'violates PodSecurity "restricted'* ]] ||
  fail "the dry-run of a Pod at uid 0 failed without a Pod Security refusal: $output"
echo "a Pod at uid 0 is refused there by Pod Security"
