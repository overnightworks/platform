#!/usr/bin/env bash
set -euo pipefail
repository=platform-secrets
tag=candidate
flux push artifact "oci://localhost:${REGISTRY_PORT}/${repository}:${tag}" --path="$SECRETS_ARTIFACT_DIR" \
  --source="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" \
  --revision="${GITHUB_REF_NAME}@sha1:${CANDIDATE_REVISION}" --insecure-registry

# Applied outside Flux's inventory: the root's patches point the Kustomization platform-secrets at it.
source="$(cat <<'YAML'
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: platform-secrets
  namespace: flux-system
spec:
  interval: 1m0s
  url: oci://@REPOSITORY@
  ref:
    tag: @TAG@
  insecure: true
YAML
)"
source="${source//@REPOSITORY@/${REGISTRY_NAME}:${REGISTRY_PORT}/${repository}}"
printf '%s\n' "${source//@TAG@/${tag}}" | kubectl apply --server-side -f -
