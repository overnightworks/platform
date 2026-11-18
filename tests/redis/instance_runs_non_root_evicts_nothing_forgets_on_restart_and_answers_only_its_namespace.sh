#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The rendered instance is the one in $APP_NAMESPACE; a Pod in $OTHER_NAMESPACE is the outsider.

redis_cli() { kubectl --namespace "$APP_NAMESPACE" exec redis-0 --container redis -- redis-cli "$@"; }

# Every deletion is attempted, whichever fails.
remove_objects() {
  local cell_status=$?
  delete_object --namespace "$APP_NAMESPACE" delete pod redis-own-probe --ignore-not-found --wait --timeout=2m
  delete_object delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
  end_deletions "$cell_status"
}
trap remove_objects EXIT
kubectl create namespace "$OTHER_NAMESPACE"

kubectl --namespace "$APP_NAMESPACE" wait pod/redis-0 --for=condition=Ready --timeout=5m
read -r uid image_uid < <(kubectl --namespace "$APP_NAMESPACE" exec redis-0 --container redis -- \
  sh -c 'echo "$(id -u) $(id -u redis)"')
[ "$uid" = "$image_uid" ] && [ "$uid" != 0 ] || fail "Redis in $APP_NAMESPACE runs as uid $uid, not as the image's redis user $image_uid"
echo "Redis in $APP_NAMESPACE is Ready and runs as uid $uid"
config_value() {
  kubectl --namespace "$APP_NAMESPACE" exec redis-0 --container redis -- redis-cli config get "$1" | sed -n 2p
}
[ -z "$(config_value save)" ] || fail "Redis in $APP_NAMESPACE snapshots to disk: save is '$(config_value save)'"
[ "$(config_value appendonly)" = no ] || fail "Redis in $APP_NAMESPACE writes an append-only file"
[ "$(config_value maxmemory-policy)" = noeviction ] || fail "Redis in $APP_NAMESPACE evicts keys: policy $(config_value maxmemory-policy)"
echo "Redis in $APP_NAMESPACE has no snapshots, no append-only file and the policy noeviction"

# probe <namespace> <name>: a Pod in the namespace tries the Redis port; sets probe_log to one line.
probe() {
  TARGET="redis.$APP_NAMESPACE.svc.cluster.local" NAME="$2" IMAGE="$PROBE_IMAGE" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "probe", "image": strenv(IMAGE),
         "command": ["sh", "-c", "if nc -z -w 5 \"$1\" 6379; then echo open; else echo closed; fi", "sh", strenv(TARGET)],
         "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]}}' |
    kubectl --namespace "$1" create -f -
  kubectl --namespace "$1" wait "pod/$2" --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m
  probe_log="$(kubectl --namespace "$1" logs "pod/$2")"
  kubectl --namespace "$1" delete pod "$2" --wait --timeout=2m
}
probe "$APP_NAMESPACE" redis-own-probe
[ "$probe_log" = open ] || fail "a Pod in $APP_NAMESPACE gets no answer from Redis, so the probe proves no policy"
probe "$OTHER_NAMESPACE" redis-other-probe
[ "$probe_log" = closed ] || fail "a Pod in $OTHER_NAMESPACE reaches Redis in $APP_NAMESPACE"
echo "a Pod in $OTHER_NAMESPACE gets no answer from Redis, one in $APP_NAMESPACE does"

# A key written to Redis is gone after its pod is deleted and back Ready.
key="forget-proof-$(openssl rand -hex 8)"
[ "$(redis_cli set "$key" value)" = OK ] || fail "Redis refused the key $key"
[ "$(redis_cli get "$key")" = value ] || fail "Redis did not return the key $key it was given"
old_pod="$(kubectl --namespace "$APP_NAMESPACE" get pod redis-0 -o jsonpath='{.metadata.uid}')"
kubectl --namespace "$APP_NAMESPACE" delete pod redis-0 --wait --timeout=2m
kubectl --namespace "$APP_NAMESPACE" wait pod/redis-0 --for=create --timeout=1m
kubectl --namespace "$APP_NAMESPACE" wait pod/redis-0 --for=condition=Ready --timeout=2m
[ "$(kubectl --namespace "$APP_NAMESPACE" get pod redis-0 -o jsonpath='{.metadata.uid}')" != "$old_pod" ] ||
  fail "the Redis pod is the one before the deletion"
# The app's own pods write keys again as soon as the new Redis answers, so only the proof key is judged.
[ "$(redis_cli exists "$key")" = 0 ] || fail "the new Redis pod in $APP_NAMESPACE still holds the key $key after a restart"
echo "the key $key is gone after Redis's pod in $APP_NAMESPACE was deleted and came back Ready"
