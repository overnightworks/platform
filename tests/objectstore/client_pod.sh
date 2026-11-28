# shellcheck shell=bash
# Sourced by the cells that drive an app's bucket from a client Pod. The Pod is built from the app's web Deployment and
# holds only the environment and the key file that manifest gives it, and runs client.py of this directory with the image
# the web of LiteLLM runs, which holds botocore. It needs APP_NAMESPACE and APP_MANIFEST (the app's web manifest), and
# reads, never restates, what that manifest and litellm's give.
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
client_directory="$(dirname "${BASH_SOURCE[0]}")"
web="$(yq 'select(.kind == "Deployment")' "$APP_MANIFEST")"
web_env() { NAME="$1" yq '.spec.template.spec.containers[0].env[] | select(.name == strenv(NAME)) | .value' <<<"$web"; }
bucket_variable="$(yq '.spec.template.spec.containers[0].env[] | select(.name | test("_S3_BUCKET$")) | .name' <<<"$web")"
bucket="$(web_env "$bucket_variable")"
credentials_path="$(web_env AWS_SHARED_CREDENTIALS_FILE)"
secrets_mount="$(yq '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "secrets") | .mountPath' <<<"$web")"
credentials_item="${credentials_path#"$secrets_mount"/}"
credentials_secret="$(CREDENTIALS_ITEM="$credentials_item" yq '.spec.template.spec.volumes[] | select(.name == "secrets")
  | .projected.sources[] | select(.secret.items[0].path == strenv(CREDENTIALS_ITEM)) | .secret.name' <<<"$web")"
credentials_key="$(CREDENTIALS_ITEM="$credentials_item" yq '.spec.template.spec.volumes[] | select(.name == "secrets")
  | .projected.sources[] | select(.secret.items[0].path == strenv(CREDENTIALS_ITEM)) | .secret.items[0].key' <<<"$web")"
client_image="$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[].image' infrastructure/litellm/litellm.yaml |
  grep -m1 '^ghcr[.]io/berriai/litellm:')"
[ -n "$bucket" ] && [ -n "$credentials_secret" ] && [ -n "$credentials_key" ] && [ -n "$client_image" ] ||
  fail "the manifests name no bucket, credentials Secret or client image to test with"

# client_pod <name> <Secret of the key file> <client argument>...: a Pod labelled and furnished as the web is.
client_pod() {
  local name="$1" secret="$2"
  shift 2
  NAME="$name" SECRET="$secret" IMAGE="$client_image" ARGUMENTS="$*" CREDENTIALS_ITEM="$credentials_item" yq '
    .spec.template.spec as $spec |
    {"apiVersion": "v1", "kind": "Pod",
     "metadata": {"name": strenv(NAME), "labels": (.spec.template.metadata.labels + {"cell": "object-store"})},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "client", "image": strenv(IMAGE),
         "command": ["python", "/cell/client.py"] + (strenv(ARGUMENTS) | split(" ")),
         "env": ($spec.containers[0].env | map(select(.name | test("^AWS_|_S3_BUCKET$")))) + [{"name": "HOME", "value": "/tmp"}],
         "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
         "volumeMounts": ($spec.containers[0].volumeMounts | map(select(.name == "secrets")))
           + [{"name": "cell", "mountPath": "/cell", "readOnly": true}, {"name": "tmp", "mountPath": "/tmp"}]}],
       "volumes": [($spec.volumes[] | select(.name == "secrets")
           | .projected.sources |= map(select(.secret.items[0].path == strenv(CREDENTIALS_ITEM)) | .secret.name = strenv(SECRET))),
         {"name": "cell", "configMap": {"name": "object-store-client"}}, {"name": "tmp", "emptyDir": {"medium": "Memory"}}]}}' <<<"$web" |
    kubectl -n "$APP_NAMESPACE" create -f -
}
pod_finished() {
  local phase
  phase="$(kubectl -n "$APP_NAMESPACE" get pod "$1" -o jsonpath='{.status.phase}')"
  [ "$phase" = Succeeded ] || [ "$phase" = Failed ]
}
# install_client: the ConfigMap object-store-client holds client.py, which the Pods mount.
install_client() {
  kubectl -n "$APP_NAMESPACE" create configmap object-store-client --from-file=client.py="$client_directory/client.py"
}
# run_client <name> <Secret> <client argument>...: the client runs to its end, its log is printed and its end must be Succeeded.
run_client() {
  local name="$1"
  client_pod "$@"
  until_true 600 "the client Pod $name ends" pod_finished "$name"
  kubectl -n "$APP_NAMESPACE" logs "pod/$name"
  [ "$(kubectl -n "$APP_NAMESPACE" get pod "$name" -o jsonpath='{.status.phase}')" = Succeeded ] || fail "the client Pod $name failed"
  kubectl -n "$APP_NAMESPACE" delete pod "$name" --wait --timeout=2m
}
# client_output <name> <client argument>...: run_client with the app's own key, and what the client printed in client_log
# instead of the console.
# shellcheck disable=SC2034 # client_log is this function's result for the cells that source this file.
client_output() {
  local name="$1"
  client_pod "$name" "$credentials_secret" "${@:2}" >/dev/null
  until_true 600 "the client Pod $name ends" pod_finished "$name"
  client_log="$(kubectl -n "$APP_NAMESPACE" logs "pod/$name")"
  [ "$(kubectl -n "$APP_NAMESPACE" get pod "$name" -o jsonpath='{.status.phase}')" = Succeeded ] || fail "the client Pod $name failed"
  kubectl -n "$APP_NAMESPACE" delete pod "$name" --wait --timeout=2m >/dev/null
}
# remove_client: for a cell's exit trap, the bucket cleared by a client Pod, whose failure counts as a deletion failure, then
# the client Pods and the ConfigMap install_client made.
remove_client() {
  (run_client clear-planted-objects "$credentials_secret" clear "$bucket_variable") ||
    { delete_object --namespace "$APP_NAMESPACE" delete pod clear-planted-objects --ignore-not-found --wait --timeout=2m; deletion_failures=$((deletion_failures + 1)); }
  delete_object --namespace "$APP_NAMESPACE" delete pod --selector cell=object-store --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$APP_NAMESPACE" delete configmap object-store-client --ignore-not-found
}
