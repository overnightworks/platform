#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The object store's bucket and key of one app. A client Pod built from the app's web Deployment, holding only the
# environment and the key file that manifest gives it, drives botocore against Garage's Service. It needs APP_NAMESPACE,
# APP_MANIFEST (the app's web manifest), OTHER_NAMESPACE (a namespace for a Pod that is no app's), PROBE_IMAGE and
# RUNNER_TEMP. The rotation and backup-key steps suspend platform-secrets, so that it does not revert the Secrets the cell changes.
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
# shellcheck source=../layer_includes.sh
source "$here/../layer_includes.sh"
# shellcheck source=client_pod.sh
source "$here/client_pod.sh"
web_labels="$(yq -o json '.spec.template.metadata.labels' <<<"$web")"
# The Secret that holds the backup's read-only key, which the Job's ClusterRole names beside the app's, under the same key.
backup_secret="$(CREDENTIALS_SECRET="$credentials_secret" yq 'select(.kind == "ClusterRole") | .rules[0].resourceNames[]
  | select(. != strenv(CREDENTIALS_SECRET))' "$layer/apply.yaml")"
[ -n "$backup_secret" ] || fail "the manifests name no Secret that holds the backup's key"

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
throwaway_id="" suspended=0 original_credentials="" original_backup=""

# Every deletion is attempted, whichever fails; the Secret goes back to what platform-secrets holds.
remove_objects() {
  local cell_status=$?
  [ -z "$original_credentials" ] || set_credentials "$original_credentials" || cell_status=1
  if [ "$suspended" -eq 1 ]; then
    if [ -n "$original_backup" ]; then
      set_backup_credentials "$original_backup" || cell_status=1
    else
      delete_object --namespace "$APP_NAMESPACE" delete secret "$backup_secret" --ignore-not-found
    fi
  fi
  [ "$suspended" -eq 0 ] || flux resume kustomization platform-secrets --namespace flux-system || cell_status=1
  [ -z "$throwaway_id" ] || admin POST "/v2/DeleteBucket?id=$throwaway_id" || cell_status=1
  kill "$forward_pid" 2>/dev/null || true
  rm -f -- "$admin_token_file"
  for job in apply-second apply-rotated apply-clash apply-restored apply-backup apply-backup-second apply-backup-clash \
    apply-backup-missing apply-backup-empty apply-backup-removed apply-backup-restored; do
    delete_object --namespace "$store_namespace" delete job "$job" --ignore-not-found --wait --timeout=2m
  done
  delete_object --namespace "$APP_NAMESPACE" delete pod --selector cell=object-store --ignore-not-found --wait --timeout=2m
  delete_object --namespace "$APP_NAMESPACE" delete secret object-store-old "$backup_secret-old" --ignore-not-found
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
# set_backup_credentials <the file's content>: the backup Secret holds it under the key credentials, made if it is absent.
set_backup_credentials() {
  if [ -n "$(kubectl -n "$APP_NAMESPACE" get secret "$backup_secret" --output name --ignore-not-found)" ]; then
    jq --null-input --rawfile content /dev/stdin '{data: {credentials: ($content | @base64)}}' <<<"$1" |
      kubectl -n "$APP_NAMESPACE" patch secret "$backup_secret" --type merge --patch-file /dev/stdin
  else
    kubectl -n "$APP_NAMESPACE" create secret generic "$backup_secret" --from-file=credentials=/dev/stdin <<<"$1"
  fi
}
# expected_grants <app key ID> [<backup key ID>]: read and write for the first, read alone for the second, no ownership, no other key.
expected_grants() {
  jq --null-input -S --arg app "$1" --arg backup "${2-}" '
    [{accessKeyId: $app, permissions: {owner: false, read: true, write: true}}]
    + (if $backup == "" then [] else [{accessKeyId: $backup, permissions: {owner: false, read: true, write: false}}] end)
    | sort_by(.accessKeyId)'
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
original_backup="$(kubectl -n "$APP_NAMESPACE" get secret "$backup_secret" --ignore-not-found -o go-template='{{index .data "credentials" | base64decode}}')"
original_backup_id="$(key_id_of "$original_backup")"
[ -z "$original_backup" ] || mask_secret "$(secret_of "$original_backup")"
initial_grants="$(grants)"
[ "$initial_grants" = "$(expected_grants "$original_id" "$original_backup_id")" ] ||
  fail "the bucket $bucket holds other rights than read and write for the key $original_id${original_backup_id:+ and read alone for the key $original_backup_id}: $(jq -c . <<<"$initial_grants")"
echo "the bucket $bucket holds read and write, no ownership, for the key $original_id${original_backup_id:+, read alone for the key $original_backup_id,} and for no other key"

# A bucket of another app, which the key must not reach.
throwaway="throwaway-$(openssl rand -hex 4)"
throwaway_id="$(admin POST /v2/CreateBucket "{\"globalAlias\": \"$throwaway\"}" | jq -r .id)"

install_client

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
# The backup's pod: the pods of a PreBackupPod reach the S3 port where the app's layer includes the Component that gives
# them the backup's key, and in no other namespace. k8up labels the pods of a PreBackupPod with its name.
bucket_component=infrastructure/postgres/backup/files/bucket
prebackup_labels="$(yq -o json -I0 '{"k8up.io/preBackupPod": .metadata.name}' <<<"$(yq 'select(.kind == "PreBackupPod")' "$bucket_component/../files.yaml")")"
if layer_includes "$(dirname "$APP_MANIFEST")/kustomization.yaml" components "$bucket_component"; then prebackup_verdict=open; else prebackup_verdict=closed; fi
expect_probe "$prebackup_verdict" "a Pod labelled as the PreBackupPod in $APP_NAMESPACE, to the S3 port" \
  "$APP_NAMESPACE" s3-prebackup "$prebackup_labels" "$s3_host" "$service_port"
expect_probe closed "a Pod labelled as the PreBackupPod in $OTHER_NAMESPACE, to the S3 port" \
  "$OTHER_NAMESPACE" s3-prebackup-other-namespace "$prebackup_labels" "$s3_host" "$service_port"
# The restore test's pod, which the Component labels where it adds the bucket steps: the same rule.
restore_test_labels="$(yq '.patches[] | select(.target.kind == "CronJob") | .patch' "$bucket_component/kustomization.yaml" |
  yq -o json -I0 '.[] | select(.op == "add" and .path == "/spec/jobTemplate/spec/template/metadata") | .value.labels')"
[ -n "$restore_test_labels" ] || fail "the bucket Component gives the restore test's pod no label"
expect_probe "$prebackup_verdict" "a Pod labelled as the restore test in $APP_NAMESPACE, to the S3 port" \
  "$APP_NAMESPACE" s3-restore-test "$restore_test_labels" "$s3_host" "$service_port"
expect_probe closed "a Pod labelled as the restore test in $OTHER_NAMESPACE, to the S3 port" \
  "$OTHER_NAMESPACE" s3-restore-test-other-namespace "$restore_test_labels" "$s3_host" "$service_port"
# The Component's endpoint, region, bucket and key, read from the owners the web's are read from.
component_container="$(yq '.patches[] | select(.target.kind == "PreBackupPod") | .patch' "$bucket_component/kustomization.yaml" |
  yq '.[] | select(.op == "add" and .path == "/spec/pod/spec/containers/-") | .value')"
component_volume="$(yq '.patches[] | select(.target.kind == "PreBackupPod") | .patch' "$bucket_component/kustomization.yaml" |
  yq '.[] | select(.op == "add" and .path == "/spec/pod/spec/volumes/-") | .value')"
component_env() { NAME="$1" yq '.env[] | select(.name == strenv(NAME)) | .value' <<<"$component_container"; }
[ "$(component_env RCLONE_S3_ENDPOINT)" = "http://$service_name.$store_namespace.svc.cluster.local:$service_port" ] ||
  fail "the bucket Component's endpoint is not the Service $service_name in $store_namespace on port $service_port"
[ "$(component_env RCLONE_S3_REGION)" = "$(yq -p toml -o yaml '.s3_api.s3_region' "$layer/garage.toml")" ] ||
  fail "the bucket Component's region is not the s3_region of garage.toml"
[ "$(yq '.env[] | select(.name == "BUCKET") | .valueFrom.fieldRef.fieldPath' <<<"$component_container")" = metadata.namespace ] ||
  fail "the bucket Component's bucket is not the Namespace's own"
component_mount="$(VOLUME="$(yq '.name' <<<"$component_volume")" yq '.volumeMounts[] | select(.name == strenv(VOLUME)) | .mountPath' <<<"$component_container")"
[ "$(component_env AWS_SHARED_CREDENTIALS_FILE)" = "$component_mount/$(yq '.secret.items[0].path' <<<"$component_volume")" ] ||
  fail "the bucket Component's key file is not in the mount of its Secret"
[ "$(yq '.secret.secretName' <<<"$component_volume")" = "$backup_secret" ] && [ "$(yq '.secret.items[0].key' <<<"$component_volume")" = "$credentials_key" ] ||
  fail "the bucket Component mounts another Secret or key than $backup_secret and the key $credentials_key the app's Secret holds"
echo "the bucket Component's endpoint, region, bucket and key equal what the store's manifests and the app's Secret give; the PreBackupPod's and the restore test's pods reach the S3 port: $prebackup_verdict"
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
[ "$(grants)" = "$(expected_grants "$new_id" "$original_backup_id")" ] ||
  fail "after the rotation the bucket $bucket holds other rights than for $new_id${original_backup_id:+ and the backup key}"
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

# The backup's key, its own Secret: it reads the bucket and nothing else. Its key here is the cell's, never a platform-secrets value.
backup_id="GK$(openssl rand -hex 12)"
backup_value="$(openssl rand -hex 32)"
mask_secret "$backup_value"
object_key="cell-backup-$(openssl rand -hex 4)"
set_backup_credentials "$(credentials_file "$backup_id" "$backup_value")"
run_apply apply-backup Complete
grep -qF "apply: bucket $APP_NAMESPACE holds backup key $backup_id read only" <<<"$apply_log" ||
  fail "the Job did not report the backup key $backup_id of $APP_NAMESPACE as read only"
! grep -qF "$backup_value" <<<"$apply_log" || fail "the Job's log holds the backup key's secret"
[ "$(grants)" = "$(expected_grants "$original_id" "$backup_id")" ] ||
  fail "the bucket $bucket holds other rights than read and write for $original_id and read alone for $backup_id"
run_client client-seed "$credentials_secret" put "$bucket_variable" "$object_key"
run_client client-backup "$backup_secret" read-only "$bucket_variable" "$object_key" "$throwaway"
run_client client-unseed "$credentials_secret" delete "$bucket_variable" "$object_key"
echo "the backup key $backup_id reads $bucket and gets 403 on every write and on another bucket"

# A second run changes nothing and reports no change.
before="$(state)"
run_apply apply-backup-second Complete
[ "$(state)" = "$before" ] || fail "a second run of the Job $apply_job with a backup key changed the buckets, keys or grants"
! grep -qE 'created|imported|denied' <<<"$apply_log" || fail "a second run of the Job $apply_job with a backup key reports a change"
echo "a second run of the Job $apply_job with a backup key left the buckets, keys and grants equal"

# refused_backup <description>: the failed Job named the namespace and the Secret, held no secret and left the grants as they were.
refused_backup() {
  grep -qF "$APP_NAMESPACE" <<<"$apply_log" || fail "$1: the failed Job does not name the namespace"
  grep -qF "$backup_secret" <<<"$apply_log" || fail "$1: the failed Job does not name the Secret $backup_secret"
  ! grep -qF -e "$backup_value" -e "$(secret_of "$original_credentials")" <<<"$apply_log" || fail "$1: the failed Job's log holds a secret"
  [ "$(grants)" = "$(expected_grants "$original_id" "$backup_id")" ] || fail "$1: the failed Job changed the grants"
  echo "$1: the Job failed, naming $APP_NAMESPACE and $backup_secret and no secret"
}

# The backup Secret holding the app's key is refused: granting it read alone would take the app's write.
set_backup_credentials "$original_credentials"
run_apply apply-backup-clash Failed
grep -qF "the backup key equals the app key" <<<"$apply_log" || fail "the Job did not refuse the app's key as the backup key"
refused_backup "the app's key in $backup_secret"

# The Secret without the key credentials, or with it empty, is refused naming the Secret and the key.
kubectl -n "$APP_NAMESPACE" patch secret "$backup_secret" --type merge --patch '{"data": {"credentials": null}}'
run_apply apply-backup-missing Failed
grep -qF "the key credentials" <<<"$apply_log" || fail "the Job does not name the key credentials of $backup_secret"
refused_backup "$backup_secret without the key credentials"
kubectl -n "$APP_NAMESPACE" patch secret "$backup_secret" --type merge --patch '{"data": {"credentials": ""}}'
run_apply apply-backup-empty Failed
grep -qF "the key credentials" <<<"$apply_log" || fail "the Job does not name the key credentials of $backup_secret"
refused_backup "$backup_secret with an empty key credentials"

# The Secret removed: the backup key loses its read at the next run, and the Job says that no backup key is granted.
kubectl -n "$APP_NAMESPACE" create secret generic "$backup_secret-old" --from-file=credentials=/dev/stdin <<<"$(credentials_file "$backup_id" "$backup_value")"
kubectl -n "$APP_NAMESPACE" delete secret "$backup_secret"
run_apply apply-backup-removed Complete
grep -qF "apply: bucket $APP_NAMESPACE has no backup key granted" <<<"$apply_log" ||
  fail "the Job did not say that $APP_NAMESPACE has no backup key granted"
[ "$(grants)" = "$(expected_grants "$original_id")" ] || fail "after the removal the bucket $bucket holds other rights than read and write for $original_id"
run_client client-backup-removed "$backup_secret-old" denied "$bucket_variable"
run_client client-app-kept "$credentials_secret" allowed "$bucket_variable" "$throwaway"
echo "after the removal the backup key $backup_id gets 403 and the app key $original_id keeps read and write"

# The backup Secret as it was, absent included, and the grants the bucket began with.
[ -z "$original_backup" ] || set_backup_credentials "$original_backup"
run_apply apply-backup-restored Complete
[ "$(grants)" = "$initial_grants" ] || fail "after the restore of $backup_secret the bucket $bucket holds other rights than at the start"
echo "$backup_secret is as it was and the bucket $bucket holds the rights it began with"
