#!/usr/bin/env bash
# pod_on_the_pc_holds_only_lo.sh: on the PC, shows that a Pod of the shape of pod.sh holds lo alone and reaches neither
# the API's Service nor cluster DNS nor the node, while a default Pod beside it holds eth0 and reaches all three.
# The Pods live in a throwaway Namespace without a Pod Security label, which is deleted on every exit. It prints names
# and counts and changes nothing on the host. Reads through the PC's k3s kubeconfig unless KUBECONFIG is set; runs with
# the locked tools: mise exec -- tests/no_network/pod_on_the_pc_holds_only_lo.sh.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/pod.sh"
# The busybox ref of the cluster job, the one owner of the vendor image the cells run.
PROBE_IMAGE="${PROBE_IMAGE:-$(yq '.jobs.cluster.env.PROBE_IMAGE' "$(dirname "${BASH_SOURCE[0]}")/../../.github/workflows/ci.yml")}"
export PROBE_IMAGE
namespace=no-network-pc-proof
# Only a Namespace this run created is deleted; one that exists already makes the create fail and stays.
created_namespace=false
remove_objects() {
  local cell_status=$?
  if $created_namespace; then
    delete_object delete namespace --wait --timeout=2m "$namespace"
  fi
  end_deletions "$cell_status"
}
trap remove_objects EXIT

kubectl create namespace "$namespace"
created_namespace=true
kubectl -n "$namespace" wait serviceaccount/default --for=create --timeout=1m
create_pod isolated init
create_pod default none
kubectl -n "$namespace" wait pod/isolated pod/default --for=condition=Ready --timeout=3m

api_address="$(service_address default kubernetes)"
dns_address="$(service_address kube-system kube-dns)"
node_address="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
[ -n "$api_address" ] && [ -n "$dns_address" ] && [ -n "$node_address" ] || fail "an address to probe is missing"

names="$(link_names isolated)" || exit 1
[ "$names" = lo ] || fail "the isolated Pod's links are '$(tr '\n' ' ' <<<"$names")', not lo alone"
! reaches isolated "$api_address" 443 || fail "the isolated Pod reached the API's Service"
! resolves isolated kubernetes.default.svc.cluster.local "$dns_address" || fail "the isolated Pod resolved a name at cluster DNS"
! reaches isolated "$node_address" 10250 || fail "the isolated Pod reached the node"
echo "pod/isolated holds lo alone and reaches neither the API's Service, cluster DNS nor the node"

names="$(link_names default)" || exit 1
[ "$(tr '\n' ' ' <<<"$names")" = 'eth0 lo ' ] || fail "the default Pod's links are '$(tr '\n' ' ' <<<"$names")', not eth0 and lo"
reaches default "$api_address" 443 || fail "the default Pod did not reach the API's Service"
resolves default kubernetes.default.svc.cluster.local "$dns_address" || fail "the default Pod did not resolve a name at cluster DNS"
reaches default "$node_address" 10250 || fail "the default Pod did not reach the node"
echo "pod/default holds eth0 and lo and reaches the API's Service, cluster DNS and the node"
