#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
redis_cli() { kubectl --namespace "$SONGMAKER_NAMESPACE" exec redis-0 --container redis -- redis-cli "$@"; }

cleanup() {
  kubectl --namespace "$SONGMAKER_NAMESPACE" delete pod own-probe --ignore-not-found --wait --timeout=2m
  kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
}
trap cleanup EXIT
kubectl create namespace "$OTHER_NAMESPACE"

applied_revision="$(kubectl --namespace flux-system get kustomization songmaker -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization songmaker applied '$applied_revision', not the candidate $CANDIDATE_REVISION"

# Each store is Ready and runs as the image's own non-root user.
for store in postgres redis; do
  kubectl --namespace "$SONGMAKER_NAMESPACE" wait "pod/$store-0" --for=condition=Ready --timeout=5m
  read -r uid image_uid < <(kubectl --namespace "$SONGMAKER_NAMESPACE" exec "$store-0" --container "$store" -- \
    sh -c "echo \"\$(id -u) \$(id -u $store)\"")
  [ "$uid" = "$image_uid" ] && [ "$uid" != 0 ] || fail "$store in $SONGMAKER_NAMESPACE runs as uid $uid, not as the image's $store user $image_uid"
  echo "$store in $SONGMAKER_NAMESPACE is Ready and runs as uid $uid"
done

# probe <namespace> <name>: a Pod in the namespace tries each store's port; sets probe_log to one line per store.
probe() {
  TARGETS="postgres.$SONGMAKER_NAMESPACE.svc.cluster.local:5432 redis.$SONGMAKER_NAMESPACE.svc.cluster.local:6379" \
    NAME="$2" IMAGE="$PROBE_IMAGE" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "probe", "image": strenv(IMAGE),
         "command": ["sh", "-c", "for target; do if nc -z -w 5 \"${target%:*}\" \"${target##*:}\"; then echo \"$target open\"; else echo \"$target closed\"; fi; done", "sh"] + (strenv(TARGETS) | split(" ")),
         "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]}}' |
    kubectl --namespace "$1" create -f -
  kubectl --namespace "$1" wait "pod/$2" --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m
  probe_log="$(kubectl --namespace "$1" logs "pod/$2")"
  printf '%s\n' "$probe_log"
  kubectl --namespace "$1" delete pod "$2" --wait --timeout=2m
}
postgres_target="postgres.$SONGMAKER_NAMESPACE.svc.cluster.local:5432"
redis_target="redis.$SONGMAKER_NAMESPACE.svc.cluster.local:6379"
probe "$SONGMAKER_NAMESPACE" own-probe
[ "$probe_log" = "$postgres_target open"$'\n'"$redis_target open" ] ||
  fail "a Pod in $SONGMAKER_NAMESPACE does not reach both stores, so the probe proves no policy"
probe "$OTHER_NAMESPACE" other-probe
[ "$probe_log" = "$postgres_target closed"$'\n'"$redis_target closed" ] ||
  fail "a Pod in $OTHER_NAMESPACE reaches a store of $SONGMAKER_NAMESPACE"
echo "a Pod in $OTHER_NAMESPACE gets no answer from either store, one in $SONGMAKER_NAMESPACE gets both"

# A key written to Redis is gone after its pod is deleted and back Ready.
key="forget-proof-$(openssl rand -hex 8)"
[ "$(redis_cli set "$key" value)" = OK ] || fail "Redis refused the key $key"
[ "$(redis_cli get "$key")" = value ] || fail "Redis did not return the key $key it was given"
old_pod="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get pod redis-0 -o jsonpath='{.metadata.uid}')"
kubectl --namespace "$SONGMAKER_NAMESPACE" delete pod redis-0 --wait --timeout=2m
kubectl --namespace "$SONGMAKER_NAMESPACE" wait pod/redis-0 --for=create --timeout=1m
kubectl --namespace "$SONGMAKER_NAMESPACE" wait pod/redis-0 --for=condition=Ready --timeout=2m
[ "$(kubectl --namespace "$SONGMAKER_NAMESPACE" get pod redis-0 -o jsonpath='{.metadata.uid}')" != "$old_pod" ] ||
  fail "the Redis pod is the one before the deletion"
[ "$(redis_cli dbsize)" = 0 ] || fail "the new Redis pod holds keys after a restart"
echo "the key $key is gone after Redis's pod was deleted and came back Ready"
