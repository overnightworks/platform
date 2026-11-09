#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
web() { kubectl --namespace "$SONGMAKER_NAMESPACE" exec "$web_pod" --container web -- "$@"; }

cleanup() {
  kubectl --namespace "$SONGMAKER_NAMESPACE" delete pod own-client unknown-host-client --ignore-not-found --wait --timeout=2m
  kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
}
trap cleanup EXIT
kubectl create namespace "$OTHER_NAMESPACE"

# The web is the candidate's, Available with one Ready pod at a full app ref; what the image cost the runner is printed.
applied_revision="$(kubectl --namespace flux-system get kustomization songmaker -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization songmaker applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl --namespace "$SONGMAKER_NAMESPACE" wait deployment/web --for=condition=Available --timeout=3m
state="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get deployment web -o jsonpath='{.status.readyReplicas}|{.spec.strategy.type}')"
[ "$state" = "1|Recreate" ] || fail "the Deployment web reads '$state', not one Ready pod and Recreate"
images="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get deployment web \
  -o jsonpath='{.spec.template.spec.containers[*].image} {.spec.template.spec.initContainers[*].image}')"
for image in $images; do
  [[ $image =~ ^ghcr[.]io/${GITHUB_REPOSITORY_OWNER,,}/[^[:space:]:@]+:[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] ||
    fail "the Deployment web runs '$image', not a full app ref"
done
echo "the Deployment web is Available with one Ready pod and Recreate, at $images"
kubectl --namespace "$SONGMAKER_NAMESPACE" get events --field-selector reason=Pulled \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}'
df --human-readable /
web_pod="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get pod --selector app.kubernetes.io/name=web -o jsonpath='{.items[0].metadata.name}')"

# migrate ended 0, and the database stands at the one head of the image, on the major version of the base's Postgres.
exit_code="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get pod "$web_pod" \
  -o jsonpath='{.status.initContainerStatuses[?(@.name=="migrate")].state.terminated.exitCode}')"
[ "$exit_code" = 0 ] || fail "the init container migrate of $web_pod ended '$exit_code', not 0"
heads="$(web /app/.venv/bin/alembic heads | awk '{print $1}')"
[ "$(wc -l <<<"$heads")" = 1 ] || fail "the image has more than one alembic head: $heads"
sql() { kubectl --namespace "$SONGMAKER_NAMESPACE" exec postgres-0 --container postgres -- psql --no-psqlrc \
  --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="$1"; }
stored="$(sql 'select version_num from alembic_version')"
[ "$stored" = "$heads" ] || fail "alembic_version holds '$stored', not the image's head '$heads'"
base_image="$(yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].image' "$POSTGRES_BASE/postgres.yaml")"
base_major="${base_image#*/postgres:}" base_major="${base_major%%.*}"
server_version="$(sql 'show server_version')"
[ "${server_version%%.*}" = "$base_major" ] || fail "the Postgres runs $server_version, not major $base_major of $base_image"
echo "migrate ended 0 and alembic_version equals the image's head $heads on Postgres $server_version"

# The pod answers its public host and refuses another; a Pod in another namespace gets no answer.
host="$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "PUBLIC_BASE_URL") | .value' \
  apps/songmaker/web.yaml)"
host="${host#*://}"
url="http://web.$SONGMAKER_NAMESPACE.svc.cluster.local:8080/health"
request "$SONGMAKER_NAMESPACE" own-client "$host" "$url"
[ "$status" = 200 ] || fail "/health answered '$status' for $host, not 200"
request "$SONGMAKER_NAMESPACE" unknown-host-client "unknown.invalid" "$url"
[[ $status =~ ^[0-9]{3}$ && $status != 2?? && $status != 000 ]] || fail "/health answered '$status' for an unknown host, not an error"
request "$OTHER_NAMESPACE" other-client "$host" "$url" --max-time 5 --retry 0
[ "$status" = 000 ] || fail "a Pod in $OTHER_NAMESPACE got '$status' from the web"
echo "/health answers 200 for $host and $status for an unknown host; a Pod in $OTHER_NAMESPACE gets no answer"

# The root is read-only, the user is not root, and the audio claim and /tmp take a file.
uid="$(web id -u)"
[ "$uid" != 0 ] || fail "the web runs as uid 0"
web sh -c '! touch /app/root-proof 2>/dev/null' || fail "the web wrote to its root filesystem"
web sh -c 'for dir in /app/data/audio /tmp; do touch "$dir/write-proof" && rm "$dir/write-proof" || exit 1; done' ||
  fail "the web cannot write to the audio claim or /tmp as uid $uid"
echo "the web runs as uid $uid on a read-only root, and writes to /app/data/audio and /tmp"

# The audio claim is Bound on the Retain class, and no prune takes it.
claim="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get deployment web \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="audio")].persistentVolumeClaim.claimName}')"
class="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get pvc "$claim" -o jsonpath='{.spec.storageClassName}')"
state="$(kubectl --namespace "$SONGMAKER_NAMESPACE" get pvc "$claim" \
  -o jsonpath='{.status.phase}|{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}')"
[ "$state" = "Bound|disabled" ] || fail "the claim $claim reads '$state', not Bound with prune disabled"
reclaim="$(kubectl get storageclass "$class" -o jsonpath='{.reclaimPolicy}')"
[ "$reclaim" = Retain ] || fail "the class $class of $claim reclaims with $reclaim, not Retain"
echo "the claim $claim is Bound on the class $class, which retains, with prune disabled"
