#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
# The labels a stream carries; Loki derives service_name from container itself, so it is the one label Alloy does not send.
expected_labels="container namespace pod"
log_deadline_seconds=60
http_port=12345
# The one rule of Alloy's ClusterRole.
expected_rules='[{"apiGroups":[""],"resources":["namespaces","pods","pods/log"],"verbs":["get","list","watch"]}]'
loki_address="http://loki.${LOKI_NAMESPACE}.svc:3100"
writer_pod=alloy-nonce-writer

remove_objects() {
  kubectl -n "$SOURCE_NAMESPACE" delete pod --ignore-not-found --wait --timeout=2m "$writer_pod"
  kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
}
trap remove_objects EXIT
kubectl create namespace "$OTHER_NAMESPACE"

applied_revision="$(kubectl -n flux-system get kustomization alloy -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization alloy applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n "$ALLOY_NAMESPACE" wait deployment/alloy --for=condition=Available --timeout=5m
echo "the Kustomization alloy applied the candidate, and its Deployment is Available"

# The Namespace refuses a Pod that is not restricted, so a running Alloy passes; no volume of it is a host path.
enforce="$(kubectl get namespace "$ALLOY_NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
[ "$enforce" = restricted ] || fail "namespace $ALLOY_NAMESPACE enforces '$enforce', not restricted"
host_paths="$(kubectl -n "$ALLOY_NAMESPACE" get pods -o jsonpath='{.items[*].spec.volumes[*].hostPath.path}')"
[ -z "$host_paths" ] || fail "an Alloy pod mounts the host paths $host_paths"
echo "namespace $ALLOY_NAMESPACE enforces restricted and no Alloy pod mounts a host path"

# The layer's tree and the cluster each hold one ClusterRole of Alloy's with exactly the rule, and no binding of its
# ServiceAccount, cluster-wide or in a namespace, reaches another role.
rules_of() { yq -o=json -I=0 '.rules | map(.resources |= sort | .verbs |= sort)'; }
rendered_roles="$(kubectl kustomize infrastructure/alloy | yq --no-doc 'select(.kind == "ClusterRole") | .metadata.name')"
[ "$rendered_roles" = alloy ] || fail "the rendered layer holds the ClusterRoles '$rendered_roles', not alloy alone"
rendered_rules="$(kubectl kustomize infrastructure/alloy | yq --no-doc 'select(.kind == "ClusterRole")' | rules_of)"
[ "$rendered_rules" = "$expected_rules" ] || fail "the rendered ClusterRole alloy holds $rendered_rules, not $expected_rules"
bound_roles="$({
  kubectl get clusterrolebindings -o yaml
  kubectl get rolebindings --all-namespaces -o yaml
} | yq --no-doc '.items[] | select(.subjects[]? | .kind == "ServiceAccount" and .name == "alloy" and .namespace == "'"$ALLOY_NAMESPACE"'")
  | .roleRef.kind + "/" + .roleRef.name' | sort -u)"
[ "$bound_roles" = ClusterRole/alloy ] || fail "Alloy's ServiceAccount is bound to '$bound_roles', not ClusterRole/alloy alone"
cluster_rules="$(kubectl get clusterrole alloy -o yaml | rules_of)"
[ "$cluster_rules" = "$expected_rules" ] || fail "the cluster's ClusterRole alloy holds $cluster_rules, not $expected_rules"
echo "the layer holds one ClusterRole alloy, in the render and in the cluster, with exactly the rule, and nothing else binds Alloy"

# Nothing is admitted to Alloy's port.
alloy_address="$(kubectl -n "$ALLOY_NAMESPACE" get pod -l app.kubernetes.io/name=alloy -o jsonpath='{.items[0].status.podIP}')"
request "$OTHER_NAMESPACE" other "alloy.$ALLOY_NAMESPACE.svc" "http://$alloy_address:$http_port/-/ready"
[ "$status" = 000 ] || fail "a Pod in namespace $OTHER_NAMESPACE got '$status' from Alloy, not no answer"
echo "a Pod in namespace $OTHER_NAMESPACE gets no answer from Alloy"

# A line of a pod in another namespace comes back from Loki with exactly the labels of its stream.
nonce="nonce-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$(WRITER_POD="$writer_pod" NONCE="$nonce" yq '.metadata.name = strenv(WRITER_POD)
  | .spec.containers[0].command = ["sh", "-c"]
  | .spec.containers[0].args = ["echo " + strenv(NONCE) + "; sleep 300"]' <<<"${CLIENT_POD//@IMAGE@/${CLIENT_IMAGE}}")" |
  kubectl -n "$SOURCE_NAMESPACE" create -f -
started="$SECONDS"
labels=""
until [ -n "$labels" ]; do
  [ $((SECONDS - started)) -lt "$log_deadline_seconds" ] ||
    fail "the line $nonce of a Pod in namespace $SOURCE_NAMESPACE was not in Loki within $log_deadline_seconds seconds"
  request_body "$ALLOY_NAMESPACE" query "loki.$LOKI_NAMESPACE.svc" "$loki_address/loki/api/v1/query_range" \
    --get --data-urlencode "query={namespace=\"$SOURCE_NAMESPACE\"} |= \"$nonce\""
  labels="$(yq -p=json '(.data.result[0].stream // {}) | keys | .[]' <<<"$status" | { grep -vx service_name || true; } | sort | tr '\n' ' ')"
done
labels="${labels% }"
[ "$labels" = "$expected_labels" ] || fail "the stream of $nonce carries the labels '$labels', not '$expected_labels'"
echo "the line of a Pod in namespace $SOURCE_NAMESPACE reached Loki within $log_deadline_seconds seconds with the labels $labels"
