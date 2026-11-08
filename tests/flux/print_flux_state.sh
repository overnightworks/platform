#!/usr/bin/env bash
set -euo pipefail
flux get all --all-namespaces
# A layer's timeout ends the wait for every Kustomization, so each one not Ready is named with its reason.
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.status.conditions[?(@.type=="Ready")].reason}: {.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' |
  while IFS='|' read -r kustomization ready reason; do
    [ "$ready" = True ] || echo "::error::the Kustomization $kustomization is not Ready: $reason"
  done
flux logs --all-namespaces --level=error
# Pod Security's refusal of a Pod appears only in Warning events and the workloads' conditions, never in Flux's state.
kubectl get events --all-namespaces --field-selector type=Warning
# What an app's pull cost the runner before the failure: the kubelet's own report of each pull, and the disk.
kubectl get events --all-namespaces --field-selector reason=Pulled \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.message}{"\n"}{end}'
df --human-readable /
kubectl get deployments,replicasets --all-namespaces -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name}{range .status.conditions[*]} {.type}={.status}({.reason}: {.message}){end}{"\n"}{end}'
# A start an app refuses appears only in its own log, a refused pull only in its container's waiting state.
kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.status.containerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.waiting.message}{"\n"}{end}' |
  while IFS='|' read -r pod ready waiting; do
    [ "$ready" != True ] || continue
    echo "the Pod $pod is not Ready: $waiting"
    kubectl --namespace "${pod%/*}" logs "pod/${pod#*/}" --all-containers --tail=20 || true
  done
