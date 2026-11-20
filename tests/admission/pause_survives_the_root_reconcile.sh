#!/usr/bin/env bash
# Pause the attestation check, make the root Kustomization apply its tree again, and read the pause back: the Kustomization
# app-attestations is still suspended, Kyverno's admission controller still at 0 replicas and no webhook configuration of
# Kyverno's is back, so the root's apply does not undo the pause. The cell resumes on every exit.
# The task defaults to the PC's kubeconfig, so the cell hands it the runner's own.
# Needs ROOT_LAYER and ATTESTATION_LAYER (each <namespace>/<name>) and ADMISSION_SCRIPT.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
root_namespace="${ROOT_LAYER%%/*}" root_name="${ROOT_LAYER#*/}"
layer_namespace="${ATTESTATION_LAYER%%/*}" layer_name="${ATTESTATION_LAYER#*/}"
# The labels the script selects by, read from it so that the cell and the task name them once.
controller_selector="$(sed -n 's/^controller_selector="\(.*\)"$/\1/p' "$ADMISSION_SCRIPT")"
webhook_selector="$(sed -n 's/^webhook_selector="\(.*\)"$/\1/p' "$ADMISSION_SCRIPT")"
[ -n "$controller_selector" ] && [ -n "$webhook_selector" ] || fail "$ADMISSION_SCRIPT names no controller_selector or webhook_selector"

resume_on_exit() {
  local cell_status=$?
  "$ADMISSION_SCRIPT" resume || cell_status=1
  exit "$cell_status"
}
trap resume_on_exit EXIT
"$ADMISSION_SCRIPT" pause

token="$(date +%s%N)"
kubectl --namespace "$root_namespace" annotate kustomization "$root_name" "reconcile.fluxcd.io/requestedAt=$token" \
  --field-manager=flux-client-side-apply --overwrite
root_handled() {
  [ "$(kubectl --namespace "$root_namespace" get kustomization "$root_name" --output jsonpath='{.status.lastHandledReconcileAt}')" = "$token" ]
}
until_true 180 "the root Kustomization $root_name handling the reconcile it was asked for" root_handled

suspended="$(kubectl --namespace "$layer_namespace" get kustomization "$layer_name" --output jsonpath='{.spec.suspend}')"
[ "$suspended" = true ] || fail "after the root's reconcile $layer_name is suspended '$suspended', not true"
replicas="$(kubectl get deployment --all-namespaces --selector "$controller_selector" \
  --output jsonpath='{.items[*].spec.replicas}')"
[ "$replicas" = 0 ] || fail "after the root's reconcile Kyverno's admission controller runs at '$replicas' replicas, not 0"
webhooks="$(kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration --selector "$webhook_selector" --output name)"
[ -z "$webhooks" ] || fail "after the root's reconcile Kyverno's webhook configurations are back: $webhooks"
echo "the root's reconcile left $layer_name suspended, Kyverno at 0 replicas and its webhook configurations gone"
