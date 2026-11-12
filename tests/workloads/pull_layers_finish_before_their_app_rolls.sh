#!/usr/bin/env bash
# Usage: CANDIDATE_REVISION=<sha> tests/workloads/pull_layers_finish_before_their_app_rolls.sh
# For every Kustomization whose path is ./apps/<app>/pull: it applied the candidate, waits for its objects, and the app's
# Kustomization depends on it; its Job completed with its pod kept and no time to live; the Job completed before the
# ReplicaSet of the current revision of each Deployment that runs an image the Job mounts was created; and the pods of
# every workload that runs such an image report it as already present on the node. The order is read from the objects'
# creation and completion times, which a later reconcile does not move, never from a condition's lastTransitionTime,
# which every reconcile of a layer resets.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
layer() { kubectl --namespace flux-system get kustomization "$1" -o jsonpath="$2"; }

pull_layers="$(kubectl --namespace flux-system get kustomizations.kustomize.toolkit.fluxcd.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.path}{"\n"}{end}' | grep -E ' ./apps/[^/]+/pull$' || true)"
[ -n "$pull_layers" ] || fail "no Kustomization has a path ./apps/<app>/pull"

while read -r pull_layer path; do
  app="${path#./apps/}" app="${app%/pull}"
  [ "$pull_layer" = "$app-pull" ] || fail "the Kustomization $pull_layer at $path is not named $app-pull"

  applied_revision="$(layer "$pull_layer" '{.status.lastAppliedRevision}')"
  [ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
    fail "the Kustomization $pull_layer applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
  [ "$(layer "$pull_layer" '{.spec.wait}')" = true ] || fail "the Kustomization $pull_layer does not wait for its objects"
  [[ " $(layer "$app" '{.spec.dependsOn[*].name}') " == *" $pull_layer "* ]] ||
    fail "the Kustomization $app does not depend on $pull_layer"
  echo "the Kustomization $pull_layer applied the candidate, waits for its Job, and $app depends on it"

  namespace="$(layer "$pull_layer" '{range .status.inventory.entries[*]}{.id}{"\n"}{end}' | sed -n 's/^\([^_]*\)_pull_batch_Job$/\1/p')"
  [ -n "$namespace" ] || fail "the inventory of $pull_layer holds no Job pull"
  job="$(kubectl --namespace "$namespace" get job pull -o yaml)"
  [ "$(yq '.status.succeeded' <<<"$job")" = 1 ] || fail "the Job $namespace/pull has not succeeded once: $(yq '.status' -o=json -I=0 <<<"$job")"
  [ "$(yq '.spec.ttlSecondsAfterFinished // "none"' <<<"$job")" = none ] || fail "the Job $namespace/pull sets ttlSecondsAfterFinished"
  completed="$(yq '.status.completionTime' <<<"$job")"
  [ -n "$(kubectl --namespace "$namespace" get pods --selector=batch.kubernetes.io/job-name=pull \
    --field-selector=status.phase=Succeeded -o name)" ] || fail "the finished pod of the Job $namespace/pull is gone"
  echo "the Job $namespace/pull completed at $completed and its finished pod stays"

  mapfile -t references < <(yq '.spec.template.spec.volumes[].image.reference' <<<"$job")
  workloads="$(kubectl --namespace "$namespace" get deployments.apps,statefulsets.apps -o yaml)"
  for reference in "${references[@]}"; do
    # kind/name and the label selector of each workload that runs the reference.
    mapfile -t runners < <(REFERENCE="$reference" yq '.items[]
      | select([.spec.template.spec.containers[].image, .spec.template.spec.initContainers[].image] | any_c(. == strenv(REFERENCE)))
      | .kind + "/" + .metadata.name + "|" + (.spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | join(","))' <<<"$workloads")
    [ "${#runners[@]}" -gt 0 ] || fail "no workload of $namespace runs the image $reference that the Job mounts"
    for runner in "${runners[@]}"; do
      workload="${runner%%|*}" selector="${runner#*|}"
      if [[ $workload == Deployment/* ]]; then
        revision="$(kubectl --namespace "$namespace" get "$workload" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')"
        replica_set_created="$(kubectl --namespace "$namespace" get replicasets --selector="$selector" -o yaml |
          REVISION="$revision" yq '[.items[] | select(.metadata.annotations["deployment.kubernetes.io/revision"] == strenv(REVISION))
            | .metadata.creationTimestamp] | sort | .[0]')"
        [ "$replica_set_created" != null ] || fail "the $workload has no ReplicaSet at its revision $revision"
        [[ ! $replica_set_created < "$completed" ]] ||
          fail "the ReplicaSet of the $workload at revision $revision was created at $replica_set_created, before the Job $namespace/pull completed at $completed"
        echo "the Job completed at $completed, the ReplicaSet of the $workload at revision $revision was created at $replica_set_created"
      fi
      pods="$(kubectl --namespace "$namespace" get pods --selector="$selector" -o name)"
      [ -n "$pods" ] || fail "the $workload has no pod"
      for pod in $pods; do
        events="$(kubectl --namespace "$namespace" get events \
          --field-selector="reason=Pulled,involvedObject.kind=Pod,involvedObject.name=${pod#pod/}" \
          -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | grep -F "\"$reference\"" || true)"
        [ -n "$events" ] || fail "the pod ${pod#pod/} of the $workload has no pull event for $reference"
        while IFS= read -r message; do
          [[ $message == *"already present on machine"* ]] || fail "the pod ${pod#pod/} of the $workload reports its pull of the image as '$message'"
        done <<<"$events"
        echo "the pod ${pod#pod/} of the $workload reports: ${events%%$'\n'*}"
      done
    done
  done
done <<<"$pull_layers"
