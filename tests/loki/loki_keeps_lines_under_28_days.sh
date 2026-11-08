#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
# The longest a line may stay, which the privacy texts' 30 days leave room for; Loki deletes shortly after its limit.
retention_bound_seconds=$((28 * 24 * 3600))
loki_address="http://loki.${LOKI_NAMESPACE}.svc:3100"

# The namespace of the one sender Loki's policy admits and one it does not, which the cell creates and always removes.
remove_namespaces() { kubectl delete namespace --ignore-not-found --wait --timeout=2m "$WRITER_NAMESPACE" "$OTHER_NAMESPACE"; }
trap remove_namespaces EXIT
kubectl create namespace "$WRITER_NAMESPACE"
kubectl create namespace "$OTHER_NAMESPACE"

applied_revision="$(kubectl -n flux-system get kustomization loki -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization loki applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n "$LOKI_NAMESPACE" wait pod/loki-0 --for=condition=Ready --timeout=5m
echo "the Kustomization loki applied the candidate, and its pod is Ready"

# A line pushed from the admitted namespace comes back by LogQL.
nonce="nonce-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
push_body="{\"streams\":[{\"stream\":{\"cell\":\"$nonce\"},\"values\":[[\"$(date +%s%N)\",\"$nonce\"]]}]}"
request "$WRITER_NAMESPACE" push "loki.$LOKI_NAMESPACE.svc" "$loki_address/loki/api/v1/push" \
  --request POST --header 'Content-Type: application/json' --data "$push_body"
[ "$status" = 204 ] || fail "pushing a line from namespace $WRITER_NAMESPACE got '$status', not 204"
request_body "$WRITER_NAMESPACE" read "loki.$LOKI_NAMESPACE.svc" "$loki_address/loki/api/v1/query_range" \
  --get --data-urlencode "query={cell=\"$nonce\"}"
[ "$(yq -p=json '.data.result[0].values[0][1]' <<<"$status")" = "$nonce" ] ||
  fail "the line $nonce did not come back by LogQL: $status"
echo "a line pushed from namespace $WRITER_NAMESPACE came back by LogQL"

# The running configuration holds the retention, which check-pod-logs never reads.
request_body "$WRITER_NAMESPACE" config "loki.$LOKI_NAMESPACE.svc" "$loki_address/config"
running_configuration="$status"
retention_enabled="$(yq '.compactor.retention_enabled' <<<"$running_configuration")"
delete_request_store="$(yq '.compactor.delete_request_store' <<<"$running_configuration")"
retention_period="$(yq '.limits_config.retention_period' <<<"$running_configuration")"
[ "$retention_enabled" = true ] || fail "the running configuration has compactor.retention_enabled '$retention_enabled'"
[ "$delete_request_store" != null ] && [ -n "$delete_request_store" ] ||
  fail "the running configuration has no compactor.delete_request_store"
python3 -I -c '
import re, sys
units = {"w": 7 * 86400, "d": 86400, "h": 3600, "m": 60, "s": 1}
text = sys.argv[1]
if not re.fullmatch(r"(\d+[wdhms])+", text):
    sys.exit("limits_config.retention_period " + repr(text) + " is no duration")
seconds = sum(int(count) * units[unit] for count, unit in re.findall(r"(\d+)([wdhms])", text))
sys.exit(not 0 < seconds <= int(sys.argv[2]))
' "$retention_period" "$retention_bound_seconds" ||
  fail "the running configuration keeps lines for '$retention_period', not at most $retention_bound_seconds seconds"
echo "the running configuration deletes lines after $retention_period, with the compactor's retention on"

# Another namespace reaches nothing of Loki's.
request "$OTHER_NAMESPACE" other "loki.$LOKI_NAMESPACE.svc" "$loki_address/ready"
[ "$status" = 000 ] || fail "a Pod in namespace $OTHER_NAMESPACE got '$status' from Loki, not no answer"
echo "a Pod in namespace $OTHER_NAMESPACE gets no answer from Loki"

# The claim holds the lines until retention deletes them, so no prune and no release of it may take them.
claim="$(kubectl -n "$LOKI_NAMESPACE" get pod loki-0 \
  -o jsonpath='{.spec.volumes[?(@.name=="storage")].persistentVolumeClaim.claimName}')"
read -r phase volume prune < <(kubectl -n "$LOKI_NAMESPACE" get pvc "$claim" \
  -o jsonpath='{.status.phase} {.spec.volumeName} {.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}')
reclaim_policy="$(kubectl get pv "$volume" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
[ "$phase|$prune|$reclaim_policy" = "Bound|disabled|Retain" ] ||
  fail "the claim $LOKI_NAMESPACE/$claim reads '$phase|$prune|$reclaim_policy', not Bound|disabled|Retain"
echo "the claim $LOKI_NAMESPACE/$claim is Bound on a Retain volume with prune disabled"
