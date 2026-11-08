#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"

scratch="$(mktemp -d)"
forward_pid=""
cleanup() {
  local cell_status=$?
  [ -z "$forward_pid" ] || kill -- "-$forward_pid" 2>/dev/null || true
  delete_object delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
  rm -rf "$scratch"
  end_deletions "$cell_status"
}
trap cleanup EXIT

applied_revision="$(kubectl -n flux-system get kustomization grafana -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization grafana applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n "$GRAFANA_NAMESPACE" rollout status deployment/grafana --timeout=5m

port="$(kubectl -n "$GRAFANA_NAMESPACE" get service grafana -o jsonpath='{.spec.ports[0].port}')"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" setsid mise run grafana:open >"$scratch/forward.log" 2>&1 &
forward_pid=$!
local_port=""
for _ in $(seq 30); do
  local_port="$(sed -n 's#^grafana:open: open http://127\.0\.0\.1:\([0-9]*\)/;.*#\1#p' "$scratch/forward.log")"
  [ -z "$local_port" ] || break
  sleep 1
done
[ -n "$local_port" ] || fail "grafana:open printed no address: $(cat "$scratch/forward.log")"
address="http://127.0.0.1:$local_port"

[ "$(curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' "$address/api/health")" = 200 ] ||
  fail "$address/api/health did not answer 200"
echo "Grafana's page answers 200 for /api/health through the address grafana:open printed"

# until_true <seconds> <description> <command>...: the command passes within the time, tried every 10 seconds.
until_true() {
  local deadline=$((SECONDS + $1)) description="$2"
  shift 2
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "within the time: $description"
    sleep 10
  done
}

# Each provisioned data source reports OK and answers a query without any credential: PromQL's up has series, and
# the LogQL selector of Loki's own namespace, whose pod Alloy ships, returns a stream.
datasources="infrastructure/grafana/values.yaml"
uid_of() { yq ".datasources[\"datasources.yaml\"].datasources[] | select(.type == \"$1\") | .uid" "$datasources"; }
# query_body <uid> <type> <expression> <the type's own fields as JSON>: the body of one query over the last hour.
query_body() {
  UID_VALUE="$1" TYPE="$2" QUERY="$3" OWN_FIELDS="$4" yq --null-input --output-format=json '
    {"from": "now-1h", "to": "now", "queries": [{"refId": "A", "datasource": {"uid": strenv(UID_VALUE), "type": strenv(TYPE)},
      "expr": strenv(QUERY)} * (strenv(OWN_FIELDS) | from_json)]}'
}
data_source_is_ok() {
  [ "$(curl --silent --max-time 10 "$address/api/datasources/uid/$1/health" | yq -p=json '.status')" = OK ]
}
data_source_answers() {
  curl --silent --max-time 20 --header 'Content-Type: application/json' --data "$(query_body "$@")" "$address/api/ds/query" |
    yq -p=json -e '.results.A.frames[0].data.values[0] | length > 0' >/dev/null 2>&1
}
prometheus_uid="$(uid_of prometheus)" loki_uid="$(uid_of loki)"
until_true 120 "the data source $prometheus_uid reports OK" data_source_is_ok "$prometheus_uid"
until_true 120 "the data source $loki_uid reports OK" data_source_is_ok "$loki_uid"
echo "the health of the data sources $prometheus_uid and $loki_uid reads OK"
until_true 300 "PromQL up returns series through $prometheus_uid" data_source_answers "$prometheus_uid" prometheus up '{"instant": true}'
echo "PromQL up returns series through the data source $prometheus_uid"
until_true 300 "LogQL over namespace $LOKI_NAMESPACE returns a stream through $loki_uid" \
  data_source_answers "$loki_uid" loki "{namespace=\"$LOKI_NAMESPACE\"}" '{"queryType": "range", "maxLines": 5}'
echo "LogQL over namespace $LOKI_NAMESPACE returns a stream through the data source $loki_uid"

# The anonymous role runs Explore and may not change a data source.
permissions="$(curl --silent --max-time 10 "$address/api/access-control/user/permissions")"
yq -p=json -e 'has("datasources:explore")' <<<"$permissions" >/dev/null || fail "the anonymous role may not run Explore"
yq -p=json -e 'has("datasources:write") | not' <<<"$permissions" >/dev/null || fail "the anonymous role may write a data source"
echo "the anonymous role may run Explore and may not write a data source"

# No claim, and only volumes that hold nothing a restart keeps.
claims="$(kubectl -n "$GRAFANA_NAMESPACE" get persistentvolumeclaims -o name)"
[ -z "$claims" ] || fail "namespace $GRAFANA_NAMESPACE holds claims: $claims"
volume_kinds="$(kubectl -n "$GRAFANA_NAMESPACE" get deployment grafana -o yaml |
  yq '.spec.template.spec.volumes[] | keys | .[] | select(. != "name")' | sort -u | paste -sd' ')"
[ "$volume_kinds" = "configMap emptyDir" ] || [ "$volume_kinds" = "configMap emptyDir projected" ] ||
  fail "the pod's volumes are of the kinds '$volume_kinds', not only emptyDir, configMap and projected"
echo "namespace $GRAFANA_NAMESPACE holds no claim, and its pod's volumes are of the kinds: $volume_kinds"

# Its Pod runs in a Namespace that enforces restricted, and the layer renders no Role, ClusterRole or hook.
[ "$(kubectl get namespace "$GRAFANA_NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = restricted ] ||
  fail "namespace $GRAFANA_NAMESPACE does not enforce restricted"
rbac_and_hooks="$(yq --no-doc 'select(.kind == "Role" or .kind == "ClusterRole" or .kind == "RoleBinding" or .kind == "ClusterRoleBinding" or .metadata.annotations["helm.sh/hook"]) | .kind + "/" + .metadata.name' \
  infrastructure/grafana/rendered.yaml)"
[ -z "$rbac_and_hooks" ] || fail "the render of Grafana holds $rbac_and_hooks"
[ -z "$(kubectl -n "$GRAFANA_NAMESPACE" get roles,rolebindings -o name)" ] ||
  fail "namespace $GRAFANA_NAMESPACE holds a Role or RoleBinding"
echo "namespace $GRAFANA_NAMESPACE enforces restricted, and the layer holds no Role, ClusterRole or hook"

# Only Gatus's namespace reaches the page.
request "$GATUS_NAMESPACE" grafana-health grafana.grafana.svc "http://grafana.$GRAFANA_NAMESPACE.svc:$port/api/health"
[ "$status" = 200 ] || fail "a Pod in namespace $GATUS_NAMESPACE got '$status' from Grafana, not 200"
echo "a Pod in namespace $GATUS_NAMESPACE gets 200 for /api/health"
kubectl create namespace "$OTHER_NAMESPACE"
request "$OTHER_NAMESPACE" grafana-denied grafana.grafana.svc "http://grafana.$GRAFANA_NAMESPACE.svc:$port/api/health"
[ "$status" = 000 ] || fail "a Pod in namespace $OTHER_NAMESPACE got '$status' from Grafana, not no answer"
echo "a Pod in namespace $OTHER_NAMESPACE gets no answer from Grafana"

# A Pod with Grafana's labels reaches Loki and Prometheus, resolving their names, and neither the API server's Service
# nor a host outside, which a Pod in the throwaway namespace, held by no policy, does reach.
loki_port="$(kubectl -n "$LOKI_NAMESPACE" get service loki -o jsonpath='{.spec.ports[?(@.name=="http-metrics")].port}')"
prometheus_port="$(kubectl -n "$PROMETHEUS_NAMESPACE" get service prometheus-server -o jsonpath='{.spec.ports[0].port}')"
service_port="$(kubectl -n "${CLUSTER_SERVICE%/*}" get service "${CLUSTER_SERVICE#*/}" -o jsonpath='{.spec.ports[0].port}')"
loki_target="loki.$LOKI_NAMESPACE.svc.cluster.local:$loki_port"
prometheus_target="prometheus-server.$PROMETHEUS_NAMESPACE.svc.cluster.local:$prometheus_port"
service_target="${CLUSTER_SERVICE#*/}.${CLUSTER_SERVICE%/*}.svc.cluster.local:$service_port"
# egress_probe <namespace> <name> <target>...: sets probe_log to one "<target> open|closed" line per target.
egress_probe() {
  local namespace="$1" name="$2"
  shift 2
  NAME="$name" IMAGE="$PROBE_IMAGE" TARGETS="$*" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME), "labels": {"app.kubernetes.io/name": "grafana"}},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "probe", "image": strenv(IMAGE),
         "command": ["sh", "-c", "for target; do if nc -z -w 5 \"${target%:*}\" \"${target##*:}\"; then echo \"$target open\"; else echo \"$target closed\"; fi; done", "sh"] + (strenv(TARGETS) | split(" ")),
         "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]}}' |
    kubectl --namespace "$namespace" create -f -
  kubectl --namespace "$namespace" wait "pod/$name" --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m
  probe_log="$(kubectl --namespace "$namespace" logs "pod/$name")"
  printf '%s\n' "$probe_log"
  kubectl --namespace "$namespace" delete pod "$name" --wait --timeout=2m
}
egress_probe "$GRAFANA_NAMESPACE" grafana-egress-probe "$loki_target" "$prometheus_target" "$service_target" "$OUTSIDE_TARGET"
[ "$probe_log" = "$loki_target open"$'\n'"$prometheus_target open"$'\n'"$service_target closed"$'\n'"$OUTSIDE_TARGET closed" ] ||
  fail "a Pod in namespace $GRAFANA_NAMESPACE does not reach exactly Loki and Prometheus"
egress_probe "$OTHER_NAMESPACE" free-egress-probe "$service_target" "$OUTSIDE_TARGET"
[ "$probe_log" = "$service_target open"$'\n'"$OUTSIDE_TARGET open" ] ||
  fail "a Pod outside the policy does not reach both targets, so the probe proves no policy"
echo "a Pod with Grafana's labels reaches Loki and Prometheus, neither $CLUSTER_SERVICE nor $OUTSIDE_TARGET"
