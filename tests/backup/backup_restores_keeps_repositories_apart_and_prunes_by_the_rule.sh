#!/usr/bin/env bash
# Proves docs/personal-data.md PD-3.
set -euo pipefail
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
# The backup's proofs on the cluster, each with its positive control; no secret is printed.
export KUBECONFIG="$HOME/.kube/config"
# shellcheck source=restic_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/restic_pod.sh"

forward=
cleanup() {
  local cell_status=$?
  [ -z "$forward" ] || kill "$forward" 2>/dev/null || true
  delete_restic_objects
  end_deletions "$cell_status"
}
trap cleanup EXIT

# wait_completed <namespace> <backup|prune> <name>: waits for the k8up object's Completed condition and fails unless it succeeded.
wait_completed() {
  local namespace="$1" kind="$2" name="$3" deadline=$((SECONDS + 600)) reason
  while :; do
    reason="$(kubectl --namespace "$namespace" get "$kind" "$name" \
      --output jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')"
    [ -z "$reason" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      kubectl --namespace "$namespace" describe "$kind" "$name"
      kubectl --namespace "$namespace" get jobs,pods
      fail "the $kind $name of $namespace did not complete within 10 minutes"
    fi
    sleep 5
  done
  [ "$reason" = Succeeded ] || {
    kubectl --namespace "$namespace" describe "$kind" "$name"
    fail "the $kind $name of $namespace ended with reason $reason"
  }
}

# snapshots_per_run <namespace>: the snapshots one Backup leaves, the dump's and, for a layer that declares a claim
# beside its database, the staging claim's.
snapshots_per_run() {
  if [ -n "$(kubectl --namespace "$1" get configmap postgres --output jsonpath='{.data.backup-claim}')" ]; then echo 2; else echo 1; fi
}

secret_value() { kubectl --namespace "$1" get secret restic --output json | KEY="$2" yq --output-format json '.data[strenv(KEY)]' | tr -d '"' | base64 --decode; }
rest_base="$(dirname "$(kubectl --namespace "${BACKUP_NAMESPACES%% *}" get configmap postgres \
  --output jsonpath='{.data.backup-repository}')")"

# The one image both sides restore with: the operator's restic reads what its Job pods wrote.
operator_image="$(kubectl --namespace k8up-system get deployment k8up --output jsonpath='{.spec.template.spec.containers[0].image}')"
for namespace in $BACKUP_NAMESPACES; do
  dump_image="$(kubectl --namespace "$namespace" get cronjob restore-test \
    --output jsonpath='{.spec.jobTemplate.spec.template.spec.initContainers[0].image}')"
  [ "$dump_image" = "$operator_image" ] ||
    fail "the restore test of $namespace reads with $dump_image, the operator runs $operator_image"
done
echo "the restore test of each namespace reads with the operator's own image"

# The restore test fails on the empty repository that restic init made; its positive control follows.
# restic's REST backend creates a repository with one request that no retry wraps, so a fresh Pod's first packets can meet
# a refusal before the network policy admits its address; init alone is retried, only on a refusal, and its count is printed.
restic_init='
  refused=0
  while :; do
    status=0
    output="$(restic --no-cache init 2>&1)" || status=$?
    if [ "$status" != 0 ] && [ "$refused" -lt 30 ] && printf "%s" "$output" | grep -q "connection refused"; then
      refused=$((refused + 1))
      sleep 1
      continue
    fi
    printf "%s\n" "$output"
    echo "init retries after refusal: $refused"
    exit "$status"
  done'
ready_endpoints="$(kubectl --namespace "$BACKUP_LAYER" get endpointslice --selector kubernetes.io/service-name=rest-server \
  --output jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}')"
[ -n "$ready_endpoints" ] || fail "the Service rest-server in $BACKUP_LAYER has no ready endpoint, so no Pod can reach it"
for namespace in $BACKUP_NAMESPACES; do
  run_restic "$namespace" "repository-init" "$restic_init"
  echo "$namespace: $(grep '^init retries after refusal' <<<"$restic_output" || echo 'init retries after refusal: not printed')"
  [ "$restic_exit" = 0 ] || fail "restic init did not initialise the repository of $namespace (exit $restic_exit): $restic_output"
  run_restore_test "$namespace" no-snapshot-test
  [ "$status" = failed ] || fail "the restore test of $namespace passed on a repository without a snapshot"
done
echo "the restore test of each namespace fails on its repository without a snapshot"

# LiteLLM's first key table needs a row for its restore test to pass; the master key, through a port-forward, makes the
# key by LiteLLM's own API, so the cell relies on no other cell. The key stays, like the backups below, until the
# namespace goes. The master key travels from kubectl's stdout through shell variables to curl's stdin, never in an
# argument; the reply is read only for the key's presence and goes nowhere else.
kubectl --namespace "$LITELLM_NAMESPACE" rollout status deployment/litellm --timeout=5m
master_key="$(kubectl --namespace "$LITELLM_NAMESPACE" get secret litellm --output jsonpath='{.data.master_key}' | base64 --decode)"
echo "::add-mask::$master_key"
litellm_port="$(kubectl --namespace "$LITELLM_NAMESPACE" get service litellm --output jsonpath='{.spec.ports[0].port}')"
forward_log="$RUNNER_TEMP/litellm-port-forward.log"
kubectl --namespace "$LITELLM_NAMESPACE" port-forward service/litellm ":$litellm_port" > "$forward_log" 2>&1 &
forward=$!
for _ in $(seq 30); do grep -q '^Forwarding from 127.0.0.1:' "$forward_log" && break; sleep 1; done
local_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -n 1)"
[ -n "$local_port" ] || fail "kubectl port-forward to the Service litellm did not start"
key_made="$(printf '%s\n' "header = \"Authorization: Bearer $master_key\"" 'header = "Content-Type: application/json"' 'data = "{}"' |
  curl --silent --show-error --fail-with-body --max-time 30 --config - "http://127.0.0.1:$local_port/key/generate")"
[ "$(yq --input-format json '.key | length > 0' <<<"$key_made")" = true ] || fail "the master key made no key in LiteLLM"
kill "$forward"
echo "the master key made the key that LiteLLM's first key table holds for its restore test"

for namespace in $BACKUP_NAMESPACES; do
  # One backup, as the Schedule would start it.
  schedule="$(kubectl --namespace "$namespace" get schedule postgres --output json)"
  kubectl --namespace "$namespace" create --filename - <<<"$(yq --output-format json \
    '{ "apiVersion": "k8up.io/v1", "kind": "Backup", "metadata": { "name": "first-backup" },
       "spec": { "backend": .spec.backend, "podConfigRef": .spec.podConfigRef } }' <<<"$schedule")" >/dev/null
  wait_completed "$namespace" backup first-backup

  # k8up's Job pod passed restricted and the image policy, and ran a listed image at a digest.
  job_image="$(kubectl --namespace "$namespace" get jobs --selector k8upjob=true \
    --output jsonpath='{.items[0].spec.template.spec.containers[0].image}')"
  [[ $job_image == *@sha256:* ]] || fail "k8up's Job pods in $namespace run $job_image, not an image at a digest"
  repository="${job_image%%@*}"
  repository="${repository%:*}"
  grep -qF "$repository" "$VENDOR_LIST" || fail "k8up's Job pods in $namespace run $repository, which the vendor list does not hold"
  echo "k8up's Job pods in $namespace ran as restricted at $job_image"

  # Neither the Job's log nor a Snapshot object may hold the repository's credentials. The log is read first: a failed
  # or empty read proves nothing, so it fails the step.
  job_logs="$(kubectl --namespace "$namespace" logs --selector k8upjob=true --all-pods --tail=-1)" ||
    fail "cannot read k8up's Job logs in $namespace"
  [ -n "$job_logs" ] || fail "k8up's Job logs in $namespace are empty"
  for key in password repository-password; do
    value="$(secret_value "$namespace" "$key")"
    [ -n "$value" ] || fail "cannot read $key of the Secret restic in $namespace"
    if grep -qF -f <(printf '%s\n' "$value") <<<"$job_logs"; then fail "k8up's Job logs in $namespace hold $key"; fi
  done
  snapshot_objects="$(kubectl --namespace "$namespace" get snapshots.k8up.io --output name)" ||
    fail "cannot list the Snapshot objects of $namespace"
  [ -z "$snapshot_objects" ] || fail "$namespace holds Snapshot objects, whose repository field would hold the rest password"
  echo "the logs and objects of $namespace hold none of its backup credentials"

  # One snapshot per run's shape; the dump's holds the dump alone, in custom format. A layer with a staging claim also
  # has a snapshot of it, which tests/backup/staging_snapshot_holds_the_files_and_the_dump_of_one_run.sh reads.
  per_run="$(snapshots_per_run "$namespace")"
  run_restic "$namespace" snapshot-listing '
    restic --no-cache snapshots --json | jq length
    restic --no-cache ls --json --path "/$(NAMESPACE)-postgres.dump" latest | jq --raw-output "select(.type == \"file\") | .path"
    # An early exit of head kills restic by SIGPIPE while it holds its read lock, which k8up prune then waits out; draining ends it.
    restic --no-cache dump --path "/$(NAMESPACE)-postgres.dump" latest "/$(NAMESPACE)-postgres.dump" | { head -c 5; cat >/dev/null; }'
  [ "$restic_exit" = 0 ] || fail "the snapshot of $namespace cannot be read (exit $restic_exit)"
  mapfile -t listing <<<"$restic_output"
  [ "${listing[0]}" = "$per_run" ] || fail "the repository of $namespace holds ${listing[0]} snapshots, not $per_run"
  [ "${listing[1]}" = "/$namespace-postgres.dump" ] || fail "the dump's snapshot of $namespace holds ${listing[1]}, not its dump"
  [ "${#listing[@]}" = 3 ] || fail "the dump's snapshot of $namespace holds further files beside its dump"
  [ "${listing[2]}" = PGDMP ] || fail "the dump's snapshot of $namespace holds no custom-format dump"
  echo "the repository of $namespace holds $per_run snapshots of one run, the dump's with its dump alone, in custom format"

  # The restore test passes on the snapshot.
  run_restore_test "$namespace" restore-test-run
  [ "$status" = passed ] || fail "the restore test of $namespace failed on its snapshot"
  echo "the restore test of $namespace passes on its snapshot"

  # The prune keeps exactly the rule the component declares: k8up adds a daily rule to a Prune that sets none, so the Job's
  # KEEP_* variables must equal the component's retention and carry nothing more. One Prune, as the Schedule would start it.
  kubectl --namespace "$namespace" create --filename - <<<"$(yq --output-format json \
    '{ "apiVersion": "k8up.io/v1", "kind": "Prune", "metadata": { "name": "first-prune" },
       "spec": { "backend": .spec.backend, "podConfigRef": .spec.podConfigRef, "retention": .spec.prune.retention } }' <<<"$schedule")" >/dev/null
  wait_completed "$namespace" prune first-prune
  expected_rule="$(yq 'select(.kind == "Schedule") | .spec.prune.retention | to_entries | .[] |
    "KEEP_" + (.key | sub("^keep"; "") | upcase) + "=" + (.value | tostring)' "$BACKUP_SCHEDULE_COMPONENT/schedule.yaml" | sort)"
  [ -n "$expected_rule" ] || fail "$BACKUP_SCHEDULE_COMPONENT/schedule.yaml declares no retention"
  actual_rule="$(kubectl --namespace "$namespace" get jobs --output json | yq --input-format json \
    '.items[] | select(.metadata.ownerReferences[].name == "first-prune") | .spec.template.spec.containers[0].env[] |
     select(.name | test("^KEEP_")) | .name + "=" + .value' | sort)"
  [ "$actual_rule" = "$expected_rule" ] ||
    fail "the prune Job of $namespace keeps $(tr '\n' ' ' <<<"$actual_rule"), the component declares $(tr '\n' ' ' <<<"$expected_rule")"
  echo "the prune Job of $namespace keeps exactly: $(tr '\n' ' ' <<<"$actual_rule")"
done

# The restore test fails on an empty first key table: the same test, with a key-tables file whose first table the database leaves empty.
empty_namespace="${BACKUP_NAMESPACES%% *}"
[ "$(kubectl --namespace "$empty_namespace" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only --no-align \
  --command="SELECT count(*) FROM $EMPTY_KEY_TABLE")" = 0 ] || fail "the table $EMPTY_KEY_TABLE of $empty_namespace is not empty"
kubectl --namespace "$empty_namespace" get configmap postgres --output json |
  TABLE="$EMPTY_KEY_TABLE" yq --output-format json '{ "apiVersion": "v1", "kind": "ConfigMap",
    "metadata": { "name": "postgres-empty-first-table" }, "data": (.data | .["key-tables"] = strenv(TABLE)) }' |
  kubectl --namespace "$empty_namespace" create --filename - >/dev/null
run_restore_test "$empty_namespace" empty-first-table-test postgres-empty-first-table
kubectl --namespace "$empty_namespace" delete configmap postgres-empty-first-table >/dev/null
[ "$status" = failed ] || fail "the restore test of $empty_namespace passed on an empty first key table"
echo "the restore test of $empty_namespace fails on an empty first key table"

# A namespace reaches only its own repository; no credentials reach none; a namespace without one reaches the server not.
# A fresh Pod's first connection can meet a refusal before the network policy admits its address, so the requests that
# expect an answer retry a refused connection for a bounded time; curl retries no 401 or 403, and the request that expects
# no answer overrides the client Pod's own retry with --retry 0, so a retryable answer followed by refusals cannot leave
# only the final 000.
retry=(--retry 5 --retry-connrefused --retry-delay 2 --retry-max-time 30)
first="${BACKUP_NAMESPACES%% *}"
second="${BACKUP_NAMESPACES##* }"
[ "$first" != "$second" ] || fail "the isolation proof needs two backup namespaces, but BACKUP_NAMESPACES is '$BACKUP_NAMESPACES'"
request "$first" no-credentials-own "$UNROUTED_HOST" "$rest_base/$first/config" "${retry[@]}"
[ "$status" = 401 ] || fail "without credentials the server answered $status under /$first/"
request "$first" no-credentials-foreign "$UNROUTED_HOST" "$rest_base/$second/config" "${retry[@]}"
[ "$status" = 401 ] || fail "without credentials the server answered $status under /$second/"
echo "without credentials the server answers 401 everywhere"
request "$OUTSIDE_NAMESPACE" outside-namespace "$UNROUTED_HOST" "$rest_base/$first/config" --retry 0
[ "$status" = 000 ] && [ "$exit_code" != 0 ] ||
  fail "a pod in $OUTSIDE_NAMESPACE reached the rest-server (status '$status', curl exit $exit_code)"
echo "a pod in $OUTSIDE_NAMESPACE gets no answer, while a pod in $first was answered above"
credential_requests='
status() {
  printf "user = \"%s:%s\"\n" "$RESTIC_REST_USERNAME" "$RESTIC_REST_PASSWORD" |
    curl --silent --output /dev/null --write-out "%{http_code}\n" @RETRY@ --config - "$@"
}
status "@BASE@/@OWN@/config"
status "@BASE@/@OTHER@/config"
status --request DELETE "@BASE@/@OTHER@/config"'
credential_requests="${credential_requests//@RETRY@/${retry[*]}}"
credential_requests="${credential_requests//@BASE@/$rest_base}"
credential_requests="${credential_requests//@OWN@/$first}"
run_restic "$first" isolation-check "${credential_requests//@OTHER@/$second}"
mapfile -t statuses <<<"$restic_output"
[ "${statuses[0]}" = 200 ] || fail "$first's credentials got ${statuses[0]} under its own /$first/, not 200"
[[ ${statuses[1]} == 40[13] ]] || fail "$first's credentials got ${statuses[1]} under /$second/, not 401 or 403"
[[ ${statuses[2]} == 40[13] ]] || fail "$first's credentials got ${statuses[2]} deleting /$second/config, not 401 or 403"
second_snapshots="$(snapshots_per_run "$second")"
run_restic "$second" foreign-snapshots 'restic --no-cache snapshots --json | jq length'
[ "$restic_exit" = 0 ] && [ "$restic_output" = "$second_snapshots" ] ||
  fail "$second's snapshots after the attempts read '$restic_output' (exit $restic_exit), not $second_snapshots"
echo "$first's credentials read only its own repository, and $second's snapshots stay"

# A deleted Kustomization keeps the claim, and the snapshots list again after the root re-creates it.
claim="$(kubectl --namespace "$BACKUP_LAYER" get pvc rest-server-data --output jsonpath='{.metadata.uid}|{.spec.volumeName}')"
kubectl --namespace flux-system delete kustomization "$BACKUP_LAYER" --wait --timeout=3m
kubectl --namespace "$BACKUP_LAYER" wait deployment/rest-server --for=delete --timeout=3m
[ "$(kubectl --namespace "$BACKUP_LAYER" get pvc rest-server-data --output jsonpath='{.metadata.uid}|{.spec.volumeName}')" = "$claim" ] ||
  fail "the claim of the rest-server is not the one before the deletion"
echo "the deleted Kustomization $BACKUP_LAYER left the claim of the rest-server"
flux reconcile kustomization flux-system --timeout=5m
kubectl --namespace flux-system wait kustomization "$BACKUP_LAYER" --for=create --timeout=1m
kubectl --namespace flux-system wait kustomization "$BACKUP_LAYER" --for=condition=Ready --timeout=5m
for namespace in $BACKUP_NAMESPACES; do
  per_run="$(snapshots_per_run "$namespace")"
  run_restic "$namespace" snapshots-again 'restic --no-cache snapshots --json | jq length'
  [ "$restic_exit" = 0 ] && [ "$restic_output" = "$per_run" ] ||
    fail "$namespace's snapshots after the root re-created the layer read '$restic_output' (exit $restic_exit), not $per_run"
done
echo "each namespace's snapshots list again after the root re-created the Kustomization $BACKUP_LAYER"

# backup:fetch: the shipped task writes the latest dump at mode 0600 from the same init container; a second run refuses.
fetched="$RUNNER_TEMP/fetched.dump"
mise run backup:fetch "$first" "$fetched"
[ "$(stat --format=%a "$fetched")" = 600 ] || fail "backup:fetch wrote $fetched at mode $(stat --format=%a "$fetched"), not 600"
[ "$(head -c 5 "$fetched")" = PGDMP ] || fail "backup:fetch wrote no custom-format dump to $fetched"
fetched_before="$(sha256sum <"$fetched")"
if mise run backup:fetch "$first" "$fetched"; then fail "backup:fetch overwrote the existing file $fetched"; fi
[ "$(sha256sum <"$fetched")" = "$fetched_before" ] || fail "backup:fetch changed the existing file $fetched while refusing it"
echo "backup:fetch wrote the latest dump of $first at mode 0600 and refuses an existing file"
rm -f -- "$fetched"
