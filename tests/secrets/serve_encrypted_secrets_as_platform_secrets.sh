#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
repository=platform-secrets
tag=candidate
flux push artifact "oci://localhost:${REGISTRY_PORT}/${repository}:${tag}" --path="$SECRETS_ARTIFACT_DIR" \
  --source="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" \
  --revision="${GITHUB_REF_NAME}@sha1:${CANDIDATE_REVISION}" --insecure-registry

# The cluster reaches the registry by its address on the cluster's network, which needs no record in CoreDNS.
network="k3d-${CLUSTER_NAME}"
registry_address="$(docker inspect "k3d-${REGISTRY_NAME}" --format "{{(index .NetworkSettings.Networks \"${network}\").IPAddress}}")" || registry_address=""
[ -n "$registry_address" ] || fail "no address of the registry k3d-${REGISTRY_NAME} could be read from the docker network $network"

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
source="${source//@REPOSITORY@/${registry_address}:${REGISTRY_PORT}/${repository}}"
printf '%s\n' "${source//@TAG@/${tag}}" | kubectl apply --server-side -f -
