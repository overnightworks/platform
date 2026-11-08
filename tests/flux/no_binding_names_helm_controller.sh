#!/usr/bin/env bash
set -euo pipefail
bindings="$(kubectl get clusterrolebindings,rolebindings --all-namespaces \
  -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{"|"}{range .subjects[*]}{.kind}{"/"}{.namespace}{"/"}{.name}{" "}{end}{"\n"}{end}')"
holders="$(grep -F 'ServiceAccount/flux-system/helm-controller' <<<"$bindings" || true)"
if [ -n "$holders" ]; then
  echo "::error::these bindings name the ServiceAccount helm-controller, which no Deployment runs:"
  printf '%s\n' "$holders"
  exit 1
fi
echo "no binding names the ServiceAccount flux-system/helm-controller"
