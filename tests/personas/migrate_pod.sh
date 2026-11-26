# shellcheck shell=bash
# Sourced by the cells that need personas' database migrated while the cluster job holds the Deployment at 0 replicas;
# defines functions only. Needs failure.sh sourced.

# migrate_pod <namespace> <pod name>: the runner's init container `migrate` runs once in a Pod of the given name, built
# from the Deployment's template (its labels, so the NetworkPolicy of the runner governs it, and its volumes), against
# the namespace's Postgres, to its end; the Pod is deleted afterwards. A caller's exit trap deletes it after a failure.
migrate_pod() {
  local namespace="$1" pod="$2"
  [ "$(kubectl --namespace "$namespace" get deployment personas --output jsonpath='{.spec.replicas}')" = 0 ] ||
    fail "the Deployment personas runs a pod, so the cell does not own the migration"
  kubectl --namespace "$namespace" get deployment personas --output yaml |
    NAME="$pod" yq '{"apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": strenv(NAME), "labels": .spec.template.metadata.labels},
      "spec": (.spec.template.spec | .restartPolicy = "Never" | .containers = [.initContainers[] | select(.name == "migrate")] | del(.initContainers))}' |
    kubectl --namespace "$namespace" create --filename -
  kubectl --namespace "$namespace" wait "pod/$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m || {
    kubectl --namespace "$namespace" logs "pod/$pod" || true
    kubectl --namespace "$namespace" describe "pod/$pod"
    fail "the migrate Pod in $namespace did not succeed"
  }
  kubectl --namespace "$namespace" delete pod "$pod" --wait --timeout=2m
}
