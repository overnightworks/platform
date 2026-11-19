# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # namespace is the sourcing cell's; staged_pod, run_logs and refused_pod are results for it.
# Sourced by the cells that run Backups of the namespace in $namespace and read the PreBackupPod's pod while it stages, which
# set namespace first and call delete_backups from their exit trap, once the pods they started are deleted.
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=restic_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/restic_pod.sh"

backups=()
deployments=()
# delete_backups: the Backups the cell made and the Deployments k8up made for its refused ones.
delete_backups() {
  local name
  for name in "${backups[@]}"; do
    delete_object --namespace "$namespace" delete backup "$name" --ignore-not-found --wait --timeout=2m
  done
  for name in "${deployments[@]}"; do
    delete_object --namespace "$namespace" delete deployment "$name" --ignore-not-found --wait --timeout=2m
  done
}

# backup_pods: how many Pods of the namespace carry a backup command; backup_pod: the first one's name.
backup_pods() {
  kubectl --namespace "$namespace" get pods --output json |
    jq '[.items[] | select(.metadata.annotations["k8up.io/backupcommand"] != null)] | length'
}
backup_pod() {
  kubectl --namespace "$namespace" get pods --output json |
    jq --raw-output '[.items[] | select(.metadata.annotations["k8up.io/backupcommand"] != null) | .metadata.name] | .[0] // ""'
}

# create_backup <name>: one Backup, as the Schedule would start it.
create_backup() {
  backups+=("$1")
  kubectl --namespace "$namespace" get schedule postgres --output json |
    NAME="$1" yq --input-format json --output-format json \
      '{ "apiVersion": "k8up.io/v1", "kind": "Backup", "metadata": { "name": strenv(NAME) },
         "spec": { "backend": .spec.backend, "podConfigRef": .spec.podConfigRef } }' |
    kubectl --namespace "$namespace" create --filename - >/dev/null
}

# The verdict of a vendor container on the staged dump, whose bytes it never prints: the dump is 70's and 0640, and the
# vendor containers copy and bucket are outside group 70.
dump_verdict='if [ ! -s /staging/postgres.dump ]; then echo missing; elif cat /staging/postgres.dump >/dev/null 2>&1; then echo readable; else echo unreadable; fi'

# vendor_dump_verdicts <pod>: "<container> <verdict>" for each vendor container the pod has; fails when the pod is gone.
vendor_dump_verdicts() {
  local container pod_json
  pod_json="$(kubectl --namespace "$namespace" get pod "$1" --output json)" || return 1
  for container in copy bucket; do
    CONTAINER="$container" yq --exit-status '.spec.containers[] | select(.name == strenv(CONTAINER))' <<<"$pod_json" >/dev/null 2>&1 || continue
    echo "$container $(kubectl --namespace "$namespace" exec "$1" --container "$container" -- sh -c "$dump_verdict" 2>/dev/null)" || return 1
  done
}

# run_backup <name>: a Backup that must succeed; at every look at most one Pod carries a backup command. Once the
# PreBackupPod's pod is Ready, its spec goes to staged_pod and its containers' logs to run_logs, and its vendor
# containers must not read the dump.
staged_pod=
run_logs=
run_backup() {
  local name="$1" deadline=$((SECONDS + 300)) pods pod pod_logs reason captured=false verdicts container verdict
  create_backup "$name"
  while :; do
    pods="$(backup_pods)"
    [ "$pods" -le 1 ] || fail "$pods Pods of $namespace carry a backup command during the Backup $name"
    pod="$(backup_pod)"
    if [ "$captured" = false ] && [ -n "$pod" ] &&
      [ "$(kubectl --namespace "$namespace" get pod "$pod" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; then
      # k8up may remove the pod between two reads; the next look tries again.
      if staged_pod="$(kubectl --namespace "$namespace" get pod "$pod" --output json 2>/dev/null)" &&
        pod_logs="$(kubectl --namespace "$namespace" logs "pod/$pod" --all-containers 2>/dev/null)" &&
        verdicts="$(vendor_dump_verdicts "$pod")"; then
        run_logs+="$pod_logs"$'\n'
        captured=true
        [ -n "$verdicts" ] || fail "the pod of the Backup $name has no vendor container to read the staged dump"
        while read -r container verdict; do
          [ "$verdict" = unreadable ] || fail "the $container container of the Backup $name's pod finds the staged dump $verdict, not unreadable"
        done <<<"$verdicts"
      fi
    fi
    reason="$(kubectl --namespace "$namespace" get backup "$name" \
      --output jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')"
    [ -z "$reason" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      kubectl --namespace "$namespace" describe backup "$name" >&2
      fail "the Backup $name of $namespace did not complete within 5 minutes"
    fi
    sleep 1
  done
  [ "$reason" = Succeeded ] || fail "the Backup $name of $namespace ended with reason $reason"
  [ "$captured" = true ] || fail "the PreBackupPod's pod of the Backup $name was never seen Ready"
}

# refused_backup <name> <refusal>: a Backup whose stager logs the refusal (an extended regular expression); sets
# refused_pod, and fails when the pod turns Ready.
refused_pod=
refused_backup() {
  local name="$1" refusal="$2" deadline=$((SECONDS + 300)) logs
  create_backup "$name"
  while :; do
    refused_pod="$(backup_pod)"
    if [ -n "$refused_pod" ]; then
      logs="$(kubectl --namespace "$namespace" logs "pod/$refused_pod" --container stager 2>/dev/null || true)"
      ! grep -Eq "$refusal" <<<"$logs" || break
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "the stager of the Backup $name did not refuse within 5 minutes"
    sleep 1
  done
  [ "$(kubectl --namespace "$namespace" get pod "$refused_pod" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != True ] ||
    fail "the PreBackupPod's pod of the Backup $name turned Ready after its stager refused"
  run_logs+="$(kubectl --namespace "$namespace" logs "pod/$refused_pod" --all-containers)"$'\n'
}

# report_backup_pods: what holds the Pods that carry a backup command and the pre-backup ReplicaSets and Deployments,
# by name, phase, container states, deletionTimestamp and owners; no log, Secret or environment value.
report_backup_pods() {
  kubectl --namespace "$namespace" get pods --output json | jq --raw-output '
    .items[] | select(.metadata.annotations["k8up.io/backupcommand"] != null) |
    "pod \(.metadata.name) phase=\(.status.phase) containers=\([.status.containerStatuses[]? | .name + ":" + (.state | keys[0])] | join(",")) " +
    "deletionTimestamp=\(.metadata.deletionTimestamp // "none") owners=\([.metadata.ownerReferences[]? | .kind + "/" + .name] | join(","))"' >&2 || true
  kubectl --namespace "$namespace" get replicasets,deployments --selector k8up.io/preBackupPod --output json | jq --raw-output '
    .items[] | "\(.kind) \(.metadata.name) deletionTimestamp=\(.metadata.deletionTimestamp // "none") " +
    "finalizers=\(.metadata.finalizers // [] | join(",")) owners=\([.metadata.ownerReferences[]? | .kind + "/" + .name] | join(","))"' >&2 || true
}

# end_backup <name>: deletes a refused Backup and the Deployment k8up made for its PreBackupPod, before k8up's deadline,
# then waits for the Pod to go; at the deadline it reports what still carries a backup command.
end_backup() {
  local name="$1" replica_set deployment deadline=$((SECONDS + 120))
  replica_set="$(kubectl --namespace "$namespace" get pod "$refused_pod" --output jsonpath='{.metadata.ownerReferences[0].name}')"
  deployment="$(kubectl --namespace "$namespace" get replicaset "$replica_set" --output jsonpath='{.metadata.ownerReferences[0].name}')"
  deployments+=("$deployment")
  kubectl --namespace "$namespace" delete backup "$name" --wait --timeout=2m >/dev/null
  kubectl --namespace "$namespace" delete deployment "$deployment" --ignore-not-found --wait --timeout=2m >/dev/null
  until [ "$(backup_pods)" = 0 ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      report_backup_pods
      fail "within the time: no Pod of $namespace carries a backup command after the Backup $name"
    fi
    sleep 5
  done
}

# staged_file_exists <path>: whether the refused pod's stager sees the path under /staging or /scratch.
staged_file_exists() { kubectl --namespace "$namespace" exec "$refused_pod" --container stager -- test -e "$1"; }

