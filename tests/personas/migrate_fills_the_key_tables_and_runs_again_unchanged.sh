#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The runner's init container `migrate` runs once in a Pod of its own, built from the Deployment's template (its labels,
# so the NetworkPolicy of the runner governs it, and its volumes), against the namespace's Postgres: the Deployment is
# held at 0 replicas here, so nothing else migrates the database. Every key table then exists and the first holds a
# row, which the restore test demands, and a second run ends 0 and changes no count.
pod=migrate-proof

cleanup() {
  local cell_status=$?
  delete_object --namespace "$PERSONAS_NAMESPACE" delete pod "$pod" --ignore-not-found --wait --timeout=2m
  end_deletions "$cell_status"
}
trap cleanup EXIT

key_table_counts() {
  kubectl --namespace "$PERSONAS_NAMESPACE" exec postgres-0 --container postgres -- \
    sh /etc/postgres-checks/check-key-tables.sh --counts-only
}

# migrate_once: a Pod that runs the init container's image, arguments, environment and mounts, to its end.
migrate_once() {
  kubectl --namespace "$PERSONAS_NAMESPACE" get deployment personas --output yaml |
    NAME="$pod" yq '{"apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": strenv(NAME), "labels": .spec.template.metadata.labels},
      "spec": (.spec.template.spec | .restartPolicy = "Never" | .containers = [.initContainers[] | select(.name == "migrate")] | del(.initContainers))}' |
    kubectl --namespace "$PERSONAS_NAMESPACE" create --filename -
  kubectl --namespace "$PERSONAS_NAMESPACE" wait "pod/$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m || {
    kubectl --namespace "$PERSONAS_NAMESPACE" logs "pod/$pod" || true
    kubectl --namespace "$PERSONAS_NAMESPACE" describe "pod/$pod"
    fail "the migrate Pod in $PERSONAS_NAMESPACE did not succeed"
  }
  kubectl --namespace "$PERSONAS_NAMESPACE" delete pod "$pod" --wait --timeout=2m
}

kubectl --namespace "$PERSONAS_NAMESPACE" wait pod/postgres-0 --for=condition=Ready --timeout=5m
[ "$(kubectl --namespace "$PERSONAS_NAMESPACE" get deployment personas --output jsonpath='{.spec.replicas}')" = 0 ] ||
  fail "the Deployment personas runs a pod, so the cell does not own the migration"

migrate_once
first="$(key_table_counts)" || fail "a key table of $PERSONAS_NAMESPACE is missing after personas migrate"
case "$(head -n 1 <<<"$first")" in
  *": 0 rows") fail "the first key table is empty after personas migrate: $(head -n 1 <<<"$first")" ;;
esac
echo "personas migrate ran to its end through the runner's policy, and every key table exists:"
echo "$first"

migrate_once
[ "$(key_table_counts)" = "$first" ] || fail "a second personas migrate changed the key tables' counts"
echo "a second personas migrate ended 0 and left every count unchanged"
