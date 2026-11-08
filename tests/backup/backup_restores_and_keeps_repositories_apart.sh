#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
# The backup's proofs on the cluster, each with its positive control; no secret is printed.
export KUBECONFIG="$HOME/.kube/config"

# run_restic <namespace> <name> <shell script>: a Pod built from the restore test's own init container, so it holds the
# namespace's repository credentials as the test does and nothing more; runs the script, sets its output (what it writes to
# stdout) and exit code. Its stderr goes to the container's termination message, since `kubectl logs` merges the two
# streams, and reaches this script's stderr when the script fails; a script that wants an error text in its output
# redirects 2>&1 itself.
# shellcheck disable=SC2034 # restic_output and restic_exit are this function's results for the cells below.
run_restic() {
  local namespace="$1" name="$2" script="$3" manifest
  manifest="$(kubectl --namespace "$namespace" get cronjob restore-test --output json |
    NAME="$name" SCRIPT="$script" yq --output-format json \
      '.spec.jobTemplate.spec.template.spec as $spec | $spec.initContainers[0] as $dump |
       { "apiVersion": "v1", "kind": "Pod", "metadata": { "name": strenv(NAME) }, "spec": ($spec | del(.initContainers) |
           .volumes |= map(select(.name == "restore")) |
           .containers = [$dump | .name = "restic" | .command = ["sh", "-c", "exec 2>/dev/termination-log\n" + strenv(SCRIPT)]]) }')"
  kubectl --namespace "$namespace" create --filename - <<<"$manifest" >/dev/null
  kubectl --namespace "$namespace" wait "pod/$name" --timeout=5m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'
  restic_exit="$(kubectl --namespace "$namespace" get "pod/$name" \
    --output jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  restic_output="$(kubectl --namespace "$namespace" logs "pod/$name")"
  if [ "$restic_exit" != 0 ]; then
    kubectl --namespace "$namespace" get "pod/$name" \
      --output jsonpath='{.status.containerStatuses[0].state.terminated.message}' >&2
  fi
  kubectl --namespace "$namespace" delete pod "$name" --wait --timeout=2m >/dev/null
}
# job_ended <namespace> <job>: waits for the Job's end; 0 when it completed, 1 when it failed.
job_ended() {
  local namespace="$1" job="$2" deadline=$((SECONDS + 600)) state
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(kubectl --namespace "$namespace" get job "$job" \
      --output jsonpath='{.status.conditions[?(@.status=="True")].type}')"
    case "$state" in
      *Complete*) return 0 ;;
      *Failed*) return 1 ;;
    esac
    sleep 5
  done
  fail "the Job $namespace/$job did not end within 10 minutes"
}
# run_restore_test <namespace> <job> [<configmap>]: runs the CronJob as it is, or with another ConfigMap as its checks.
run_restore_test() {
  local namespace="$1" job="$2" checks="${3:-}" job_manifest
  job_manifest="$(kubectl --namespace "$namespace" create job "$job" --from=cronjob/restore-test --dry-run=client --output json)"
  if [ -n "$checks" ]; then
    job_manifest="$(CHECKS="$checks" yq --output-format json \
      '(.spec.template.spec.volumes[] | select(.name == "checks") | .configMap.name) = strenv(CHECKS)' <<<"$job_manifest")"
  fi
  kubectl --namespace "$namespace" create --filename - <<<"$job_manifest" >/dev/null
  if job_ended "$namespace" "$job"; then status=passed; else status=failed; fi
  kubectl --namespace "$namespace" delete job "$job" --cascade=foreground --wait --timeout=2m >/dev/null
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

for namespace in $BACKUP_NAMESPACES; do
  # One backup, as the Schedule would start it.
  schedule="$(kubectl --namespace "$namespace" get schedule postgres --output json)"
  kubectl --namespace "$namespace" create --filename - <<<"$(yq --output-format json \
    '{ "apiVersion": "k8up.io/v1", "kind": "Backup", "metadata": { "name": "first-backup" },
       "spec": { "backend": .spec.backend, "podConfigRef": .spec.podConfigRef } }' <<<"$schedule")" >/dev/null
  deadline=$((SECONDS + 600))
  while :; do
    reason="$(kubectl --namespace "$namespace" get backup first-backup \
      --output jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')"
    [ -z "$reason" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      kubectl --namespace "$namespace" describe backup first-backup
      kubectl --namespace "$namespace" get jobs,pods
      fail "the Backup of $namespace did not complete within 10 minutes"
    fi
    sleep 5
  done
  [ "$reason" = Succeeded ] || {
    kubectl --namespace "$namespace" describe backup first-backup
    fail "the Backup of $namespace ended with reason $reason"
  }

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

  # One snapshot, the dump alone, in custom format.
  run_restic "$namespace" snapshot-listing '
    restic --no-cache snapshots --json | jq length
    restic --no-cache ls --json latest | jq --raw-output "select(.type == \"file\") | .path"
    restic --no-cache dump latest "/$(NAMESPACE)-postgres.dump" | head -c 5'
  [ "$restic_exit" = 0 ] || fail "the snapshot of $namespace cannot be read (exit $restic_exit)"
  mapfile -t listing <<<"$restic_output"
  [ "${listing[0]}" = 1 ] || fail "the repository of $namespace holds ${listing[0]} snapshots, not 1"
  [ "${listing[1]}" = "/$namespace-postgres.dump" ] || fail "the snapshot of $namespace holds ${listing[1]}, not its dump"
  [ "${#listing[@]}" = 3 ] || fail "the snapshot of $namespace holds further files beside its dump"
  [ "${listing[2]}" = PGDMP ] || fail "the snapshot of $namespace holds no custom-format dump"
  echo "the repository of $namespace holds one snapshot with its dump alone, in custom format"

  # The restore test passes on the snapshot.
  run_restore_test "$namespace" restore-test-run
  [ "$status" = passed ] || fail "the restore test of $namespace failed on its snapshot"
  echo "the restore test of $namespace passes on its snapshot"
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
run_restic "$second" foreign-snapshots 'restic --no-cache snapshots --json | jq length'
[ "$restic_exit" = 0 ] && [ "$restic_output" = 1 ] || fail "$second's snapshots after the attempts read '$restic_output' (exit $restic_exit), not 1"
echo "$first's credentials read only its own repository, and $second's snapshot stays"

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
  run_restic "$namespace" snapshots-again 'restic --no-cache snapshots --json | jq length'
  [ "$restic_exit" = 0 ] && [ "$restic_output" = 1 ] ||
    fail "$namespace's snapshots after the root re-created the layer read '$restic_output' (exit $restic_exit), not 1"
done
echo "each namespace's snapshot lists again after the root re-created the Kustomization $BACKUP_LAYER"

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
