#!/usr/bin/env bash
# Proves docs/ARCHITECTURE.md's Trust: in each namespace of POSTGRES_NAMESPACES the app's role is no superuser, is a
# member of no role, owns its database and every object in it, holds the declaration of app_role.sh and logs in over
# the Pod's address with the Secret's password, while the server's bootstrap role is named postgres and has no
# password, so that address refuses it. Needs POSTGRES_NAMESPACES and each Postgres Ready.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=loader_proof_setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/loader_proof_setup.sh"
# shellcheck source=app_role_target.sh
source "$(dirname "${BASH_SOURCE[0]}")/app_role_target.sh"
export KUBECONFIG="$HOME/.kube/config"

for namespace in $POSTGRES_NAMESPACES; do
  kubectl --namespace "$namespace" wait pod/postgres-0 --for=condition=Ready --timeout=5m
  failures="$(app_role_failures "$namespace" 5432)"
  [ -z "$failures" ] || fail "in $namespace: $failures"
  echo "in $namespace the role $namespace is no superuser, owns its database and each object in it and logs in over the network; postgres has no password and is refused there"
done
