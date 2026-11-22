#!/usr/bin/env bash
# Take the platform offline, make the root Kustomization reconcile, and read the stop back: tunnel is still suspended
# (a suspended Kustomization handles no reconcile of its own), no cloudflared Pod exists and the Service cloudflared has
# no endpoint, so Flux brings no connector back.
# Then bring it online: tunnel has applied the candidate and is Ready, and Flux corrects a hand-made scale again. The job
# has no edge, so that the names answer 530 while offline is proven by the first run on the PC. The cell runs online on
# every exit. The script defaults to the PC's kubeconfig, so the cell hands it the runner's own.
# Needs ROOT_LAYER and TUNNEL_LAYER (each <namespace>/<name>), TUNNEL_NAMESPACE and OFFLINE_SCRIPT.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
root_namespace="${ROOT_LAYER%%/*}" root_name="${ROOT_LAYER#*/}"
layer_namespace="${TUNNEL_LAYER%%/*}" layer_name="${TUNNEL_LAYER#*/}"

online_on_exit() {
  local cell_status=$?
  "$OFFLINE_SCRIPT" online || cell_status=1
  exit "$cell_status"
}
trap online_on_exit EXIT

declared_replicas="$(kubectl --namespace "$TUNNEL_NAMESPACE" get deployment cloudflared --output jsonpath='{.spec.replicas}')"

handled_since() {
  [ "$(kubectl --namespace "$1" get kustomization "$2" --output jsonpath='{.status.lastHandledReconcileAt}')" = "$3" ]
}
# reconcile <namespace> <name>: the Kustomization handles a reconcile requested now.
reconcile() {
  local token
  token="$(date +%s%N)"
  kubectl --namespace "$1" annotate kustomization "$2" "reconcile.fluxcd.io/requestedAt=$token" \
    --field-manager=flux-client-side-apply --overwrite
  until_true 180 "the Kustomization $2 handling the reconcile it was asked for" handled_since "$1" "$2" "$token"
}

"$OFFLINE_SCRIPT" offline
reconcile "$root_namespace" "$root_name"

suspended="$(kubectl --namespace "$layer_namespace" get kustomization "$layer_name" --output jsonpath='{.spec.suspend}')"
[ "$suspended" = true ] || fail "after the root reconcile $layer_name is suspended '$suspended', not true"
replicas="$(kubectl --namespace "$TUNNEL_NAMESPACE" get deployment cloudflared --output jsonpath='{.spec.replicas}')"
[ "$replicas" = 0 ] || fail "after the root reconcile cloudflared runs at '$replicas' replicas, not 0"
pods="$(kubectl --namespace "$TUNNEL_NAMESPACE" get pod --selector app.kubernetes.io/name=cloudflared --output name)"
[ -z "$pods" ] || fail "after the root reconcile cloudflared Pods exist: $pods"
endpoints="$(kubectl --namespace "$TUNNEL_NAMESPACE" get endpoints cloudflared --output jsonpath='{.subsets[*].addresses[*].ip}')"
[ -z "$endpoints" ] || fail "after the root reconcile the Service cloudflared has endpoints: $endpoints"
echo "the reconcile of the root left $layer_name suspended, cloudflared at 0 with no Pod and its Service without an endpoint"

"$OFFLINE_SCRIPT" online
suspended="$(kubectl --namespace "$layer_namespace" get kustomization "$layer_name" --output jsonpath='{.spec.suspend}')"
[ -z "$suspended" ] || fail "after online $layer_name is suspended '$suspended'"
applied_revision="$(kubectl --namespace "$layer_namespace" get kustomization "$layer_name" --output jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "after online $layer_name applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
replicas="$(kubectl --namespace "$TUNNEL_NAMESPACE" get deployment cloudflared --output jsonpath='{.spec.replicas}')"
[ "$replicas" = "$declared_replicas" ] || fail "after online cloudflared runs at '$replicas' replicas, not the $declared_replicas it ran at"
echo "online cleared the suspend of $layer_name, which applied the candidate and is Ready"

kubectl --namespace "$TUNNEL_NAMESPACE" scale deployment cloudflared --replicas=2
reconcile "$layer_namespace" "$layer_name"
replicas="$(kubectl --namespace "$TUNNEL_NAMESPACE" get deployment cloudflared --output jsonpath='{.spec.replicas}')"
[ "$replicas" = "$declared_replicas" ] || fail "after a hand-made scale and a reconcile cloudflared runs at '$replicas' replicas, not the $declared_replicas Git declares"
echo "Flux corrected a hand-made scale of cloudflared to the $declared_replicas Git declares"
