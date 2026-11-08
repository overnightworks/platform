#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
inventory() {
  kubectl -n flux-system get kustomization flux-system \
    -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}'
}
assert_job_source() {
  local kind entries value
  kind="$(kubectl -n flux-system get kustomization platform-secrets -o jsonpath='{.spec.sourceRef.kind}')"
  [ "$kind" = OCIRepository ] || fail "the Kustomization platform-secrets runs on a $kind, not the job's OCIRepository"
  echo "the Kustomization platform-secrets runs on the job's OCIRepository"
  [ -z "$(kubectl -n flux-system get gitrepository platform-secrets --ignore-not-found -o name)" ] ||
    fail "the GitRepository platform-secrets exists, though CI never fetches it"
  echo "no GitRepository platform-secrets exists"
  entries="$(inventory)"
  for entry in flux-system_flux-system_kustomize.toolkit.fluxcd.io_Kustomization \
    flux-system_platform-secrets_source.toolkit.fluxcd.io_GitRepository; do
    if grep -qxF "$entry" <<<"$entries"; then fail "the flux-system inventory holds $entry"; fi
    echo "inventory lacks: $entry"
  done
  value="$(kubectl -n "$PROOF_SECRET_NAMESPACE" get secret "$PROOF_SECRET_NAME" -o jsonpath='{.data.value}' |
    base64 --decode)"
  [ "$value" = "$(<"$DUMMY_FILE")" ] || fail "the Secret $PROOF_SECRET_NAME does not hold the dummy"
  echo "the Secret $PROOF_SECRET_NAME, decrypted by Flux, holds the dummy the job generated"
}

kubectl -n flux-system wait gitrepository/flux-system --for=condition=Ready --timeout=3m
kubectl -n flux-system wait kustomization/flux-system --for=condition=Ready --timeout=5m
kubectl wait kustomizations.kustomize.toolkit.fluxcd.io --all --all-namespaces --for=condition=Ready --timeout=10m
kubectl -n flux-system get gitrepository flux-system -o yaml

source_revision="$(kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}')"
applied_revision="$(kubectl -n flux-system get kustomization flux-system -o jsonpath='{.status.lastAppliedRevision}')"
for revision in "$source_revision" "$applied_revision"; do
  [ "${revision##*@sha1:}" = "$CANDIDATE_REVISION" ] || fail "revision '$revision' is not the candidate $CANDIDATE_REVISION"
done
echo "candidate revision:                   $CANDIDATE_REVISION"
echo "GitRepository artifact revision:      $source_revision"
echo "Kustomization lastAppliedRevision:    $applied_revision"

entries="$(inventory)"
for entry in flux-system_flux-system_source.toolkit.fluxcd.io_GitRepository \
  flux-system_source-controller_apps_Deployment flux-system_kustomize-controller_apps_Deployment \
  flux-system_notification-controller_apps_Deployment; do
  grep -qxF "$entry" <<<"$entries" || fail "the flux-system inventory lacks $entry"
  echo "inventory holds: $entry"
done

# The root health-checks exactly the Deployments in its inventory and its own source, compared as
# inventory ids so that kind and namespace count; an unset namespace is the root's, as in Flux.
root_namespace=flux-system
health_checks="$(kubectl -n "$root_namespace" get kustomization flux-system \
  -o jsonpath='{range .spec.healthChecks[*]}{.namespace}{"|"}{.name}{"|"}{.apiVersion}{"|"}{.kind}{"\n"}{end}')"
health_check_ids="$(while IFS='|' read -r namespace name api_version kind; do
    group=""
    [[ $api_version != */* ]] || group="${api_version%/*}"
    echo "${namespace:-$root_namespace}_${name}_${group}_${kind}"
  done <<<"$health_checks" | sort -u)"
source_ref="$(kubectl -n "$root_namespace" get kustomization flux-system \
  -o jsonpath='{.spec.sourceRef.namespace}{"|"}{.spec.sourceRef.name}{"|"}{.spec.sourceRef.kind}')"
IFS='|' read -r source_namespace source_name source_kind <<<"$source_ref"
expected_ids="$( {
    grep -E '_Deployment$' <<<"$entries" || true
    grep -E "^${source_namespace:-$root_namespace}_${source_name}_[^_]*_${source_kind}\$" <<<"$entries" || true
  } | sort -u)"
mismatch="$(comm -3 <(printf '%s\n' "$expected_ids") <(printf '%s\n' "$health_check_ids"))"
if [ -n "$mismatch" ]; then
  while IFS= read -r id; do
    case "$id" in
      $'\t'*) echo "::error::the root health-checks ${id#$'\t'}, neither a Deployment in its inventory nor its own source" ;;
      *) echo "::error::the root's inventory holds $id without a health check" ;;
    esac
  done <<<"$mismatch"
  exit 1
fi
sed 's/^/the root health-checks: /' <<<"$health_check_ids"

assert_job_source

# allow-scraping only admits metrics scrapes; deleting allow-egress would cut the controllers off each other.
kubectl -n flux-system delete networkpolicy allow-scraping
flux reconcile kustomization flux-system --with-source --timeout=5m
kubectl -n flux-system get networkpolicy allow-scraping

if [ "$GITHUB_EVENT_NAME" = pull_request ]; then
  source_ref="$(kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.spec.ref.name}')"
  [ "$source_ref" = "$PULL_REQUEST_REF" ] || fail "the source ref '$source_ref' left $PULL_REQUEST_REF"
else
  source_ref="$(kubectl -n flux-system get gitrepository flux-system -o go-template='{{.spec.ref}}')"
  committed_ref="$(kubectl create --dry-run=client -f clusters/pc/flux-system/gotk-sync.yaml \
    -o go-template='{{if eq .kind "GitRepository"}}map[branch:{{.spec.ref.branch}} commit:'"$CANDIDATE_REVISION"']{{end}}')"
  [ "$source_ref" = "$committed_ref" ] || fail "the source ref '$source_ref' is not the committed branch at the candidate '$committed_ref'"
fi
echo "GitRepository spec.ref after the reconcile: $source_ref"
assert_job_source
