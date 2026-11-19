#!/usr/bin/env bash
# Probe the attestation check by server-side dry-run: a generated-digest app ref under hopin and under songmaker/web, in
# a container and in an init container only, in an image volume, is refused by the policy and by no failed webhook call
# (the nested repository guards the glob's * crossing /); a live presentator Pod patched in place to such a ref is
# refused while a label-only patch of it is admitted; a throwaway copy of the policy that names another repository for
# hopin refuses hopin's real ref beside the real policy, which keeps admitting it, and the copy is deleted on every exit;
# and a Pod of a vendor image reaches no answer from Kyverno's Service, which the API server's calls still reach.
# Needs PROBE_NAMESPACE, PROBE_IMAGE, ATTESTATION_LAYER, HOPIN_MANIFEST, LIVE_APP_NAMESPACE and GITHUB_REPOSITORY_OWNER.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
owner="${GITHUB_REPOSITORY_OWNER,,}"
policy_file="$ATTESTATION_LAYER/app-attestations.yaml"
policy_name="$(yq 'select(.kind == "ImageValidatingPolicy") | .metadata.name' "$policy_file")"
app_prefix="$(yq 'select(.kind == "ImageValidatingPolicy") | .spec.matchImageReferences[0].glob | sub("[*]$"; "")' "$policy_file")"
service="$(yq 'select(.kind == "Service" and (.metadata.name | test("-metrics$") | not)) | .metadata.name + "." + .metadata.namespace' "$ATTESTATION_LAYER/rendered.yaml")"
service_port="$(yq 'select(.kind == "Service" and (.metadata.name | test("-metrics$") | not)) | .spec.ports[0].port' "$ATTESTATION_LAYER/rendered.yaml")"
sentinel_name="${policy_name}-sentinel"

cleanup() {
  local cell_status=$?
  delete_object delete imagevalidatingpolicy "$sentinel_name" --ignore-not-found
  delete_object delete namespace "$PROBE_NAMESPACE" --ignore-not-found --wait=false
  end_deletions "$cell_status"
}
trap cleanup EXIT
kubectl create namespace "$PROBE_NAMESPACE"
kubectl --namespace "$PROBE_NAMESPACE" wait serviceaccount/default --for=create --timeout=1m

pod_yaml() { # <containers> [<initContainers>]
  echo "{apiVersion: v1, kind: Pod, metadata: {name: probe}, spec: {restartPolicy: Never, containers: [$1]${2:+, initContainers: [$2]}}}"
}
container() { echo "{name: $1, image: '$2'}"; }
dry_run() { kubectl --namespace "$PROBE_NAMESPACE" create --dry-run=server -f -; }
refused_by_policy() { # <what> <pod yaml>
  local output
  if output="$(dry_run <<<"$2" 2>&1)"; then fail "$1 was admitted"; fi
  [[ $output == *"$policy_name"* ]] || fail "$1 was refused without naming $policy_name: $output"
  [[ $output != *"failed calling webhook"* ]] || fail "$1 met a failed webhook call: $output"
  [[ $output != *"no such "* ]] || fail "$1 met an evaluation error of the policy, not its check: $output"
  refusal="$output"
  echo "refused by $policy_name: $1"
}
generated() { echo "$app_prefix$1:v1.0.0@sha256:$(openssl rand -hex 32)"; }

# A generated digest has no attestation: the refusal is Kyverno's, which also shows the API server reaches it.
for repository in hopin songmaker/web; do
  image="$(generated "$repository")"
  refused_by_policy "$image in a container" "$(pod_yaml "$(container app "$image")")"
  refused_by_policy "$image in an init container only" "$(pod_yaml "$(container app "$PROBE_IMAGE")" "$(container setup "$image")")"
done
# An app ref whose repository has no attestor, or only shares a prefix with one, is refused by the policy's own message.
message="$(yq 'select(.kind == "ImageValidatingPolicy") | .spec.validations[0].message' "$policy_file")"
for repository in unattested hopin-evil; do
  image="$(generated "$repository")"
  refused_by_policy "$image in a container" "$(pod_yaml "$(container app "$image")")"
  [[ $refusal == *"$message"* ]] || fail "$image was refused without the policy's message: $refusal"
done
image="$(generated hopin)"
refused_by_policy "$image as an image volume" "{apiVersion: v1, kind: Pod, metadata: {name: probe}, spec: {restartPolicy: Never,
  containers: [$(container app "$PROBE_IMAGE")], volumes: [{name: image, image: {reference: '$image'}}]}}"

# A live app Pod patched in place meets Kyverno on its image change and not on a label.
live_pod="$(kubectl --namespace "$LIVE_APP_NAMESPACE" get pods -o json | jq --raw-output --arg prefix "$app_prefix" \
  '[.items[] | select(.spec.containers[0].image | startswith($prefix)) | .metadata.name][0] // empty')"
[ -n "$live_pod" ] || fail "no Pod of $LIVE_APP_NAMESPACE runs an app ref"
patch="[{\"op\": \"replace\", \"path\": \"/spec/containers/0/image\", \"value\": \"$(generated presentator)\"}]"
if output="$(kubectl --namespace "$LIVE_APP_NAMESPACE" patch pod "$live_pod" --type=json --patch "$patch" --dry-run=server 2>&1)"; then
  fail "$live_pod patched to a generated digest was admitted"
fi
[[ $output == *"$policy_name"* ]] || fail "the patch of $live_pod was refused without naming $policy_name: $output"
kubectl --namespace "$LIVE_APP_NAMESPACE" patch pod "$live_pod" --type=merge --patch '{"metadata": {"labels": {"attested-probe": "1"}}}' \
  --dry-run=server >/dev/null || fail "a label-only patch of $live_pod was refused"
echo "the in-place image change of $live_pod is refused and its label-only patch admitted"

# One policy's cached success does not serve another: a copy that names another repository for hopin refuses hopin's ref.
hopin_image="$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$HOPIN_MANIFEST")"
hopin_pod="$(pod_yaml "$(container app "$hopin_image")")"
dry_run <<<"$hopin_pod" >/dev/null || fail "hopin's ref $hopin_image was refused before the copy existed"
OWNER="$owner" PROBE="$PROBE_NAMESPACE" NAME="$sentinel_name" yq 'select(.kind == "ImageValidatingPolicy") | .metadata.name = strenv(NAME)
  | .spec.matchConstraints.namespaceSelector = {"matchExpressions": [{"key": "kubernetes.io/metadata.name", "operator": "In", "values": [strenv(PROBE)]}]}
  | (.spec.attestors[] | select(.name == "hopin") | .cosign.keyless.additionalExtensions.githubWorkflowRepository) = strenv(OWNER) + "/presentator"' \
  "$policy_file" | kubectl apply -f -
kubectl wait "imagevalidatingpolicy/$sentinel_name" --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout=2m
refused_copy() {
  local output
  ! output="$(dry_run <<<"$hopin_pod" 2>&1)" && [[ $output == *"$sentinel_name"* ]]
}
until_true 90 "hopin's ref refused by $sentinel_name beside the real policy" refused_copy
kubectl delete "imagevalidatingpolicy/$sentinel_name" --wait
admitted_again() { dry_run <<<"$hopin_pod" >/dev/null; }
until_true 90 "hopin's ref admitted again after $sentinel_name was deleted" admitted_again
echo "the copy refused hopin's ref and was deleted, and the real policy admits it again"

# Nothing but the API server reaches Kyverno: a vendor-image Pod gets no answer from its Service.
kubectl --namespace "$PROBE_NAMESPACE" apply -f - <<<"{apiVersion: v1, kind: Pod, metadata: {name: reach}, spec: {restartPolicy: Never, containers: [{name: reach, image: '$PROBE_IMAGE',
  command: [sh, -c, 'nc -w 5 ${service%%.*}.${service#*.}.svc $service_port </dev/null; echo \"exit=\$?\"']}]}}"
kubectl --namespace "$PROBE_NAMESPACE" wait pod/reach --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m
reach_log="$(kubectl --namespace "$PROBE_NAMESPACE" logs reach)"
[[ $reach_log == *"exit=0"* ]] && fail "a Pod of namespace $PROBE_NAMESPACE connected to $service:$service_port: $reach_log"
echo "a Pod of namespace $PROBE_NAMESPACE gets no answer from $service:$service_port: ${reach_log//$'\n'/ }"
