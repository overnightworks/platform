#!/usr/bin/env bash
# Proves docs/personal-data.md PD-8: what the whole cluster exposes beside Traefik.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
applied_revision="$(kubectl -n flux-system get kustomization traefik -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization traefik applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n traefik wait deployment/traefik --for=condition=Available --timeout=3m
echo "the Kustomization traefik applied the candidate, and the Deployment traefik is Available"

# Charts reach the cluster only as committed manifests: no HelmRelease can exist, as its CRD is not installed,
# and the job's own platform-secrets source is no chart.
helm_release_crd="$(kubectl get crd --ignore-not-found helmreleases.helm.toolkit.fluxcd.io -o name)"
[ -z "$helm_release_crd" ] || fail "the cluster holds the CRD $helm_release_crd"
sources="$(kubectl get ocirepositories.source.toolkit.fluxcd.io -A \
  -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
chart_sources="$(grep -vxF OCIRepository/flux-system/platform-secrets <<<"$sources" || true)"
[ -z "$chart_sources" ] || fail "the cluster holds ${chart_sources//$'\n'/ }"
echo "no HelmRelease CRD and no OCIRepository beyond the job's platform-secrets source exists"
traefik_crds="$(kubectl get crd -o jsonpath='{range .items[*]}{.spec.group} {.metadata.name}{"\n"}{end}' |
  awk '$1 == "traefik.io" || $1 == "hub.traefik.io" { print $2 }')"
[ -z "$traefik_crds" ] || fail "the cluster holds Traefik's CRDs ${traefik_crds//$'\n'/ }"
echo "no traefik.io or hub.traefik.io CRD exists"

# A NodePort, a LoadBalancer, a hostPort or the host network takes the forward path ufw's input rules never see.
traefik_service="$(kubectl -n traefik get service traefik -o jsonpath='{.spec.type}{range .spec.ports[*]} {.name}{end}')"
[ "$traefik_service" = "ClusterIP web" ] ||
  fail "the Service traefik is '$traefik_service', not ClusterIP with the one port web"
echo "the Service traefik is ClusterIP with the one port web"
exposed=""
services="$(kubectl get services -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}|{.spec.type}{"\n"}{end}')"
while IFS='|' read -r service type; do
  case "$type" in NodePort | LoadBalancer) exposed+="the Service $service is a $type"$'\n' ;; esac
done <<<"$services"
pods="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}|{.spec.hostNetwork}|{.spec.initContainers[*].ports[*].hostPort} {.spec.containers[*].ports[*].hostPort}{"\n"}{end}')"
while IFS='|' read -r pod host_network host_ports; do
  [ "$host_network" != true ] || exposed+="the Pod $pod uses the host network"$'\n'
  [ -z "${host_ports// /}" ] || exposed+="the Pod $pod binds the host ports $host_ports"$'\n'
done <<<"$pods"
if [ -n "$exposed" ]; then
  while IFS= read -r finding; do [ -z "$finding" ] || echo "::error::$finding"; done <<<"$exposed"
  exit 1
fi
echo "no NodePort or LoadBalancer Service and no Pod on a host port or the host network exists"

# web trusts the X-Forwarded-For of the pod network, which holds the pods its NetworkPolicy admits.
trusted_ips="$(kubectl -n traefik get deployment traefik -o json | yq \
  '.spec.template.spec.containers[0].args[] | select(test("^--entryPoints[.]web[.]forwardedHeaders[.]trustedIPs=")) | sub("^[^=]*=", "")')"
pod_cidrs="$(kubectl get nodes -o jsonpath='{.items[*].spec.podCIDRs[*]}')"
python3 -I -c '
import ipaddress, sys
trusted = [ipaddress.ip_network(network) for network in sys.argv[1].split(",")]
pod_networks = [ipaddress.ip_network(network) for network in sys.argv[2].split()]
sys.exit(not pod_networks or not all(
    any(pod.version == network.version and pod.subnet_of(network) for network in trusted) for pod in pod_networks))
' "$trusted_ips" "$pod_cidrs" || fail "web trusts '$trusted_ips', which does not hold the nodes' pod CIDRs '$pod_cidrs'"
echo "web trusts the forwarded headers of $trusted_ips, which holds the nodes' pod CIDRs $pod_cidrs"
