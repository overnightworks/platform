#!/usr/bin/env bash
set -euo pipefail
fail() { echo "::error::$1"; exit 1; }
server="k3d-${CLUSTER_NAME}-server-0"

# k3s stages its manifests in one pass before it deploys coredns, so the set is final once that Deployment
# exists. Flux owns everything else in the cluster.
kubectl -n kube-system wait deployment/coredns --for=create --timeout=3m
own_manifests="$(printf '%s\n' ccm coredns metrics-server rolebindings | sort)"
staged_manifests="$(docker exec "$server" ls -1A /var/lib/rancher/k3s/server/manifests |
  sed 's/\.yaml$//' | sort)"
mismatch="$(comm -3 <(printf '%s\n' "$own_manifests") <(printf '%s\n' "$staged_manifests"))"
if [ -n "$mismatch" ]; then
  while IFS= read -r manifest; do
    case "$manifest" in
      $'\t'*) echo "::error::k3s staged ${manifest#$'\t'}, outside the manifests Flux leaves to k3s" ;;
      *) echo "::error::k3s did not stage its own manifest $manifest" ;;
    esac
  done <<<"$mismatch"
  exit 1
fi
sed 's/^/k3s staged: /' <<<"$staged_manifests"
helm_crds="$(kubectl get crd \
  -o jsonpath='{range .items[?(@.spec.group=="helm.cattle.io")]}{.metadata.name}{" "}{end}')"
[ -z "$helm_crds" ] || fail "k3s registered the helm.cattle.io CRDs $helm_crds"
echo "no helm.cattle.io CRD exists"

kubectl wait node --all --for=condition=Ready --timeout=3m
nodes="$(kubectl get nodes -o name)"
[ "$(wc -l <<<"$nodes")" -eq 1 ] || fail "the cluster has not exactly one Node: ${nodes//$'\n'/ }"
node="${nodes#node/}"
# k3s records its arguments with the config file merged in; k3d passes no --node-name, so it is the file's.
node_args="$(kubectl get node "$node" -o jsonpath='{.metadata.annotations.k3s\.io/node-args}')"
recorded_name="$(grep -oP '"--node-name","\K[^"]*' <<<"$node_args" || true)"
[ -n "$recorded_name" ] || fail "k3s recorded no --node-name for the Node $node"
[ "$node" = "$recorded_name" ] || fail "the Node $node is not named $recorded_name, the --node-name k3s recorded"
echo "the one Node is Ready and carries the --node-name k3s recorded: $node"

# The API server reaches the kubelet under the Node's name for logs and for the metrics API.
kubectl -n kube-system wait deployment/coredns --for=condition=Available --timeout=3m
kubectl -n kube-system logs deployment/coredns --tail=1
kubectl wait apiservice v1beta1.metrics.k8s.io --for=condition=Available --timeout=3m
echo "logs and the metrics API reach the kubelet of $node"

encryption="$(docker exec "$server" k3s secrets-encrypt status)"
grep -qx 'Encryption Status: Enabled' <<<"$encryption" ||
  fail "k3s reports secrets encryption as: $(head -n 1 <<<"$encryption")"
echo "k3s reports secrets encryption Enabled"

# The Flux controllers reached the API through the kubernetes Service, so kube-proxy has started.
route_localnet="$(docker exec "$server" cat /proc/sys/net/ipv4/conf/all/route_localnet)"
[ "$route_localnet" = 0 ] || fail "net.ipv4.conf.all.route_localnet is $route_localnet in $server, not 0"
echo "net.ipv4.conf.all.route_localnet is 0 in $server"
