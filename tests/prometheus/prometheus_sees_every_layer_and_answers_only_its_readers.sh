#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
web_address="http://prometheus-server.${PROMETHEUS_NAMESPACE}.svc"
# A digest no registry holds, on the repository of the probe image, which the image policy judges by form only.
dead_image="${PROBE_IMAGE%@*}@sha256:$(printf '0%.0s' {1..64})"

# The namespace of the stranger and the Kustomization at a missing path, which the cell creates and always removes.
remove_probes() {
  kubectl -n flux-system delete kustomization --ignore-not-found --wait --timeout=2m "$BROKEN_KUSTOMIZATION"
  kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
}
trap remove_probes EXIT

# api <path>: Prometheus' answer through the API server's proxy, which no NetworkPolicy of the pod network stops.
api() { kubectl get --raw "/api/v1/namespaces/$PROMETHEUS_NAMESPACE/services/prometheus-server:80/proxy/api/v1/$1"; }
# query <expression>: the instant vector's series, one JSON object per line.
query() {
  api "query?query=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")" |
    yq -p=json -o=json -I=0 '.data.result[]'
}
# until_true <seconds> <description> <command>...: the command passes within the time, tried every 10 seconds.
until_true() {
  local deadline=$((SECONDS + $1)) description="$2"
  shift 2
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "within the time: $description"
    sleep 10
  done
}

kubectl -n "$PROMETHEUS_NAMESPACE" wait deployment --all --for=condition=Available --timeout=5m
echo "every Deployment of namespace $PROMETHEUS_NAMESPACE is Available"

# Prometheus' ServiceAccount may read the kubelet's metrics and may not reach nodes/proxy, whose get opens the kubelet's
# exec through a WebSocket upgrade.
service_account="system:serviceaccount:$PROMETHEUS_NAMESPACE:prometheus-server"
kubectl auth can-i get nodes --subresource=metrics --as "$service_account" >/dev/null || fail "$service_account may not get nodes/metrics"
if kubectl auth can-i get nodes --subresource=proxy --as "$service_account" >/dev/null; then
  fail "$service_account may get nodes/proxy"
fi
echo "$service_account may get nodes/metrics and not nodes/proxy"

# kube-state-metrics' list on secrets would return their data, which no rule needs.
if kubectl auth can-i list secrets --all-namespaces --as "system:serviceaccount:$PROMETHEUS_NAMESPACE:prometheus-kube-state-metrics" >/dev/null; then
  fail "prometheus-kube-state-metrics may list secrets"
fi
echo "prometheus-kube-state-metrics may not list secrets"

# Every target the rendered configuration names is up, and none is down.
jobs="$(yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-server") | .data["prometheus.yml"] | from_yaml | .scrape_configs[].job_name' \
  infrastructure/prometheus/rendered.yaml)"
every_target_is_up() {
  local job
  [ -z "$(query 'up == 0')" ] || return 1
  for job in $jobs; do [ -n "$(query "up{job=\"$job\"} == 1")" ] || return 1; done
}
until_true 300 "every target of '${jobs//$'\n'/ }' is up and none is down" every_target_is_up
echo "every target is up: ${jobs//$'\n'/ }"

# gotk_resource_info exists for each Kustomization the cluster holds.
every_kustomization_has_its_series() {
  local name
  for name in $(kubectl get kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    [ -n "$(query "gotk_resource_info{customresource_kind=\"Kustomization\", name=\"$name\"}")" ] || return 1
  done
}
until_true 300 "gotk_resource_info exists for every Kustomization" every_kustomization_has_its_series
echo "gotk_resource_info exists for every Kustomization"

# DiskLow's own expression, without its threshold, has a series: cAdvisor's root filesystem reports usage and limit
# for a disk.
disk_ratio="$(yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-rules") | .data["rules.yml"] | from_yaml | .groups[].rules[] | select(.alert == "DiskLow") | .expr' \
  infrastructure/prometheus/rules.yaml)"
[[ $disk_ratio == *" > "* ]] || fail "the expression of DiskLow '$disk_ratio' has no threshold to strip"
disk_ratio="${disk_ratio% > *}"
root_filesystem_is_measured() { [ -n "$(query "$disk_ratio")" ]; }
until_true 300 "DiskLow's expression without its threshold has a series" root_filesystem_is_measured
echo "DiskLow's expression has series, by device: $(query "$disk_ratio" | yq -p=json '.metric.device + " " + .value[1]' | paste -sd' ')"

# A Deployment at an image no registry holds and a Kustomization at a missing path make their alerts pending; the
# durations, firing and resolving are the rules' tests'.
kubectl create namespace "$OTHER_NAMESPACE"
kubectl -n "$OTHER_NAMESPACE" create deployment dead --image "$dead_image"
kubectl apply -f - <<YAML
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $BROKEN_KUSTOMIZATION
  namespace: flux-system
spec:
  interval: 1m
  path: ./the-path-that-does-not-exist
  prune: false
  sourceRef:
    kind: GitRepository
    name: flux-system
YAML
alert_is_pending() {
  api alerts | yq -p=json -e ".data.alerts[] | select(.state == \"pending\" and .labels.alertname == \"$1\" and .labels.$2 == \"$3\")" >/dev/null 2>&1
}
until_true 360 "DeploymentUnavailable is pending for the dead Deployment" alert_is_pending DeploymentUnavailable deployment dead
echo "DeploymentUnavailable is pending for a Deployment at a dead image"
until_true 360 "KustomizationNotReady is pending for the broken Kustomization" alert_is_pending KustomizationNotReady name "$BROKEN_KUSTOMIZATION"
echo "KustomizationNotReady is pending for a Kustomization at a missing path"

# Only the admitted namespaces and Prometheus' own reach the web port, and a Pod there proves the address is right.
for namespace in "$PROMETHEUS_NAMESPACE" "$READER_NAMESPACE"; do
  request "$namespace" reader "prometheus-server.$PROMETHEUS_NAMESPACE.svc" "$web_address/-/ready"
  [ "$status" = 200 ] || fail "a Pod in namespace $namespace got '$status' from Prometheus, not 200"
  echo "a Pod in namespace $namespace gets 200 from Prometheus"
done
request "$OTHER_NAMESPACE" stranger "prometheus-server.$PROMETHEUS_NAMESPACE.svc" "$web_address/-/ready"
[ "$status" = 000 ] || fail "a Pod in namespace $OTHER_NAMESPACE got '$status' from Prometheus, not no answer"
echo "a Pod in namespace $OTHER_NAMESPACE gets no answer from Prometheus"

# The claim holds every sample until retention deletes it, so no prune and no release of it may take them.
claim="$(kubectl -n "$PROMETHEUS_NAMESPACE" get deployment prometheus-server \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="storage-volume")].persistentVolumeClaim.claimName}')"
read -r phase volume prune < <(kubectl -n "$PROMETHEUS_NAMESPACE" get pvc "$claim" \
  -o jsonpath='{.status.phase} {.spec.volumeName} {.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}')
reclaim_policy="$(kubectl get pv "$volume" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
[ "$phase|$prune|$reclaim_policy" = "Bound|disabled|Retain" ] ||
  fail "the claim $PROMETHEUS_NAMESPACE/$claim reads '$phase|$prune|$reclaim_policy', not Bound|disabled|Retain"
echo "the claim $PROMETHEUS_NAMESPACE/$claim is Bound on a Retain volume with prune disabled"
