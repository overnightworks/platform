#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The policy with the vendor list as its parameter, and the system namespaces' policy without one.
policy="$(yq 'select(.kind == "ValidatingAdmissionPolicy" and .spec.paramKind != null) | .metadata.name' "$POLICY_FILE")"
binding="$(yq 'select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.paramRef != null) | .metadata.name' "$POLICY_FILE")"
system_policy="$(yq 'select(.kind == "ValidatingAdmissionPolicy" and .spec.paramKind == null) | .metadata.name' "$POLICY_FILE")"
system_binding="$(yq 'select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.paramRef == null) | .metadata.name' "$POLICY_FILE")"
vendor_list="$(yq '.metadata.namespace + "/" + .metadata.name' "$VENDOR_LIST")"
failure_policy="$(kubectl get validatingadmissionpolicy "$policy" -o jsonpath='{.spec.failurePolicy}')"
[ "$failure_policy" = Fail ] || fail "the policy $policy has failurePolicy '$failure_policy', not Fail"
settings="$(kubectl get validatingadmissionpolicybinding "$binding" -o jsonpath='{.spec.policyName}|{.spec.validationActions[*]}|{.spec.paramRef.namespace}/{.spec.paramRef.name}|{.spec.paramRef.parameterNotFoundAction}')"
[ "$settings" = "$policy|Deny|$vendor_list|Deny" ] ||
  fail "the binding $binding reads '$settings', not '$policy|Deny|$vendor_list|Deny'"
echo "$policy fails closed; $binding only denies, reads $vendor_list and denies without it"

# The system namespaces are exactly those the first policy leaves out, and nothing there reads the vendor list.
exempt=" $(kubectl get validatingadmissionpolicy "$policy" -o jsonpath='{.spec.matchConstraints.namespaceSelector.matchExpressions[?(@.operator=="NotIn")].values[*]}') "
settings="$(kubectl get validatingadmissionpolicy "$system_policy" -o jsonpath='{.spec.failurePolicy}|{.spec.paramKind}| {.spec.matchConstraints.namespaceSelector.matchExpressions[?(@.operator=="In")].values[*]} ')"
[ "$settings" = "Fail||$exempt" ] || fail "the policy $system_policy reads '$settings', not 'Fail||$exempt'"
settings="$(kubectl get validatingadmissionpolicybinding "$system_binding" -o jsonpath='{.spec.policyName}|{.spec.validationActions[*]}|{.spec.paramRef}')"
[ "$settings" = "$system_policy|Deny|" ] || fail "the binding $system_binding reads '$settings', not '$system_policy|Deny|'"
echo "$system_policy fails closed in the namespaces$exempt; $system_binding only denies and reads no parameter"
# Both policies find a Pod spec's images through the same first three variables.
shared_variables() {
  yq -o json -I 0 "select(.kind == \"ValidatingAdmissionPolicy\" and .metadata.name == \"$1\") | .spec.variables[0:3]" "$POLICY_FILE"
}
[ "$(shared_variables "$policy")" = "$(shared_variables "$system_policy")" ] ||
  fail "the first three variables of $system_policy differ from those of $policy"
# What flux-system admits follows the controllers that gotk-components.yaml runs.
mapfile -t controller_refs < <(yq --no-doc 'select(.kind == "Deployment") | .spec.template.spec.containers[].image' \
  "$FLUX_COMPONENTS_FILE")
controller_repositories="$(printf '%s\n' "${controller_refs[@]%:*}" | sort -u)"
admitted_repositories="$(kubectl get validatingadmissionpolicy "$system_policy" \
  -o jsonpath='{.spec.variables[?(@.name=="controllerRepositories")].expression}' | grep -oE "'[^']+'" | tr -d "'" | sort -u)"
[ "$admitted_repositories" = "$controller_repositories" ] ||
  fail "$system_policy admits '${admitted_repositories//$'\n'/ }', not the controllers of $FLUX_COMPONENTS_FILE"
echo "$system_policy admits the ${#controller_refs[@]} controller repositories of $FLUX_COMPONENTS_FILE"

create_in() { kubectl --namespace "$1" create --dry-run=server -f -; }
admitted() {
  local what="$1" output
  shift
  output="$("$@" 2>&1)" || fail "$what was refused: $output"
  echo "admitted: $what"
}
# refused <what> <text>... -- <command>...: the refusal names each of judged_by and each text.
judged_by=("$policy" digest)
refused() {
  local what="$1" texts=() text output
  shift
  while [ "$1" != -- ]; do texts+=("$1") && shift; done
  shift
  if output="$("$@" 2>&1)"; then fail "$what was admitted"; fi
  for text in "${judged_by[@]}" "${texts[@]}"; do
    [[ $output == *"$text"* ]] || fail "$what was refused without naming '$text': $output"
  done
  echo "refused: $what: $output"
}
# probe_object <kind> <name> <Pod spec fields>: a YAML flow mapping of that kind whose Pods have the fields.
probe_object() {
  local kind="$1" name="$2" spec="{$3}" template
  case "$kind" in Pod | Job | CronJob) spec="{restartPolicy: Never, $3}" ;; esac
  template="{metadata: {labels: {probe: $name}}, spec: $spec}"
  case "$kind" in
    Pod) echo "{apiVersion: v1, kind: Pod, metadata: {name: $name}, spec: $spec}" ;;
    ReplicationController) echo "{apiVersion: v1, kind: $kind, metadata: {name: $name}, spec: {selector: {probe: $name}, template: $template}}" ;;
    StatefulSet) echo "{apiVersion: apps/v1, kind: $kind, metadata: {name: $name}, spec: {serviceName: $name, selector: {matchLabels: {probe: $name}}, template: $template}}" ;;
    Deployment | DaemonSet | ReplicaSet) echo "{apiVersion: apps/v1, kind: $kind, metadata: {name: $name}, spec: {selector: {matchLabels: {probe: $name}}, template: $template}}" ;;
    Job) echo "{apiVersion: batch/v1, kind: Job, metadata: {name: $name}, spec: {template: $template}}" ;;
    CronJob) echo "{apiVersion: batch/v1, kind: CronJob, metadata: {name: $name}, spec: {schedule: '@daily', jobTemplate: {spec: {template: $template}}}}" ;;
  esac
}
one_container() { echo "containers: [{name: $1, image: '$2'}]"; }
template_containers='(.spec.template.spec.containers[], .spec.template.spec.initContainers[])'

# Each running workload's Pod template, copied from the live object under a new name; the probes after this
# loop build on the vendor refs among its images.
app_prefix="ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/"
live_refs=() live_deployment="" live_pod=""
while IFS='|' read -r namespace workload; do
  [[ $exempt != *" $namespace "* ]] || continue
  [ -n "$live_deployment" ] || [[ $workload != Deployment/* ]] || live_deployment="$namespace|$workload"
  copy="$(kubectl --namespace "$namespace" get "$workload" -o yaml |
    yq '{"apiVersion": .apiVersion, "kind": .kind, "metadata": {"name": .metadata.name + "-probe"}, "spec": .spec}')"
  admitted "a copy of $namespace/$workload with its digests" create_in "$namespace" <<<"$copy"
  stripped="$(yq "$template_containers.image |= sub(\"@sha256:[0-9a-f]{64}\$\"; \"\")" <<<"$copy")"
  mapfile -t texts < <(yq "$template_containers | (.name, .image)" <<<"$stripped")
  refused "a copy of $namespace/$workload without its digests" "${texts[@]}" -- create_in "$namespace" <<<"$stripped"
  while IFS= read -r image; do
    [[ $image == "$app_prefix"* ]] || live_refs+=("$image")
  done < <(yq "$template_containers | .image" <<<"$copy")
done < <(kubectl get deployments,statefulsets,daemonsets --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}|{.kind}/{.metadata.name}{"\n"}{end}')
[ -n "$live_deployment" ] || fail "no vendor Deployment runs outside the namespaces$exempt"
while IFS='|' read -r namespace pod; do
  [[ $exempt == *" $namespace "* ]] || { live_pod="$namespace|pod/$pod" && break; }
done < <(kubectl get pods --all-namespaces --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}{"\n"}{end}')
[ -n "$live_pod" ] || fail "no Pod runs outside the namespaces$exempt"

kubectl create namespace "$PROBE_NAMESPACE"
for namespace in "$PROBE_NAMESPACE" "${vendor_list%/*}"; do
  kubectl --namespace "$namespace" wait serviceaccount/default --for=create --timeout=1m
done
pod() { create_in "$PROBE_NAMESPACE" <<<"$(probe_object Pod probe "$(one_container app "$1")")"; }
# The probes after this loop build on its last live vendor ref, its repository and its digest.
for ref in "${live_refs[@]}"; do
  named="${ref%@*}" digest="${ref##*@}"
  repository="$named"
  [[ ${named##*/} != *:* ]] || repository="${named%:*}"
  admitted "$repository@$digest" pod "$repository@$digest"
  admitted "$repository:probe@$digest" pod "$repository:probe@$digest"
done

generated_digest="sha256:$(openssl rand -hex 32)"
unlisted="docker.io/someone/hopin@$generated_digest"
app="${app_prefix}probe-app"
for image in "$unlisted" "${repository##*/}@$digest" "$repository:probe" "$repository:.probe@$digest" \
  "$app:v1.0.0" "$app@$generated_digest" "GHCR.io/${app#ghcr.io/}:v1.0.0@$generated_digest" \
  "quay.io/${app#ghcr.io/}:v1.0.0@$generated_digest"; do
  refused "$image" app "$image" -- pod "$image"
done
admitted "the full app ref $app:v1.0.0@$generated_digest" pod "$app:v1.0.0@$generated_digest"
refused "an init container running $unlisted" setup "$unlisted" -- create_in "$PROBE_NAMESPACE" \
  <<<"$(probe_object Pod probe "$(one_container app "$ref"), initContainers: [{name: setup, image: '$unlisted'}]")"
for kind in Pod Deployment StatefulSet DaemonSet ReplicaSet Job CronJob; do
  refused "a $kind running $unlisted" app "$unlisted" -- create_in "$PROBE_NAMESPACE" \
    <<<"$(probe_object "$kind" "${kind,,}-probe" "$(one_container app "$unlisted")")"
done
IFS='|' read -r namespace workload <<<"$live_deployment"
patch='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "'"$unlisted"'"}]'
refused "$namespace/$workload patched to $unlisted" "$unlisted" -- \
  kubectl --namespace "$namespace" patch "$workload" --type=json --patch="$patch" --dry-run=server
IFS='|' read -r namespace pod <<<"$live_pod"
refused "$namespace/$pod patched in place to $unlisted" "$unlisted" -- \
  kubectl --namespace "$namespace" patch "$pod" --type=json --patch="${patch//template\/spec\//}" --dry-run=server

# The namespace of the vendor list admits listed vendor refs only.
refused "the full app ref in ${vendor_list%/*}" app "$app:v1.0.0@$generated_digest" -- create_in "${vendor_list%/*}" \
  <<<"$(probe_object Pod probe "$(one_container app "$app:v1.0.0@$generated_digest")")"
admitted "$ref in ${vendor_list%/*}" create_in "${vendor_list%/*}" <<<"$(probe_object Pod probe "$(one_container app "$ref")")"
kubectl delete namespace "$PROBE_NAMESPACE" --wait --timeout=2m

# flux-system admits Flux's controller repositories by tag and nothing else.
judged_by=("$system_policy")
flux_pod() { create_in flux-system <<<"$(probe_object Pod probe "$(one_container manager "$1")")"; }
for controller in "${controller_refs[@]}"; do
  admitted "$controller in flux-system" flux_pod "$controller"
done
for image in "$unlisted" "${controller%/*}/helm-controller:${controller##*:}" "${controller%:*}" \
  "$app:v1.0.0@$generated_digest"; do
  refused "$image in flux-system" manager "$image" -- flux_pod "$image"
done
refused "an init container running $unlisted in flux-system" setup "$unlisted" -- create_in flux-system \
  <<<"$(probe_object Pod probe "$(one_container manager "$controller"), initContainers: [{name: setup, image: '$unlisted'}]")"
refused "a Deployment running $unlisted in flux-system" app "$unlisted" -- create_in flux-system \
  <<<"$(probe_object Deployment deployment-probe "$(one_container app "$unlisted")")"

# kube-system refuses what a Flux controller writes and leaves the rest, as k3s's own parts, unjudged.
for kind in Pod Deployment ReplicationController; do
  object="$(probe_object "$kind" "${kind,,}-probe" "$(one_container app "$unlisted")")"
  refused "a $kind in kube-system written as $FLUX_CONTROLLER" kube-system "$FLUX_CONTROLLER" -- \
    kubectl --as="$FLUX_CONTROLLER" --namespace kube-system create --dry-run=server -f - <<<"$object"
  admitted "a $kind in kube-system written as the job's user" create_in kube-system <<<"$object"
done
