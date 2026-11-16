#!/usr/bin/env bash
# Run in every part: the root and every layer of the part's closure (tests/flux/part_closure.sh) are Ready and applied
# the candidate commit. A layer outside the closure was deleted from the root's patches and never exists.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
step_started_at="$(date +%s)"
kubectl -n flux-system wait gitrepository/flux-system --for=condition=Ready --timeout=3m
kubectl -n flux-system wait kustomization/flux-system --for=condition=Ready --timeout=5m
wait_status=0
kubectl wait kustomizations.kustomize.toolkit.fluxcd.io --all --all-namespaces --for=condition=Ready --timeout=6m ||
  wait_status=$?
"$(dirname "${BASH_SOURCE[0]}")/print_ready_times.sh" "$step_started_at"
[ "$wait_status" -eq 0 ] || exit "$wait_status"
kubectl -n flux-system get gitrepository flux-system -o yaml

source_revision="$(kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}')"
applied_revision="$(kubectl -n flux-system get kustomization flux-system -o jsonpath='{.status.lastAppliedRevision}')"
[ "$source_revision" = "${CANDIDATE_BRANCH}@sha1:${CANDIDATE_REVISION}" ] ||
  fail "the artifact revision '$source_revision' is not ${CANDIDATE_BRANCH}@sha1:${CANDIDATE_REVISION}"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "revision '$applied_revision' is not the candidate $CANDIDATE_REVISION"
echo "candidate revision:                   $CANDIDATE_REVISION"
echo "GitRepository artifact revision:      $source_revision"
echo "Kustomization lastAppliedRevision:    $applied_revision"

