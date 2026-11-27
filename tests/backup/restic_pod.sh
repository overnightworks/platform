# shellcheck shell=bash
# Sourced by the scripts under tests/backup/ that read a namespace's restic repository or run its restore test.
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

# The Pods and Jobs started here, as "<namespace> <kind> <name>"; a script's exit trap calls delete_restic_objects.
restic_objects=()

# delete_restic_objects: deletes what is left of them, so a failed wait or a failed cell leaves nothing behind.
delete_restic_objects() {
  local entry namespace kind name
  for entry in "${restic_objects[@]}"; do
    read -r namespace kind name <<<"$entry"
    delete_object --namespace "$namespace" delete "$kind" "$name" --ignore-not-found --cascade=foreground --wait --timeout=2m
  done
}

# run_restic <namespace> <name> <shell script> [<directory>]: a Pod built by scripts/restic_dump_pod.sh from the
# restore test's restic container, so it holds the namespace's repository credentials as the test does and nothing
# more, and an emptyDir at the directory when one is named (a path the script backs up, which restic records in its
# snapshot); runs the script, sets its output (what it writes to stdout) and exit code. Its stderr goes to the
# container's termination message, since `kubectl logs` merges the two streams, and reaches this script's stderr when
# the script fails; a script that wants an error text in its output redirects 2>&1 itself.
# shellcheck disable=SC2034 # restic_output and restic_exit are this function's results for the cells below.
run_restic() {
  local namespace="$1" name="$2" script="$3" directory="${4:-}" manifest
  manifest="$("$(dirname "${BASH_SOURCE[0]}")/../../scripts/restic_dump_pod.sh" "$namespace" "$name" \
    "exec 2>/dev/termination-log
$script" |
    DIRECTORY="$directory" yq --output-format json \
      'if strenv(DIRECTORY) == "" then . else
         .spec.volumes += [{"name": "directory", "emptyDir": {}}] |
         .spec.containers[0].volumeMounts += [{"name": "directory", "mountPath": strenv(DIRECTORY)}] end')"
  restic_objects+=("$namespace pod $name")
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
# init_restic_repository <namespace>: restic init of the namespace's repository from a run_restic Pod, fails when it does
# not initialise it; sets restic_output. restic's REST backend creates a repository with one request that no retry wraps,
# so a fresh Pod's first packets can meet a refusal before the network policy admits its address; init alone is retried,
# only on a refusal, and its count is printed.
init_restic_repository() {
  local namespace="$1"
  run_restic "$namespace" repository-init '
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
  [ "$restic_exit" = 0 ] || fail "restic init did not initialise the repository of $namespace (exit $restic_exit): $restic_output"
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
# pod_logs <namespace> <pod>: what each container that started printed, each line led by `[pod/<pod>/<container>]`;
# a container that never started is skipped, and one whose log cannot be read fails the call.
pod_logs() {
  local namespace="$1" pod="$2" containers container log line
  containers="$(kubectl --namespace "$namespace" get pod "$pod" --output json | yq --input-format json \
    '((.status.initContainerStatuses // []) + (.status.containerStatuses // [])) | .[] | select(.state.waiting == null) | .name')" || return 1
  while IFS= read -r container; do
    [ -n "$container" ] || continue
    log="$(kubectl --namespace "$namespace" logs "pod/$pod" --container "$container")" || return 1
    [ -z "$log" ] || while IFS= read -r line; do printf '[pod/%s/%s] %s\n' "$pod" "$container" "$line"; done <<<"$log"
  done <<<"$containers"
}

# run_restore_test <namespace> <job> [<configmap> [<cronjob>]]: runs the CronJob restore-test, or the one named, as it is,
# or with another ConfigMap as its checks;
# sets status to passed or failed, restore_exits to "dump <exit> check <exit>" (an exit the container never reached reads
# as none), restore_log to what the check printed and restore_pod_log to what every container of the pod printed, each
# line led by its container's name.
# shellcheck disable=SC2034 # status, restore_exits, restore_log and restore_pod_log are this function's results for the cells that source this file.
run_restore_test() {
  local namespace="$1" job="$2" checks="${3:-}" cronjob="${4:-restore-test}" job_manifest pod exits
  job_manifest="$(kubectl --namespace "$namespace" create job "$job" --from="cronjob/$cronjob" --dry-run=client --output json)"
  if [ -n "$checks" ]; then
    job_manifest="$(CHECKS="$checks" yq --output-format json \
      '(.spec.template.spec.volumes[] | select(.name == "checks") | .configMap.name) = strenv(CHECKS)' <<<"$job_manifest")"
  fi
  restic_objects+=("$namespace job $job")
  kubectl --namespace "$namespace" create --filename - <<<"$job_manifest" >/dev/null
  if job_ended "$namespace" "$job"; then status=passed; else status=failed; fi
  pod="$(kubectl --namespace "$namespace" get pods --selector "batch.kubernetes.io/job-name=$job" \
    --output jsonpath='{.items[0].metadata.name}')"
  exits="$(kubectl --namespace "$namespace" get pod "$pod" --output json | yq --input-format json \
    '[.status.initContainerStatuses[0], .status.containerStatuses[0]] | map(.state.terminated.exitCode // "none") | join(" ")')"
  restore_exits="dump ${exits% *} check ${exits#* }"
  restore_log="$(kubectl --namespace "$namespace" logs "pod/$pod" --container restore-test 2>/dev/null || true)"
  restore_pod_log="$(pod_logs "$namespace" "$pod")" || fail "a container of the pod $pod of the Job $job started and its log cannot be read"
  kubectl --namespace "$namespace" delete job "$job" --cascade=foreground --wait --timeout=2m >/dev/null
}


# require_restore_passed <description>: the last run_restore_test passed; else prints its container exits and what its
# containers printed to stderr, ahead of the failure that names the description, so a failed cell carries the Job's reason.
require_restore_passed() {
  [ "$status" = passed ] && return 0
  {
    echo "restore test exits: $restore_exits"
    echo "restore test pod log:"
    echo "$restore_pod_log"
  } >&2
  fail "$1"
}
