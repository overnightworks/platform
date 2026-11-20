#!/usr/bin/env bash
# Parse Flux inventory ids, <namespace>_<name>_<group>_<kind> with each ':' of the name written '__', the way the cells
# of tests/workloads read them: a namespaced and a cluster-scoped object, a name with no, one and several colons, and an
# empty group. The ids follow cli-utils' ParseObjMetadata, which Flux's inventory uses.
# Usage: tests/workloads/inventory_ids_decode_colons_and_scopes.sh
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=inventory_id.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory_id.sh"

expect() {
  local id="$1" got
  parse_inventory_id "$id"
  got="$inventory_namespace|$inventory_name|$inventory_group|$inventory_kind"
  [ "$got" = "$2" ] || fail "the id $id parses as '$got', not '$2'"
  echo "the id $id parses as $got"
}
expect kyverno_kyverno-admission-controller_apps_Deployment 'kyverno|kyverno-admission-controller|apps|Deployment'
expect flux-system_flux-system__ConfigMap 'flux-system|flux-system||ConfigMap'
expect _kyverno_rbac.authorization.k8s.io_ClusterRole '|kyverno|rbac.authorization.k8s.io|ClusterRole'
expect _kyverno__admission-controller_rbac.authorization.k8s.io_ClusterRole \
  '|kyverno:admission-controller|rbac.authorization.k8s.io|ClusterRole'
expect _kyverno__admission-controller__core_rbac.authorization.k8s.io_ClusterRole \
  '|kyverno:admission-controller:core|rbac.authorization.k8s.io|ClusterRole'
expect kyverno_kyverno__leader-election_rbac.authorization.k8s.io_Role \
  'kyverno|kyverno:leader-election|rbac.authorization.k8s.io|Role'
expect _kyverno__Namespace '|kyverno||Namespace'
