#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

cleanup() {
  kubectl --namespace "$SONGMAKER_NAMESPACE" delete pod own-probe --ignore-not-found --wait --timeout=2m
  kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
}
trap cleanup EXIT
kubectl create namespace "$OTHER_NAMESPACE"

applied_revision="$(kubectl --namespace flux-system get kustomization songmaker -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization songmaker applied '$applied_revision', not the candidate $CANDIDATE_REVISION"

# Postgres is Ready and runs as the image's own non-root user.
kubectl --namespace "$SONGMAKER_NAMESPACE" wait pod/postgres-0 --for=condition=Ready --timeout=5m
read -r uid image_uid < <(kubectl --namespace "$SONGMAKER_NAMESPACE" exec postgres-0 --container postgres -- \
  sh -c 'echo "$(id -u) $(id -u postgres)"')
[ "$uid" = "$image_uid" ] && [ "$uid" != 0 ] || fail "postgres in $SONGMAKER_NAMESPACE runs as uid $uid, not as the image's postgres user $image_uid"
echo "postgres in $SONGMAKER_NAMESPACE is Ready and runs as uid $uid"

# probe <namespace> <name>: a Pod in the namespace tries the Postgres port; sets probe_log to one line.
probe() {
  TARGETS="postgres.$SONGMAKER_NAMESPACE.svc.cluster.local:5432" \
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
probe "$SONGMAKER_NAMESPACE" own-probe
[ "$probe_log" = "$postgres_target open" ] ||
  fail "a Pod in $SONGMAKER_NAMESPACE does not reach Postgres, so the probe proves no policy"
probe "$OTHER_NAMESPACE" other-probe
[ "$probe_log" = "$postgres_target closed" ] ||
  fail "a Pod in $OTHER_NAMESPACE reaches Postgres of $SONGMAKER_NAMESPACE"
echo "a Pod in $OTHER_NAMESPACE gets no answer from Postgres, one in $SONGMAKER_NAMESPACE does"
