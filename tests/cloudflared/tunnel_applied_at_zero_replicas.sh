#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/failure.sh"
# platform-secrets runs on the job's own source, whose revision is its artifact's digest.
for kustomization in namespaces tunnel; do
  applied_revision="$(kubectl -n flux-system get kustomization "$kustomization" \
    -o jsonpath='{.status.lastAppliedRevision}')"
  [ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
    fail "the Kustomization $kustomization applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
  echo "the Kustomization $kustomization is Ready at the candidate"
done

replicas="$(kubectl -n "$TUNNEL_NAMESPACE" get deployment cloudflared -o jsonpath='{.spec.replicas}')"
[ "$replicas" = 0 ] || fail "the Deployment cloudflared runs $replicas replicas in the job, not 0"
echo "the Deployment cloudflared is applied at 0 replicas"
