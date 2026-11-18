#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The object store's bucket and key of one app. A client Pod built from the app's web Deployment, holding only the
# environment and the key file that manifest gives it, drives botocore against Garage's Service. It needs APP_NAMESPACE,
# APP_MANIFEST (the app's web manifest), OTHER_NAMESPACE (a namespace for a Pod that is no app's), PROBE_IMAGE and
# RUNNER_TEMP. The rotation steps suspend platform-secrets, so that it does not revert the Secret the cell changes.
here="$(dirname "${BASH_SOURCE[0]}")"
layer=infrastructure/objectstore
mask_secret() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::$1"; }

# What the manifests state, which the cell reads and never restates.
store_set="$(yq 'select(.kind == "StatefulSet")' "$layer/garage.yaml")"
store_namespace="$(yq '.metadata.namespace' <<<"$store_set")"
store_pod="$(yq '.metadata.name' <<<"$store_set")-0"
admin_secret="$(yq '.spec.template.spec.volumes[] | select(.secret) | .secret.secretName' <<<"$store_set")"
admin_key="$(yq '.spec.template.spec.containers[0].env[] | select(.name == "GARAGE_ADMIN_TOKEN_FILE") | .value | sub(".*/", "")' <<<"$store_set")"
s3_service="$(yq 'select(.kind == "Service" and .spec.ports[0].name == "s3") | .metadata.name + " " + (.spec.ports[0].port | tostring)' "$layer/garage.yaml")"
apply_job="$(yq 'select(.kind == "Job") | .metadata.name' "$layer/apply.yaml")"
web="$(yq 'select(.kind == "Deployment")' "$APP_MANIFEST")"
web_labels="$(yq -o json '.spec.template.metadata.labels' <<<"$web")"
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

# The environment contract, read from both owners: the endpoint is the Service s3 of the store, the region the store's own,
# and the bucket one the Job makes.
read -r service_name service_port <<<"$s3_service"
[ "$(web_env AWS_ENDPOINT_URL_S3)" = "http://$service_name.$store_namespace.svc.cluster.local:$service_port" ] ||
  fail "the web's AWS_ENDPOINT_URL_S3 is not the Service $service_name in $store_namespace on port $service_port"
[ "$(web_env AWS_DEFAULT_REGION)" = "$(yq -p toml -o yaml '.s3_api.s3_region' "$layer/garage.toml")" ] ||
  fail "the web's AWS_DEFAULT_REGION is not the s3_region of garage.toml"
grep -qxF "$bucket" "$layer/namespaces.txt" || fail "the bucket $bucket of the web is no namespace the Job apply makes a bucket for"
[ "$bucket" = "$APP_NAMESPACE" ] || fail "the bucket $bucket is not named like the namespace $APP_NAMESPACE"
echo "the web's endpoint, region and bucket $bucket equal what the store's manifests give"
# The app's layer, named like its namespace, applies after the store's Job has made the bucket and granted the key.
store_layer="$(basename "$layer")"
APP_LAYER="$APP_NAMESPACE" STORE_LAYER="$store_layer" yq -e 'select(.kind == "Kustomization" and .metadata.name == strenv(APP_LAYER))
  | .spec.dependsOn[] | select(.name == strenv(STORE_LAYER))' clusters/pc/apps.yaml >/dev/null ||
  fail "the Kustomization $APP_NAMESPACE in clusters/pc/apps.yaml does not wait for $store_layer, so its web may start before its bucket and key exist"
echo "the Kustomization $APP_NAMESPACE waits for $store_layer"

# The admin API through a port-forward, which no NetworkPolicy sees.
admin_token_file="$RUNNER_TEMP/object-store-admin-token"
(umask 077 && kubectl -n "$store_namespace" get secret "$admin_secret" -o go-template="{{index .data \"$admin_key\" | base64decode}}" \
  >"$admin_token_file")
mask_secret "$(<"$admin_token_file")"
forward_log="$RUNNER_TEMP/object-store-forward.log"
timeout 20m kubectl -n "$store_namespace" port-forward --address 127.0.0.1 "pod/$store_pod" :3903 >"$forward_log" 2>&1 &
forward_pid=$!
throwaway_id="" suspended=0 original_credentials=""

# Every deletion is attempted, whichever fails; the Secret goes back to what platform-secrets holds.
remove_objects() {
  local cell_status=$?
  [ -z "$original_credentials" ] || set_credentials "$original_credentials" || cell_status=1
  [ "$suspended" -eq 0 ] || flux resume kustomization platform-secrets --namespace flux-system || cell_status=1
  [ -z "$throwaway_id" ] || admin POST "/v2/DeleteBucket?id=$throwaway_id" || cell_status=1
  kill "$forward_pid" 2>/dev/null || true
  rm -f -- "$admin_token_file"
  for job in apply-second apply-rotated apply-clash apply-restored; do
    delete_object --namespace "$store_namespace" delete job "$job" --ignore-not-found --wait --timeout=2m
  done
  delete_object --namespace "$APP_NAMESPACE" delete pod --selector cell=object-store --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$APP_NAMESPACE" delete secret object-store-old --ignore-not-found
  delete_object --namespace "$APP_NAMESPACE" delete configmap object-store-client --ignore-not-found
  delete_object delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"
  end_deletions "$cell_status"
}
trap remove_objects EXIT
timeout 30 bash -c 'until grep -q "^Forwarding from 127.0.0.1:" "$0"; do sleep 1; done' "$forward_log" ||
  fail "the port-forward to $store_pod did not start: $(<"$forward_log")"
local_url="http://127.0.0.1:$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -n 1)"
# admin <GET|POST> <path> [<JSON body>]: one admin API call; prints the answer.
admin() {
  local body=()
  [ "$#" -lt 3 ] || body=(--data "$3")
  curl --silent --show-error --fail --request "$1" --header @<(printf 'Authorization: Bearer %s\n' "$(<"$admin_token_file")") \
    --header 'Content-Type: application/json' "${body[@]}" "$local_url$2"
}
# grants: the keys with a right on the bucket, with their rights. state: also every bucket and key the store holds.
grants() { admin GET "/v2/GetBucketInfo?globalAlias=$bucket" | jq -S '[.keys[] | select(.permissions.read or .permissions.write or .permissions.owner) | {accessKeyId, permissions}] | sort_by(.accessKeyId)'; }
state() {
  admin GET /v2/ListBuckets | jq -S 'map({id, globalAliases}) | sort_by(.id)'
  admin GET /v2/ListKeys | jq -S 'map(.id) | sort'
  grants
}

# set_credentials <the file's content>: the Secret holds it, whose value reaches kubectl through its stdin.
set_credentials() {
  jq --null-input --rawfile content /dev/stdin '{data: {($ARGS.positional[0]): ($content | @base64)}}' --args "$credentials_key" \
    <<<"$1" | kubectl -n "$APP_NAMESPACE" patch secret "$credentials_secret" --type merge --patch-file /dev/stdin
}
credentials_file() { printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$1" "$2"; }
key_id_of() { sed -n 's/^aws_access_key_id = //p' <<<"$1"; }
secret_of() { sed -n 's/^aws_secret_access_key = //p' <<<"$1"; }

kubectl -n "$store_namespace" wait "pod/$store_pod" --for=condition=Ready --timeout=5m
kubectl -n "$store_namespace" wait "job/$apply_job" --for=condition=Complete --timeout=5m
[ "$(kubectl get namespace "$store_namespace" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = restricted ] ||
  fail "the Namespace $store_namespace does not enforce restricted"
echo "$store_pod is Ready and the Job $apply_job completed in $store_namespace, which enforces restricted"
original_credentials="$(kubectl -n "$APP_NAMESPACE" get secret "$credentials_secret" -o go-template="{{index .data \"$credentials_key\" | base64decode}}")"
mask_secret "$(secret_of "$original_credentials")"
original_id="$(key_id_of "$original_credentials")"
initial_grants="$(grants)"
[ "$(jq -c 'map(.accessKeyId)' <<<"$initial_grants")" = "[\"$original_id\"]" ] ||
  fail "the bucket $bucket holds rights for other keys than the key of the Secret: $(jq -c 'map(.accessKeyId)' <<<"$initial_grants")"
[ "$(jq -c '.[0].permissions | [.read, .write, .owner]' <<<"$initial_grants")" = '[true,true,false]' ] ||
  fail "the key $original_id holds more or less than read and write on $bucket"
echo "the bucket $bucket holds read and write, no ownership, for the key $original_id alone"

# A bucket of another app, which the key must not reach.
throwaway="throwaway-$(openssl rand -hex 4)"
throwaway_id="$(admin POST /v2/CreateBucket "{\"globalAlias\": \"$throwaway\"}" | jq -r .id)"

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
# run_client <name> <Secret> <client argument>...: the client runs to its end, its log is printed and its end must be Succeeded.
run_client() {
  local name="$1"
  client_pod "$@"
  until_true 600 "the client Pod $name ends" pod_finished "$name"
  kubectl -n "$APP_NAMESPACE" logs "pod/$name"
  [ "$(kubectl -n "$APP_NAMESPACE" get pod "$name" -o jsonpath='{.status.phase}')" = Succeeded ] || fail "the client Pod $name failed"
  kubectl -n "$APP_NAMESPACE" delete pod "$name" --wait --timeout=2m
}
kubectl -n "$APP_NAMESPACE" create configmap object-store-client --from-file=client.py="$here/client.py"

run_client client-allowed "$credentials_secret" allowed "$bucket_variable" "$throwaway"
echo "a Pod furnished as the web reached its bucket with the contract's environment alone, and nothing else"

# probe <namespace> <name> <labels as JSON> <host> <port>: a Pod tries the port; sets probe_log to open or closed.
probe() {
  HOST="$4" PORT="$5" NAME="$2" LABELS="$3" IMAGE="$PROBE_IMAGE" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME), "labels": (strenv(LABELS) | from_json)},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "probe", "image": strenv(IMAGE),
         "command": ["sh", "-c", "if nc -z -w 5 \"$1\" \"$2\"; then echo open; else echo closed; fi", "sh", strenv(HOST), strenv(PORT)],
         "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]}}' |
    kubectl --namespace "$1" create -f -
  kubectl --namespace "$1" wait "pod/$2" --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m
  probe_log="$(kubectl --namespace "$1" logs "pod/$2")"
  kubectl --namespace "$1" delete pod "$2" --wait --timeout=2m
}
kubectl create namespace "$OTHER_NAMESPACE"
s3_host="$service_name.$store_namespace.svc.cluster.local"
admin_host="$store_pod.$(yq '.spec.serviceName' <<<"$store_set").$store_namespace.svc.cluster.local"
expect_probe() {
  local verdict="$1" description="$2"
  shift 2
  probe "$@"
  [ "$probe_log" = "$verdict" ] || fail "$description: the port answered '$probe_log', not $verdict"
  echo "$description: $verdict"
}
expect_probe closed "a Pod in $APP_NAMESPACE that is not the web, to the S3 port" "$APP_NAMESPACE" s3-unlabelled '{"cell": "object-store"}' "$s3_host" "$service_port"
# The app's other workloads, labelled as their templates are, which hold no key.
worker_number=0
while IFS= read -r worker_labels; do
  [ -n "$worker_labels" ] || continue
  worker_number=$((worker_number + 1))
  worker_name="$(jq -r '."app.kubernetes.io/name"' <<<"$worker_labels")"
  expect_probe closed "a Pod labelled as $worker_name in $APP_NAMESPACE, to the S3 port" \
    "$APP_NAMESPACE" "s3-worker-$worker_number" "$worker_labels" "$s3_host" "$service_port"
done < <(yq -o json -I0 'select(.kind == "Deployment" or .kind == "StatefulSet") | .spec.template.metadata.labels
  | select(.["app.kubernetes.io/name"] != "web")' "$(dirname "$APP_MANIFEST")"/*.yaml)
[ "$worker_number" -gt 0 ] || fail "$(dirname "$APP_MANIFEST") holds no workload besides the web to probe"
expect_probe closed "a Pod labelled as the web in $OTHER_NAMESPACE, to the S3 port" "$OTHER_NAMESPACE" s3-other-namespace "$web_labels" "$s3_host" "$service_port"
expect_probe closed "a Pod labelled as the web in $APP_NAMESPACE, to the admin port" "$APP_NAMESPACE" admin-web "$web_labels" "$admin_host" 3903
expect_probe closed "a Pod in $OTHER_NAMESPACE, to the admin port" "$OTHER_NAMESPACE" admin-other-namespace '{"cell": "object-store"}' "$admin_host" 3903
expect_probe open "a Pod in $store_namespace, to the admin port" "$store_namespace" admin-own-namespace '{"cell": "object-store"}' "$admin_host" 3903
[ "$(kubectl -n "$store_namespace" get networkpolicy garage -o jsonpath='{.spec.policyTypes}')" = '["Ingress","Egress"]' ] &&
  [ "$(kubectl -n "$store_namespace" get networkpolicy garage -o jsonpath='{.spec.egress}')" = "" ] ||
  fail "the NetworkPolicy garage does not hold Garage's pod to no egress"
echo "the NetworkPolicy garage lists Egress and no rule, so $store_pod sends nothing"

# A second run of the Job changes nothing.
# run_apply <name> <Complete|Failed>: a copy of the Flux-made Job, its pod's labels the Job's own, runs to that end.
run_apply() {
  kubectl -n "$store_namespace" get job "$apply_job" -o json | jq --arg name "$1" '
    {apiVersion, kind, metadata: {name: $name, namespace: .metadata.namespace},
     spec: (.spec | del(.selector, .manualSelector) | .backoffLimit = 0
       | .template.metadata.labels |= with_entries(select(.key | startswith("app.kubernetes.io/"))))}' |
    kubectl create -f -
  kubectl -n "$store_namespace" wait "job/$1" --for=condition="$2" --timeout=5m || {
    kubectl -n "$store_namespace" logs "job/$1" || true
    fail "the Job $1 did not end $2"
  }
  apply_log="$(kubectl -n "$store_namespace" logs "job/$1")"
  printf '%s\n' "$apply_log"
}
before="$(state)"
run_apply apply-second Complete
[ "$(state)" = "$before" ] || fail "a second run of the Job $apply_job changed the buckets, keys or grants"
! grep -qE 'created|imported|denied' <<<"$apply_log" || fail "a second run of the Job $apply_job reports a change"
echo "a second run of the Job $apply_job left the buckets, keys and grants equal"

# A rotated key ID: the new key works and the old one gets 403.
flux suspend kustomization platform-secrets --namespace flux-system
suspended=1
new_id="GK$(openssl rand -hex 12)"
new_secret="$(openssl rand -hex 32)"
mask_secret "$new_secret"
kubectl -n "$APP_NAMESPACE" create secret generic object-store-old --from-file="$credentials_key=/dev/stdin" <<<"$original_credentials"
set_credentials "$(credentials_file "$new_id" "$new_secret")"
run_apply apply-rotated Complete
[ "$(grants | jq -c 'map(.accessKeyId)')" = "[\"$new_id\"]" ] || fail "after the rotation the bucket $bucket holds rights for other keys than $new_id"
run_client client-rotated "$credentials_secret" allowed "$bucket_variable" "$throwaway"
run_client client-old-key object-store-old denied "$bucket_variable"
echo "after the rotation the new key $new_id works and the old key $original_id gets 403"

# A changed secret under a key ID Garage holds fails the Job, naming the namespace and the ID and no secret.
other_secret="$(openssl rand -hex 32)"
mask_secret "$other_secret"
set_credentials "$(credentials_file "$new_id" "$other_secret")"
run_apply apply-clash Failed
grep -qF "$APP_NAMESPACE" <<<"$apply_log" || fail "the failed Job does not name the namespace"
grep -qF "$new_id" <<<"$apply_log" || fail "the failed Job does not name the key ID"
! grep -qF -e "$new_secret" -e "$other_secret" -e "$(secret_of "$original_credentials")" <<<"$apply_log" || fail "the failed Job's log holds a secret"
echo "a changed secret under the key ID $new_id failed the Job, which named $APP_NAMESPACE and the ID and no secret"

# The original key comes back, and the bucket holds its rights alone as before.
set_credentials "$original_credentials"
run_apply apply-restored Complete
[ "$(grants)" = "$initial_grants" ] || fail "after the restore the bucket $bucket holds other rights than before the rotation"
run_client client-restored "$credentials_secret" allowed "$bucket_variable" "$throwaway"
echo "the original key $original_id is back with the rights it began with"
