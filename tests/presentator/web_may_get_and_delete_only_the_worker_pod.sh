#!/usr/bin/env bash
# The rendered ServiceAccounts and RBAC of apps/presentator, applied to their Namespace, hold their rights as the API
# server answers them: the web's ServiceAccount may get and delete the build worker's one pod and nothing else this cell
# asks, the worker's ServiceAccount nothing; and the web's environment names that pod. The pod's name is read from the
# rendered StatefulSet, which names its pods <name>-<ordinal>.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

work="$(mktemp -d)"
applied=
remove_objects() {
  local cell_status=$?
  [ -z "$applied" ] || delete_object delete --filename "$work/rbac.yaml" --ignore-not-found --wait --timeout=2m
  rm -rf "$work"
  end_deletions "$cell_status"
}
trap remove_objects EXIT

kubectl kustomize apps/presentator >"$work/presentator.yaml"
worker_pod="$(yq --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "build-worker") | .metadata.name + "-0"' "$work/presentator.yaml")"
other_pod="${worker_pod%-0}-1"
namespace="$(yq --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "build-worker") | .metadata.namespace' "$work/presentator.yaml")"
web_account="$(yq --no-doc 'select(.kind == "Deployment" and .metadata.name == "web") | .spec.template.spec.serviceAccountName' "$work/presentator.yaml")"
worker_account="$(yq --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "build-worker") | .spec.template.spec.serviceAccountName' "$work/presentator.yaml")"
[ -n "$worker_pod" ] && [ -n "$namespace" ] && [ -n "$web_account" ] && [ -n "$worker_account" ] ||
  fail "the render names no build worker StatefulSet, its namespace, or the web's or the worker's ServiceAccount"

named="$(yq --no-doc 'select(.kind == "Deployment" and .metadata.name == "web") | .spec.template.spec.containers[] | select(.name == "web") | .env[] | select(.name == "PRESENTATOR_BUILD_WORKER_POD") | .value' "$work/presentator.yaml")"
[ "$named" = "$worker_pod" ] || fail "the web's PRESENTATOR_BUILD_WORKER_POD is '$named', not the StatefulSet's first pod '$worker_pod'"
echo "the web's environment names the worker's pod $worker_pod"

yq 'select(.kind == "ServiceAccount" or .kind == "Role" or .kind == "RoleBinding")' "$work/presentator.yaml" >"$work/rbac.yaml"
applied=1
kubectl apply --filename "$work/rbac.yaml" >/dev/null

# expect <account> <yes|no> <verb> <resource> [kubectl flags]: the API server answers the account's request so; any
# answer but yes or no fails, so a refused impersonation never passes as a no.
expect() {
  local account="$1" expected="$2" verb="$3" resource="$4" reply actual
  shift 4
  reply="$(kubectl auth can-i "$verb" "$resource" --namespace "$namespace" \
    --as "system:serviceaccount:$namespace:$account" "$@" 2>&1)" || true
  case "$reply" in
    yes) actual=yes ;;
    no | "no - "*) actual=no ;;
    *) fail "kubectl auth can-i $verb $resource${*:+ $*} as $account answered '$reply'" ;;
  esac
  [ "$actual" = "$expected" ] || fail "$account may$([ "$expected" = no ] || echo ' not') $verb $resource${*:+ $*}"
}

# The requests every account is asked; only the web's get and delete on the worker's pod are allowed.
requests=(
  "get pods/$worker_pod"
  "delete pods/$worker_pod"
  "list pods"
  "watch pods"
  "create pods"
  "patch pods/$worker_pod"
  "update pods/$worker_pod"
  "deletecollection pods"
  "get pods/$other_pod"
  "delete pods/$other_pod"
  "get pods/$worker_pod --subresource=log"
  "get pods/$worker_pod --subresource=exec"
  "create pods/$worker_pod --subresource=exec"
  "get secrets"
  "list secrets"
)
for request in "${requests[@]}"; do
  read -r -a words <<<"$request"
  case "$request" in
    "get pods/$worker_pod" | "delete pods/$worker_pod") web_expected=yes ;;
    *) web_expected=no ;;
  esac
  expect "$web_account" "$web_expected" "${words[@]}"
  expect "$worker_account" no "${words[@]}"
done
echo "$web_account may get and delete pods/$worker_pod and nothing else asked; $worker_account may do none of it"
