#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# An inventory id is <namespace>_<name>_<group>_<kind>; Kubernetes names hold no underscore.
workload_id='_(apps_(Deployment|StatefulSet|DaemonSet|ReplicaSet)|batch_(Job|CronJob)|_(Pod|ReplicationController)|helm[.]toolkit[.]fluxcd[.]io_HelmRelease)$'
created() {
  local namespace name group kind
  IFS=_ read -r namespace name group kind <<<"$1"
  kubectl get "$kind${group:+.$group}" "$name" ${namespace:+"--namespace=$namespace"} \
    -o jsonpath='{.metadata.creationTimestamp}'
}
inventory() {
  kubectl --namespace "${1%/*}" get kustomization "${1#*/}" \
    -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}'
}

# Timestamps in one RFC 3339 form in UTC order as strings.
admission_applied=""
while IFS= read -r id; do
  timestamp="$(created "$id")"
  [[ $timestamp < "$admission_applied" ]] || admission_applied="$timestamp"
done < <(inventory "$ADMISSION_LAYER")
[ -n "$admission_applied" ] || fail "the Kustomization $ADMISSION_LAYER holds no object"
echo "the last object of $ADMISSION_LAYER was created at $admission_applied"

flux_deployments="$(yq --no-doc 'select(.kind == "Deployment") | .metadata.namespace + "_" + .metadata.name + "_apps_Deployment"' \
  clusters/pc/flux-system/gotk-components.yaml | sort)"
layers="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{range .spec.dependsOn[*]}{.namespace}/{.name}{" "}{end}{"\n"}{end}')"
while IFS='|' read -r layer depends_on; do
  entries="$(inventory "$layer")"
  workloads="$(grep -E "$workload_id" <<<"$entries" | sort || true)"
  case "$layer" in
    "$ROOT_LAYER")
      [ "$workloads" = "$flux_deployments" ] ||
        fail "the workloads of $layer are '${workloads//$'\n'/ }', not the Deployments of gotk-components.yaml"
      echo "the workloads of $layer are the $(wc -l <<<"$flux_deployments") Deployments of gotk-components.yaml"
      continue ;;
    "$ADMISSION_LAYER") continue ;;
    # Their Secrets live in platform-secrets, so Flux must never delete one of these namespaces.
    "$NAMESPACES_LAYER")
      while IFS= read -r id; do
        [[ $id =~ ^_([^_]+)__Namespace$ ]] || fail "$layer holds $id, which is no Namespace"
        prune="$(kubectl get namespace "${BASH_REMATCH[1]}" -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}')"
        [ "$prune" = disabled ] || fail "the Namespace ${BASH_REMATCH[1]} of $layer lacks kustomize.toolkit.fluxcd.io/prune: disabled"
      done <<<"$entries"
      echo "every object of $layer is a Namespace Flux never prunes" ;;
  esac
  [ -n "$workloads" ] || continue
  dependencies=" "
  for dependency in $depends_on; do dependencies+="${dependency/#\//${layer%/*}/} "; done
  [[ $dependencies == *" $ADMISSION_LAYER "* ]] || fail "$layer holds workloads but does not depend on $ADMISSION_LAYER"
  while IFS= read -r id; do
    timestamp="$(created "$id")"
    [[ ! $timestamp < "$admission_applied" ]] || fail "$id of $layer was created at $timestamp, before $ADMISSION_LAYER"
  done <<<"$workloads"
  echo "$layer depends on $ADMISSION_LAYER, and its workloads were created after it"
done <<<"$layers"
