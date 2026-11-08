#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/failure.sh"
layer() { kubectl --namespace "${1%/*}" get kustomization "${1#*/}" -o jsonpath="$2"; }

for manifest in $APP_MANIFESTS; do
  app_layer="flux-system/$(basename "$(dirname "$manifest")")"
  applied_revision="$(layer "$app_layer" '{.status.lastAppliedRevision}')"
  [ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
    fail "the Kustomization $app_layer applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
  [[ " $(layer "$app_layer" '{.spec.dependsOn[*].name}') " == *" ${SECRETS_LAYER#*/} "* ]] ||
    fail "the Kustomization $app_layer does not depend on $SECRETS_LAYER"
  echo "the Kustomization $app_layer applied the candidate and depends on $SECRETS_LAYER"

  deployment="$(yq 'select(.kind == "Deployment") | .metadata.namespace + "/" + .metadata.name' "$manifest")"
  namespace="${deployment%/*}" name="${deployment#*/}"
  markers="$(kubectl get namespace "$namespace" \
    -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}|{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}')"
  [ "$markers" = "restricted|disabled" ] ||
    fail "the Namespace $namespace reads '$markers', not Pod Security restricted and prune disabled"
  echo "the Namespace $namespace enforces restricted, and Flux never prunes it"

  kubectl --namespace "$namespace" wait "deployment/$name" --for=condition=Available --timeout=3m
  state="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.status.readyReplicas}|{.spec.strategy.type}')"
  [ "$state" = "1|Recreate" ] || fail "the Deployment $deployment reads '$state', not one Ready pod and Recreate"
  image="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.spec.template.spec.containers[*].image}')"
  [[ $image =~ ^ghcr[.]io/${GITHUB_REPOSITORY_OWNER,,}/[^[:space:]:@]+:[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] ||
    fail "the Deployment $deployment runs '$image', not one full app ref"
  echo "the Deployment $deployment is Available with one Ready pod, Recreate, and runs the full app ref $image"
  # What the image cost the runner: the kubelet's own report of each pull, and the disk after it.
  kubectl --namespace "$namespace" get events --field-selector reason=Pulled \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}'
  df --human-readable /

  # The Secrets the pod pulls and starts from are platform-secrets' objects, there before the Deployment.
  created="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.metadata.creationTimestamp}')"
  secrets_inventory="$(layer "$SECRETS_LAYER" '{range .status.inventory.entries[*]}{.id}{"\n"}{end}')"
  pull_secrets="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}')"
  [ -n "$pull_secrets" ] || fail "the Deployment $deployment names no pull Secret"
  for secret in $pull_secrets $(kubectl --namespace "$namespace" get deployment "$name" \
    -o jsonpath='{.spec.template.spec.volumes[*].secret.secretName}'); do
    grep -qxF "${namespace}_${secret}__Secret" <<<"$secrets_inventory" ||
      fail "the Secret $namespace/$secret is not in the inventory of $SECRETS_LAYER"
    secret_created="$(kubectl --namespace "$namespace" get secret "$secret" -o jsonpath='{.metadata.creationTimestamp}')"
    [[ ! $created < "$secret_created" ]] ||
      fail "the Deployment $deployment was created at $created, before its Secret $secret at $secret_created"
    echo "the Secret $namespace/$secret of $SECRETS_LAYER was created at $secret_created, not after the Deployment at $created"
  done
  for secret in $pull_secrets; do
    type="$(kubectl --namespace "$namespace" get secret "$secret" -o jsonpath='{.type}')"
    [ "$type" = kubernetes.io/dockerconfigjson ] || fail "the pull Secret $namespace/$secret is of type $type"
  done
  echo "the Deployment $deployment pulled its private image through $pull_secrets"
done
