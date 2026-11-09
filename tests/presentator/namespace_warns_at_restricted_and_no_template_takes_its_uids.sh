#!/usr/bin/env bash
# Rows 11 and 13 of presentator's table read this repository's own files, which
# pods_stay_within_their_levels.sh, called by presentator at a pinned commit, does not see: the Namespace presentator
# enforces nothing and warns and audits at restricted, and no Pod template of a layer names the build or wire uid.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
markers="$(yq --no-doc 'select(.kind == "Namespace" and .metadata.name == "presentator")
  | (.metadata.labels | keys | map(select(test("^pod-security[.]kubernetes[.]io/enforce"))) | join(",")) + "|"
  + .metadata.labels["pod-security.kubernetes.io/warn"] + "|" + .metadata.labels["pod-security.kubernetes.io/audit"] + "|"
  + .metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]' infrastructure/namespaces/namespaces.yaml)"
[ "$markers" = "|restricted|restricted|disabled" ] ||
  fail "the Namespace presentator reads '$markers', not no enforced level, warn and audit restricted, and prune disabled"
echo "the Namespace presentator enforces no level, warns and audits at restricted, and is never pruned"
# The build and wire uids of presentator's image; a template that names either shares its RLIMIT_NPROC count.
census() {
  yq --no-doc '(.spec.template.spec // .spec.jobTemplate.spec.template.spec // (select(.kind == "Pod") | .spec)) as $spec
    | select($spec != null)
    | select(($spec | [.securityContext.runAsUser, .securityContext.runAsGroup, ((.initContainers[], .containers[]) | (.securityContext.runAsUser, .securityContext.runAsGroup))]
      | map(select(. == 61001 or . == 61002)) | length) > 0)
    | .kind + "/" + .metadata.name' "$@"
}
layers="$(mktemp -d)"
kubectl kustomize apps/presentator >"$layers/presentator.yaml"
for path in $(yq --no-doc 'select(.kind == "Kustomization" and (.apiVersion | test("^kustomize[.]toolkit[.]fluxcd[.]io/"))) | .spec.path' clusters/pc/apps.yaml clusters/pc/infrastructure.yaml | grep -E '^[.]/(apps|infrastructure)/'); do
  if [ -f "$path/kustomization.yaml" ]; then
    kubectl kustomize "$path" >"$layers/$(tr '/' '_' <<<"${path#./}").yaml"
  else
    for file in "$path"/*.yaml; do cp "$file" "$layers/$(tr '/' '_' <<<"${path#./}")_${file##*/}"; done
  fi
done
[ -z "$(census "$layers"/*.yaml)" ] || fail "a Pod template names 61001 or 61002: $(census "$layers"/*.yaml)"
echo "no Pod template of a layer names 61001 or 61002"
for mutation in '.spec.template.spec.securityContext.runAsUser = 61001' \
  '.spec.template.spec.containers[0].securityContext.runAsGroup = 61002'; do
  [ -n "$(yq "(select(.kind == \"Deployment\" and .metadata.name == \"web\") | $mutation)" "$layers/presentator.yaml" | census)" ] ||
    fail "the census does not see a template at 61001 or 61002 through '$mutation'"
done
echo "the census names a template at either uid"

