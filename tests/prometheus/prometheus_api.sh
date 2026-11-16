# shellcheck shell=bash
# Sourced by the cells under tests/prometheus/; reads PROMETHEUS_NAMESPACE from the caller when a function runs.

# api <path>: Prometheus' answer through the API server's proxy, which no NetworkPolicy of the pod network stops.
api() { kubectl get --raw "/api/v1/namespaces/$PROMETHEUS_NAMESPACE/services/prometheus-server:80/proxy/api/v1/$1"; }
# query <expression>: the instant vector's series, one JSON object per line.
query() {
  api "query?query=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")" |
    yq -p=json -o=json -I=0 '.data.result[]'
}

# alertmanager_metric <series selector>: the value of one of Alertmanager's own series, 0 while it has none.
alertmanager_metric() {
  kubectl -n "$PROMETHEUS_NAMESPACE" exec prometheus-alertmanager-0 -c alertmanager -- wget -qO- http://127.0.0.1:9093/metrics |
    awk -v series="$1" 'index($0, series " ") == 1 {value = $2} END {print value + 0}'
}
