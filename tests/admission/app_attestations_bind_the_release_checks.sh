#!/usr/bin/env bash
# Read what the attestation check is made of and fail where one part drifts from another: the render of Kyverno (one
# admission controller, no hook, every image at a listed digest, bootstrap exclusion on, generation-label protection off,
# no Namespace), the policy (fail closed, no rewrite, 30 seconds, no controller kind, its credential in Kyverno's
# namespace), the live webhooks (the system namespaces excluded, both match conditions present, rules naming exactly the
# Pod resources, no mutating webhook for Pods, the live replicas equal to the render's), the release checks in
# scripts/verify_image_release.sh (issuer, ref, predicate type and signer, read from both files), the attestors against
# the repositories of the live app refs, and the prefix the form rule shares with the policy.
# Needs GITHUB_REPOSITORY_OWNER, ATTESTATION_LAYER, VENDOR_LIST, POLICY_FILE (the form rule), RELEASE_SCRIPT and
# ADMISSION_SCRIPT, and kubectl on the cluster.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
owner="${GITHUB_REPOSITORY_OWNER,,}"
render="$ATTESTATION_LAYER/rendered.yaml"
policy_file="$ATTESTATION_LAYER/app-attestations.yaml"
policy() { yq "select(.kind == \"ImageValidatingPolicy\") | $1" "$policy_file"; }
constant() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$2"; }
equal() { [ "$2" = "$3" ] || fail "$1: '$2', not '$3'"; }

# The render.
equal "the Deployments of the render" "$(yq --no-doc 'select(.kind == "Deployment") | .metadata.name' "$render")" kyverno-admission-controller
equal "the replicas of the render" "$(yq 'select(.kind == "Deployment") | .spec.replicas' "$render")" 1
equal "the hooks of the render" "$(yq --no-doc 'select(.metadata.annotations["helm.sh/hook"]) | .kind' "$render")" ""
equal "the Namespaces of the render" "$(yq --no-doc 'select(.kind == "Namespace") | .kind' "$render")" ""
for argument in --excludeBootstrapResources=true --protectGenerationLabels=false --generateValidatingAdmissionPolicy=false; do
  [ "$(yq "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].args[] | select(. == \"$argument\")" "$render")" = "$argument" ] ||
    fail "the admission controller runs without $argument"
done
vendors="$(yq '.data[]' "$VENDOR_LIST")"
while IFS= read -r image; do
  [[ $image =~ ^(.+):[^:@/]+@sha256:[0-9a-f]{64}$ ]] || fail "Kyverno runs '$image', not a tag at a sha256 digest"
  grep -qxF "${BASH_REMATCH[1]}" <<<"$vendors" || fail "Kyverno runs '$image', whose repository is no listed vendor"
done < <(yq --no-doc 'select(.kind == "Deployment") | (.spec.template.spec.containers[].image, .spec.template.spec.initContainers[].image)' "$render")
echo "the render holds one admission controller at 1 replica with listed images at digests, no hook and no Namespace"

# The policy.
equal "failurePolicy" "$(policy .spec.failurePolicy)" Fail
equal "validationActions" "$(policy '.spec.validationActions | join(",")')" Deny
equal "mutateDigest" "$(policy .spec.validationConfigurations.mutateDigest)" false
equal "verifyDigest" "$(policy .spec.validationConfigurations.verifyDigest)" true
equal "required" "$(policy .spec.validationConfigurations.required)" true
equal "timeoutSeconds" "$(policy .spec.webhookConfiguration.timeoutSeconds)" 30
equal "autogen controllers" "$(policy '.spec.autogen.podControllers.controllers | length')" 0
kyverno_namespace="$(yq 'select(.kind == "Deployment") | .metadata.namespace' "$render")"
credential="$(policy '.spec.credentials.secrets[0]')"
kubectl --namespace "$kyverno_namespace" get secret "$credential" >/dev/null || fail "the credential $credential is not a Secret of $kyverno_namespace"
echo "the policy fails closed, rewrites no ref, reads $kyverno_namespace/$credential and has no controller kind"

# The live webhooks Kyverno manages, found by the label scripts/pause_or_resume_attestation_check.sh deletes them by.
webhook_selector="$(sed -n 's/^webhook_selector="\(.*\)"$/\1/p' "$ADMISSION_SCRIPT")"
[ -n "$webhook_selector" ] || fail "$ADMISSION_SCRIPT names no webhook_selector"
webhooks="$(kubectl get validatingwebhookconfiguration --selector "$webhook_selector" -o json)"
pod_webhooks="$(jq --compact-output '[.items[].webhooks[] | select(any((.rules // [])[].resources[]; . == "pods"))]' <<<"$webhooks")"
[ "$(jq length <<<"$pod_webhooks")" -gt 0 ] || fail "no live webhook of Kyverno reaches Pods"
jq --exit-status --argjson expressions "$(policy '[.spec.matchConditions[] | select(.name == "app-ref" or .name == "image-change") | .expression]' | yq -o json -I 0)" '
  all(.[]; .failurePolicy == "Fail"
    and ([.namespaceSelector.matchExpressions[] | select(.operator == "NotIn" and .key == "kubernetes.io/metadata.name") | .values[]]
      | (index("kube-system") != null and index("flux-system") != null and index("admission") != null))
    and ([.rules[] | .resources[] ] | unique == ["pods", "pods/ephemeralcontainers"])
    and ([.rules[] | select(.resources == ["pods"]) | .operations[]] | sort == ["CREATE", "UPDATE"])
    and ([.rules[] | select(.resources == ["pods/ephemeralcontainers"]) | .operations[]] == ["UPDATE"])
    and (any(.matchConditions[]; .name == "kyverno-exclude-bootstrap-resources"))
    and ([.matchConditions[].expression] as $have | all($expressions[]; . as $expression | any($have[]; contains($expression)))))' \
  <<<"$pod_webhooks" >/dev/null || fail "a live webhook that reaches Pods lacks an exclusion, fail closed, a match condition, the bootstrap condition or has other rules: $pod_webhooks"
mutating="$(kubectl get mutatingwebhookconfiguration --selector "$webhook_selector" -o json | jq '[.items[].webhooks[] | select(any((.rules // [])[].resources[]; . == "pods"))] | length')"
equal "the mutating webhooks of Kyverno that reach Pods" "$mutating" 0
equal "the live replicas" "$(kubectl --namespace "$kyverno_namespace" get deployment kyverno-admission-controller -o jsonpath='{.spec.replicas}')" \
  "$(yq 'select(.kind == "Deployment") | .spec.replicas' "$render")"
echo "every live webhook of Kyverno that reaches Pods excludes the system namespaces, fails closed and carries both match conditions"

# The release checks.
issuer="$(constant RELEASE_OIDC_ISSUER "$RELEASE_SCRIPT")"
signer_repository="$(constant SIGNER_REPOSITORY_NAME "$RELEASE_SCRIPT")"
signer_workflow="$(constant SIGNER_WORKFLOW "$RELEASE_SCRIPT")"
equal "the issuer of the first attestor" "$(policy '.spec.attestors[0].cosign.keyless.identities[0].issuer')" "$issuer"
equal "the predicate type" "$(policy '.spec.attestations[0].intoto.type')" "$(constant RELEASE_PREDICATE_TYPE "$RELEASE_SCRIPT")"
equal "the attestors' issuers" "$(policy '[.spec.attestors[].cosign.keyless.identities[].issuer] | unique | join(",")')" "$issuer"
equal "the attestors' refs" "$(policy '[.spec.attestors[].cosign.keyless.additionalExtensions.githubWorkflowRef] | unique | join(",")')" \
  "$(constant RELEASE_SOURCE_REF "$RELEASE_SCRIPT")"
equal "the attestors' subjects" "$(policy '[.spec.attestors[].cosign.keyless.identities[].subjectRegExp] | unique | length')" 1
subject="$(policy '.spec.attestors[0].cosign.keyless.identities[0].subjectRegExp')"
sha="$(printf 'a%.0s' {1..40})"
grep -qE "$subject" <<<"https://github.com/$owner/$signer_repository/$signer_workflow@$sha" ||
  fail "the subject '$subject' refuses quality's $signer_workflow at a pinned SHA"
! grep -qE "$subject" <<<"https://github.com/$owner/$signer_repository/.github/workflows/other.yml@$sha" ||
  fail "the subject '$subject' admits another workflow file of quality"
! grep -qE "$subject" <<<"https://github.com/$owner/other/$signer_workflow@$sha" || fail "the subject '$subject' admits another repository"
echo "the policy's issuer, subject, ref and predicate type are the release script's"

# The attestors against the live app refs.
expected="$(kubectl get deployments,statefulsets,jobs --all-namespaces -o json | jq --raw-output --arg prefix "ghcr.io/$owner/" '
  [.items[].spec.template.spec | (((.containers // []) + (.initContainers // []))[].image, ((.volumes // [])[] | .image.reference // empty))
    | select(startswith($prefix)) | ltrimstr($prefix) | split("/")[0] | split(":")[0] | split("@")[0] | "'"$owner"'/" + .] | unique[]')"
equal "the attestors' repositories" "$(policy '[.spec.attestors[].cosign.keyless.additionalExtensions.githubWorkflowRepository] | sort | .[]')" "$expected"
echo "the attestors' repositories are those of the live app refs: ${expected//$'\n'/ }"

# The prefix.
prefix="ghcr.io/$owner/"
equal "the glob" "$(policy '.spec.matchImageReferences[0].glob')" "$prefix*"
equal "the strings of the policy that hold the prefix" "$(policy '[.. | select(tag == "!!str" and contains("'"$prefix"'"))] | length')" 2
equal "the match condition's prefix" "$(policy '.spec.matchConditions[] | select(.name == "app-ref") | .expression | contains("'"'$prefix'"'")')" true
[ -n "$(yq "select(.kind == \"ValidatingAdmissionPolicy\") | .. | select(tag == \"!!str\" and contains(\"ghcr[.]io/$owner/\"))" "$POLICY_FILE")" ] ||
  fail "the form rule's pattern in $POLICY_FILE does not name ghcr[.]io/$owner/"
echo "the prefix is $prefix in the policy, twice, and in the form rule"
