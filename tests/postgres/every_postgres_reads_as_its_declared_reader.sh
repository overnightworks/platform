#!/usr/bin/env bash
# Proves docs/personal-data.md PD-11: that in each namespace of POSTGRES_NAMESPACES mise run db:read passes reader.sh's
# check of the declared role, that the role holds the connection limit the ConfigMap postgres-reader declares, and that
# it counts the first key table as the namespace's superuser does. Needs POSTGRES_NAMESPACES, which the cluster job
# sets, and each Postgres Ready with its app's migration run.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# db:read runs as on the PC, against this cluster.
export KUBECONFIG="$HOME/.kube/config"

as_superuser() {
  kubectl --namespace "$1" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only --no-align \
    --set=ON_ERROR_STOP=1 --command="$2"
}

for namespace in $POSTGRES_NAMESPACES; do
  kubectl --namespace "$namespace" wait pod/postgres-0 --for=condition=Ready --timeout=5m
  key_tables="$(kubectl --namespace "$namespace" get configmap postgres -o jsonpath='{.data.key-tables}')"
  first_table="${key_tables%% *}"
  first_table_exists() { [ "$(as_superuser "$namespace" "SELECT to_regclass('\"$first_table\"') IS NOT NULL")" = t ]; }
  until_true 300 "the first key table $first_table of $namespace exists" first_table_exists
  count_query="SELECT count(*) FROM \"$first_table\""
  # The aligned output is a header, a rule and the value.
  read_count="$(mise run db:read "$namespace" <<<"$count_query" | sed -n 3p | tr -d ' ')"
  superuser_count="$(as_superuser "$namespace" "$count_query")"
  [ -n "$read_count" ] && [ "$read_count" = "$superuser_count" ] ||
    fail "db:read counts '$read_count' rows of $first_table in $namespace, the superuser '$superuser_count'"
  reader_configmap="$(kubectl --namespace "$namespace" get pod postgres-0 \
    -o jsonpath='{.spec.volumes[?(@.name=="reader")].configMap.name}')"
  declared_connections="$(kubectl --namespace "$namespace" get configmap "$reader_configmap" -o jsonpath='{.data.connections}')"
  connection_limit="$(as_superuser "$namespace" "SELECT rolconnlimit FROM pg_roles WHERE rolname = 'reader'")"
  [ "$connection_limit" = "$declared_connections" ] ||
    fail "the role reader in $namespace holds the connection limit $connection_limit, not $declared_connections of $reader_configmap"
  echo "db:read passed the check in $namespace as the role reader with $connection_limit connections and counted $read_count rows of $first_table, as the superuser does"
done
