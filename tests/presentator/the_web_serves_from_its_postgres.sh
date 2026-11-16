#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# presentator's web in the layer as Flux applied it: Ready, which its readiness probe answers only with /health at 200 and
# so with a database that holds a revision row, the init container migrate terminated with 0, the web and migrate carry
# the same URL (no password, query or fragment) and the same password file, which a read-only mount of the Secret
# postgres holds, and the database holds one alembic_version row. The claim database stays mounted. Names, verdicts and
# the row count only.
export KUBECONFIG="$HOME/.kube/config"
namespace=presentator
url_variable=PRESENTATOR_DATABASE_URL
file_variable=PRESENTATOR_DATABASE_PASSWORD_FILE

kubectl --namespace "$namespace" wait deployment/web --for=condition=Available --timeout=5m
kubectl --namespace "$namespace" rollout status deployment/web --timeout=5m
pod="$(kubectl --namespace "$namespace" get pod --selector app.kubernetes.io/name=web --output jsonpath='{.items[0].metadata.name}')"
[ "$(kubectl --namespace "$namespace" get pods --selector app.kubernetes.io/name=web --output name | wc -l)" = 1 ] ||
  fail "the web runs more than one pod"
kubectl --namespace "$namespace" wait "pod/$pod" --for=condition=Ready --timeout=5m
pod_json="$(kubectl --namespace "$namespace" get pod "$pod" --output json)"

exit_code="$(yq '.status.initContainerStatuses[] | select(.name == "migrate") | .state.terminated.exitCode' <<<"$pod_json")"
[ "$exit_code" = 0 ] || fail "the init container migrate of $pod ended '$exit_code', not 0"

container_setting() { # <container-list> <container> <variable>
  CONTAINER="$2" VARIABLE="$3" yq ".spec.$1[] | select(.name == strenv(CONTAINER)) | .env[] | select(.name == strenv(VARIABLE)) | .value" <<<"$pod_json"
}
for variable in "$url_variable" "$file_variable"; do
  web_value="$(container_setting containers web "$variable")"
  migrate_value="$(container_setting initContainers migrate "$variable")"
  [ -n "$web_value" ] && [ "$web_value" != null ] || fail "the web of $pod carries no $variable"
  [ "$web_value" = "$migrate_value" ] || fail "the web and migrate of $pod carry different values of $variable"
done
web_url="$(container_setting containers web "$url_variable")"
[[ $web_url =~ ^postgresql://[^:@/?#]+@[^:@/?#]+:[0-9]+/[^:@/?#]+$ ]] ||
  fail "$url_variable of $pod is no postgresql:// URL with a user, host, port and database, or carries a password, query or fragment"
echo "the web and migrate of $pod carry one $url_variable without a password and one $file_variable"

# The password file lies in a read-only mount of the Secret postgres, in the web and in migrate alike.
password_file="$(container_setting containers web "$file_variable")"
for container_list in containers initContainers; do
  holding=0
  while IFS=, read -r volume mount_path read_only; do
    [[ $password_file == "$mount_path"/* ]] || continue
    holding=$((holding + 1))
    [ "$read_only" = true ] || fail "the mount $volume that holds $password_file in $container_list of $pod is not read-only"
    secret="$(VOLUME="$volume" yq '.spec.volumes[] | select(.name == strenv(VOLUME)) | .secret.secretName' <<<"$pod_json")"
    [ "$secret" = postgres ] || fail "the mount $volume that holds $password_file in $container_list of $pod is the Secret '$secret', not postgres"
  done < <(yq ".spec.${container_list}[].volumeMounts[] | .name + \",\" + .mountPath + \",\" + (.readOnly | to_string)" <<<"$pod_json")
  [ "$holding" = 1 ] || fail "$holding mounts of the $container_list of $pod hold $password_file, not 1"
done
echo "$file_variable lies in a read-only mount of the Secret postgres in the web and in migrate"

[ "$(yq '[.spec.containers[] | select(.name == "web") | .volumeMounts[] | select(.name == "database")] | length' <<<"$pod_json")" = 1 ] ||
  fail "the web of $pod does not mount the claim database"
echo "the web still mounts the claim database"

# The user and the database are the ones in the URL.
database_user="${web_url#postgresql://}" database_user="${database_user%%@*}"
database_name="${web_url##*/}"
revision_rows="$(kubectl --namespace "$namespace" exec postgres-0 --container postgres -- psql --no-psqlrc \
  --username="$database_user" --dbname="$database_name" --tuples-only --no-align --set=ON_ERROR_STOP=1 \
  --command='select count(*) from alembic_version')"
[ "$revision_rows" = 1 ] || fail "alembic_version of $database_name holds '$revision_rows' rows, not 1"
echo "migrate ended 0 and alembic_version of $database_name holds one row; the web is Ready on it"
