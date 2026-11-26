#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=migrate_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/migrate_pod.sh"
# migrate_pod runs personas' migration through the runner's policy; the Deployment is held at 0 replicas here, so nothing
# else migrates the database. Every key table then exists and the first holds a row, which the restore test demands.
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

kubectl --namespace "$PERSONAS_NAMESPACE" wait pod/postgres-0 --for=condition=Ready --timeout=5m
migrate_pod "$PERSONAS_NAMESPACE" "$pod"
first="$(key_table_counts)" || fail "a key table of $PERSONAS_NAMESPACE is missing after personas migrate"
case "$(head -n 1 <<<"$first")" in
  *": 0 rows") fail "the first key table is empty after personas migrate: $(head -n 1 <<<"$first")" ;;
esac
echo "personas migrate ran to its end through the runner's policy, and every key table exists:"
echo "$first"
