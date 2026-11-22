#!/usr/bin/env bash
# `mise run offline` and `mise run online`: the platform's stop. Every public name of the platform reaches the internet
# through the one Deployment cloudflared, so with it at 0 none answers, while Traefik, the apps, Keycloak and the
# databases keep running. The operator, or an agent on his word, runs them (docs/runbooks/take-the-platform-offline.md).
# Offline suspends the Kustomization tunnel first, so that no reconcile scales cloudflared back, then scales it to 0 and
# ends its Pods. cloudflared unregisters its connections from the edge when SIGTERM arrives, so the edge sends no new
# request to it from then on and only requests in progress wait out its 30 second drain; the Pods are deleted with a
# one second grace period and the names are off at once. A repeated or interrupted offline ends the same way.
# Online clears the suspend, asks Flux to reconcile and waits until the controller handled that request and the
# Kustomization is Ready, which cloudflared grants only with an edge connection. Flux applies from the source
# controller's stored artifact and the image sits in the node's cache by its digest, so neither command reads GitHub or
# the registry. A repeated online reconciles and returns.
# Usage: scripts/take_platform_offline_or_online.sh <offline|online>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
verb="${1:?usage: take_platform_offline_or_online.sh <offline|online>}"
fail() { echo "$verb: $1; $2" >&2; exit 1; }

flux_namespace=flux-system
layer=tunnel
tunnel_namespace=cloudflared
tunnel_deployment=cloudflared
tunnel_selector="app.kubernetes.io/name=cloudflared"
wait_seconds="${PLATFORM_OFFLINE_WAIT_SECONDS:-300}"
poll_seconds="${PLATFORM_OFFLINE_POLL_SECONDS:-3}"
field_manager=flux-client-side-apply
way_back="it is safe to run it again"

# wait_until <what> <command>...: the command passes within the wait.
wait_until() {
  local what="$1" deadline=$((SECONDS + wait_seconds))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "$what did not happen within $wait_seconds seconds" "$way_back"
    sleep "$poll_seconds"
  done
}

# The root Kustomization applies tunnel on every reconcile and takes over the fields that managers whose name starts
# with kubectl set; flux-client-side-apply is the manager its apply keeps, so a field it owns holds until online.
# suspend <json value>: the value of spec.suspend, null for absent as Git declares it.
suspend() {
  kubectl --namespace "$flux_namespace" patch kustomization "$layer" --field-manager="$field_manager" --type merge \
    --patch "{\"spec\":{\"suspend\":$1}}" >/dev/null
}
tunnel_pods_gone() {
  [ -z "$(kubectl --namespace "$tunnel_namespace" get pod --selector "$tunnel_selector" --output name)" ]
}
reconciled() {
  [ "$(kubectl --namespace "$flux_namespace" get kustomization "$layer" --output jsonpath='{.status.lastHandledReconcileAt}')" = "$1" ]
}
layer_ready() {
  [ "$(kubectl --namespace "$flux_namespace" get kustomization "$layer" \
    --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
}

offline() {
  kubectl --namespace "$flux_namespace" get kustomization "$layer" >/dev/null ||
    fail "the Kustomization $layer cannot be read; nothing changed" "$way_back"
  suspend true
  kubectl --namespace "$tunnel_namespace" scale deployment "$tunnel_deployment" --replicas=0 >/dev/null
  kubectl --namespace "$tunnel_namespace" delete pod --selector "$tunnel_selector" --grace-period=1 --wait=false >/dev/null
  wait_until "the cloudflared Pods being gone" tunnel_pods_gone
  echo "offline: every public name of the platform is off the internet and the apps keep running; mise run online brings them back (done in $SECONDS seconds)"
}

online() {
  local token
  token="$(date +%s%N)"
  suspend null
  kubectl --namespace "$flux_namespace" annotate kustomization "$layer" "reconcile.fluxcd.io/requestedAt=$token" \
    --field-manager="$field_manager" --overwrite >/dev/null
  wait_until "Flux handling the reconcile of $layer" reconciled "$token"
  wait_until "$layer being Ready" layer_ready
  echo "online: every public name of the platform answers again (done in $SECONDS seconds)"
}

case "$verb" in
  offline) offline ;;
  online) online ;;
  *) echo "take_platform_offline_or_online.sh: unknown verb '$verb'; use offline or online" >&2; exit 2 ;;
esac
