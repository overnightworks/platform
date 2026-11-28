#!/usr/bin/env bash
# Proves docs/personal-data.md PD-11: that in each namespace of POSTGRES_NAMESPACES mise run db:read passes reader_role.sh's
# check of the declared role, that the role holds the connection limit the ConfigMap postgres-reader declares, and that
# it counts the first key table as the namespace's superuser does. Needs POSTGRES_NAMESPACES, which the cluster job
# sets, and each Postgres Ready with its app's migration run; the cluster job holds personas' Deployment at 0 replicas,
# so the cell runs personas' migration itself.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=loader_proof_setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/loader_proof_setup.sh"
# shellcheck source=../personas/migrate_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../personas/migrate_pod.sh"
# db:read runs as on the PC, against this cluster.
export KUBECONFIG="$HOME/.kube/config"
migrate_pod_name=reader-migrate-proof
cleanup() {
  local cell_status=$?
  delete_object --namespace personas delete pod "$migrate_pod_name" --ignore-not-found --wait --timeout=2m
  end_deletions "$cell_status"
}
trap cleanup EXIT

for namespace in $POSTGRES_NAMESPACES; do
  kubectl --namespace "$namespace" wait pod/postgres-0 --for=condition=Ready --timeout=5m
  [ "$namespace" != personas ] || migrate_pod personas "$migrate_pod_name"
  key_tables="$(kubectl --namespace "$namespace" get configmap postgres -o jsonpath='{.data.key-tables}')"
  first_table="${key_tables%% *}"
  first_table_exists() { [ "$(sql "$namespace" "SELECT to_regclass('\"$first_table\"') IS NOT NULL")" = t ]; }
  until_true 300 "the first key table $first_table of $namespace exists" first_table_exists
  count_query="SELECT count(*) FROM \"$first_table\""
  # The aligned output is a header, a rule and the value.
  read_count="$(mise run db:read "$namespace" <<<"$count_query" | sed -n 3p | tr -d ' ')"
  superuser_count="$(sql "$namespace" "$count_query")"
  [ -n "$read_count" ] && [ "$read_count" = "$superuser_count" ] ||
    fail "db:read counts '$read_count' rows of $first_table in $namespace, the superuser '$superuser_count'"
  declared_connections="$(declared_reader_connections "$namespace")"
  connection_limit="$(sql "$namespace" "SELECT rolconnlimit FROM pg_roles WHERE rolname = 'reader'")"
  [ "$connection_limit" = "$declared_connections" ] ||
    fail "the role reader in $namespace holds the connection limit $connection_limit, not the declared $declared_connections"
  echo "db:read passed the check in $namespace as the role reader with $connection_limit connections and counted $read_count rows of $first_table, as the superuser does"
done
