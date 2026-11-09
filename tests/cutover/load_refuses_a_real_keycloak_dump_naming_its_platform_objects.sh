#!/usr/bin/env bash
# In k3d: `mise run cutover:load` reads a custom-format dump of the cluster's own Keycloak through its Postgres
# container and refuses it before anything is loaded. It names agent_owner in the user profile and the six objects only
# realm.yaml declares, no other profile difference, which shows on Keycloak's own storage that the gate finds the stored
# profile and compares every other attribute equal. It prints no line of db:load-dump and leaves the Kustomization
# unsuspended. The success path needs hal's dump and belongs to the rehearsal.
set -euo pipefail
# The task falls back to the PC's kubeconfig, so the job's cluster is named for it.
export KUBECONFIG="$HOME/.kube/config"
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
namespace="$KEYCLOAK_NAMESPACE"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

kubectl --namespace "$namespace" exec postgres-0 --container postgres -- pg_dump --format=custom >"$work_directory/dump" ||
  fail "the dump of the database $namespace cannot be taken"
printf 'issuer https://issuer.invalid/realms/x\nkid a\n' >"$work_directory/evidence"

status=0
output="$(mise run cutover:load "$work_directory/dump" "$work_directory/evidence" 2>&1)" || status=$?
[ "$status" = 1 ] || fail "cutover:load exited $status, not 1: $output"
findings="$(grep -E '^cutover:load: (profile |the dump holds )' <<<"$output" | LC_ALL=C sort)" || fail "no finding in: $output"
expected="$(LC_ALL=C sort <<'FINDINGS'
cutover:load: profile attribute agent_owner is extra
cutover:load: the dump holds client agent-mozart, which only realm.yaml declares
cutover:load: the dump holds user service-account-agent-mozart, which only realm.yaml declares
cutover:load: the dump holds scope agent-identity, which only realm.yaml declares
cutover:load: the dump holds group agents, which only realm.yaml declares
cutover:load: the dump holds group agent-adders, which only realm.yaml declares
cutover:load: the dump holds group agent-owners, which only realm.yaml declares
FINDINGS
)"
[ "$findings" = "$expected" ] || fail "the gate named other findings than the platform's own: $output"
grep -q 'nothing loaded$' <<<"$output" || fail "the refusal does not end in 'nothing loaded': $output"
! grep -q '^db:load-dump' <<<"$output" || fail "db:load-dump ran: $output"
suspended="$(kubectl --namespace flux-system get kustomization "$namespace" --output jsonpath='{.spec.suspend}')" ||
  fail "the Kustomization $namespace cannot be read"
[ "$suspended" != true ] || fail "the Kustomization $namespace is suspended"
echo "cutover:load refused Keycloak's own dump naming agent_owner and the six objects, and loaded nothing"
