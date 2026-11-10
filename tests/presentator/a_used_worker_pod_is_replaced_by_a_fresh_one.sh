#!/usr/bin/env bash
# a_used_worker_pod_is_replaced_by_a_fresh_one.sh: in k3d, shows that the StatefulSet of apps/presentator, with only its
# worker container's image and command replaced by a stand-in, gives every exit of the worker a fresh pod: after a
# life's end and after a crash the pod has a new uid, its init container ran again, its worker never restarted and its
# scratch was empty; a running pod is left alone; an exit loop makes one pod at a time, restarts no container and leaves
# the node's leases, links and sandboxes as they were; and after a removed sandbox the worker runs again in the same pod,
# finds its scratch used and ends it, which gives a fresh pod too. It needs CLUSTER_NAME and PROBE_IMAGE, and creates and
# deletes the Namespace $REPLACEMENT_NAMESPACE, which carries no Pod Security label. The stand-in appends to the file
# lives in the claim: "empty" when every scratch directory of the worker was empty at its start, else "used" and exit 2.
# It then waits for the file trigger in the claim, whose content is its exit status. In loop mode it exits 2 at once.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../no_network/pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../no_network/pod.sh"
server="k3d-${CLUSTER_NAME}-server-0"
namespace="${REPLACEMENT_NAMESPACE:-presentator-replacement}"
started_at=$SECONDS
work="$(mktemp -d)"
namespace_created=
remove_objects() {
  local cell_status=$?
  rm -rf "$work"
  [ -z "$namespace_created" ] || delete_object delete namespace --wait --timeout=2m "$namespace"
  end_deletions "$cell_status"
}
trap remove_objects EXIT
k() { kubectl -n "$namespace" "$@"; }

STAND_IN="$(
  cat <<'EOF'
set -eu
mode="$1" claim="$2"
shift 2
[ "$mode" = serve ] || exit 2
for scratch in "$@"; do
  if [ -n "$(ls -A "$scratch")" ]; then
    echo used >>"$claim/lives"
    exit 2
  fi
done
echo empty >>"$claim/lives"
for scratch in "$@"; do echo marker >"$scratch/marker"; done
until [ -e "$claim/trigger" ]; do sleep 1; done
code="$(cat "$claim/trigger")"
rm "$claim/trigger"
exit "$code"
EOF
)"

# The StatefulSet, its ServiceAccount and its claim as the render has them, with the names read from it.
kubectl kustomize apps/presentator >"$work/presentator.yaml"
yq --no-doc 'select(.kind == "StatefulSet") | .metadata.name' "$work/presentator.yaml" >"$work/names"
[ "$(wc -l <"$work/names")" = 1 ] || fail "the render holds not exactly one StatefulSet"
statefulset="$(cat "$work/names")"
pod="$statefulset-0"
pod_spec='select(.kind == "StatefulSet") | .spec.template.spec'
[ "$(yq --no-doc "$pod_spec | .containers | length" "$work/presentator.yaml")" = 1 ] ||
  fail "the StatefulSet does not hold exactly one container"
account="$(yq --no-doc "$pod_spec | .serviceAccountName" "$work/presentator.yaml")"
claim_volume="$(yq --no-doc "$pod_spec | .volumes[] | select(has(\"persistentVolumeClaim\")) | .name" "$work/presentator.yaml")"
claim="$(yq --no-doc "$pod_spec | .volumes[] | select(.name == \"$claim_volume\") | .persistentVolumeClaim.claimName" "$work/presentator.yaml")"
claim_mount="$(yq --no-doc "$pod_spec | .containers[0].volumeMounts[] | select(.name == \"$claim_volume\") | .mountPath" "$work/presentator.yaml")"
scratch_mounts="$(yq --no-doc "$pod_spec | [.volumes[] | select(has(\"emptyDir\")) | .name] as \$scratch
  | .containers[0].volumeMounts[] | select(.name as \$name | \$scratch | any_c(. == \$name)) | .mountPath" "$work/presentator.yaml" | tr '\n' ' ')"
[ -n "$account" ] && [ -n "$claim" ] && [ -n "$claim_mount" ] && [ -n "$scratch_mounts" ] ||
  fail "the render names no ServiceAccount, claim, its mount or scratch mount of the worker"

# statefulset_manifest <replicas> <serve|loop>: the render's StatefulSet in the cell's Namespace, its worker container
# running the stand-in from PROBE_IMAGE in that mode.
statefulset_manifest() {
  REPLICAS="$1" MODE="$2" NAMESPACE="$namespace" IMAGE="$PROBE_IMAGE" PROGRAM="$STAND_IN" CLAIM_MOUNT="$claim_mount" SCRATCH="$scratch_mounts" \
    yq --no-doc 'select(.kind == "StatefulSet") | .metadata.namespace = strenv(NAMESPACE) | .spec.replicas = env(REPLICAS)
      | .spec.template.spec.containers[0] |= (.image = strenv(IMAGE)
        | .command = ["sh", "-c", strenv(PROGRAM), "stand-in", strenv(MODE), strenv(CLAIM_MOUNT)] + (strenv(SCRATCH) | split(" ") | map(select(length > 0))))' \
    "$work/presentator.yaml"
}

kubectl create namespace "$namespace"
namespace_created=1
{
  ACCOUNT="$account" NAMESPACE="$namespace" yq --no-doc 'select(.kind == "ServiceAccount" and .metadata.name == strenv(ACCOUNT)) | .metadata.namespace = strenv(NAMESPACE)' "$work/presentator.yaml"
  echo ---
  CLAIM="$claim" NAMESPACE="$namespace" yq --no-doc 'select(.kind == "PersistentVolumeClaim" and .metadata.name == strenv(CLAIM)) | .metadata.namespace = strenv(NAMESPACE)' "$work/presentator.yaml"
} | k apply -f -
find_lease_directory
node_before="$(node_state)" || exit 1

# observe: sets uid (empty when the pod is absent), phase, init_exit, restarts and started (when the worker runs) from the pod.
observe() {
  local reply
  reply="$(k get pod "$pod" --ignore-not-found -o jsonpath='{.metadata.uid},{.status.phase},{.status.initContainerStatuses[0].state.terminated.exitCode},{.status.containerStatuses[0].restartCount},{.status.containerStatuses[0].state.running.startedAt}')" ||
    fail "the read of pod/$pod failed"
  IFS=, read -r uid phase init_exit restarts started <<<"$reply"
}
now_milliseconds() { echo $(($(date +%s%N) / 1000000)); }
pods_of_the_statefulset() { k get pods -o jsonpath='{range .items[*]}{.metadata.uid},{.status.containerStatuses[0].restartCount}{"\n"}{end}'; }
# wait_until <seconds> <command>...: succeeds when the command does within the time, tried twice a second.
wait_until() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.5
  done
}
wait_for() { wait_until "$1" "${@:3}" || fail "within the time: $2"; }
worker_runs() { observe; [ -n "$started" ]; }
is_successor_of() { observe; [ -n "$uid" ] && [ "$uid" != "$1" ] && [ -n "$started" ]; }
lives_log() { k exec "$pod" -c worker -- cat "$claim_mount/lives" 2>/dev/null || true; }
expected_lives=
lives_are_as_expected() { [ "$(lives_log)" = "$expected_lives" ]; }
# stand_in_logged <empty|used>...: the lives of the stand-in so far, as the file in the claim lists them.
stand_in_logged() {
  local life
  for life in "$@"; do expected_lives+="${expected_lives:+$'\n'}$life"; done
  wait_until 60 lives_are_as_expected ||
    fail "the stand-in's file lists '$(lives_log | tr '\n' ' ')', not '$(tr '\n' ' ' <<<"$expected_lives")'"
}
trigger_exit() { k exec "$pod" -c worker -- sh -c "echo $1 >'$claim_mount/trigger.new' && mv '$claim_mount/trigger.new' '$claim_mount/trigger'"; }
# fresh_pod_holds: the pod now observed is running, its init container ended 0, its worker never
# restarted, and it is the only pod of the StatefulSet.
fresh_pod_holds() {
  [ "$phase" = Running ] || fail "the successor's phase is '$phase', not Running"
  [ "$init_exit" = 0 ] || fail "remove-link ended '$init_exit' in the successor, not 0"
  [ "$restarts" = 0 ] || fail "the successor's worker restarted $restarts times"
  [ "$(k get pods -o name | wc -l)" = 1 ] || fail "the namespace holds $(k get pods -o name | wc -l) pods besides the successor: $(k get pods -o name | tr '\n' ' ')"
}
# end_a_life <exit status> <description>: the stand-in ends with the status; a pod with a new uid then runs.
end_a_life() {
  local old_uid="$uid" triggered elapsed
  trigger_exit "$1"
  triggered="$(now_milliseconds)"
  wait_for 120 "a pod with a new uid whose worker runs after $2" is_successor_of "$old_uid"
  elapsed=$(($(now_milliseconds) - triggered))
  echo "$2: the successor's worker ran $((elapsed / 1000)).$((elapsed % 1000 / 100)) seconds after the trigger"
  fresh_pod_holds
  stand_in_logged empty
}

k apply -f - <<<"$(statefulset_manifest 1 serve)"
wait_for 180 "the first pod's worker runs" worker_runs
stand_in_logged empty
fresh_pod_holds

# (a) A life ends, a fresh pod answers.
end_a_life 0 "a life's end (exit 0)"
echo "(a) after a life's end the pod has a new uid, remove-link ended 0 in it, its worker has no restart and found its scratch empty"

# (b) A running pod is never touched.
untouched_uid="$uid"
untouched_started="$started"
for _ in $(seq 15); do
  observe
  [ "$uid" = "$untouched_uid" ] && [ "$phase" = Running ] && [ "$restarts" = 0 ] && [ "$started" = "$untouched_started" ] ||
    fail "the running pod changed within 15 seconds: uid '$uid', phase '$phase', restarts '$restarts'"
  sleep 1
done
stand_in_logged
echo "(b) a running pod kept its uid, its phase and its worker's start over 15 seconds"

# (d) A crash gives a fresh pod too.
end_a_life 1 "a crash (exit 1)"
echo "(d) after a crash the pod has a new uid and the same properties as after a life's end"

# (c) The exit loop stays bounded: one pod at a time, no restart, and nothing left on the node.
loop_start_uid="$uid"
k apply -f - <<<"$(statefulset_manifest 1 loop)"
declare -A seen_uids=()
window_seconds=30
loop_started="$(now_milliseconds)"
while [ "$(($(now_milliseconds) - loop_started))" -lt $((window_seconds * 1000)) ]; do
  sample="$(pods_of_the_statefulset)" || fail "the read of the pods failed"
  [ "$(grep -c . <<<"$sample" || true)" -le 1 ] || fail "more than one pod of the StatefulSet existed at once: $(tr '\n' ' ' <<<"$sample")"
  while IFS=, read -r sampled_uid sampled_restarts; do
    [ -n "$sampled_uid" ] || continue
    [ "${sampled_restarts:-0}" = 0 ] || fail "a pod of the exit loop shows restartCount $sampled_restarts"
    [ "$sampled_uid" = "$loop_start_uid" ] || seen_uids[$sampled_uid]=1
  done <<<"$sample"
  sleep 0.5
done
loop_pods="${#seen_uids[@]}"
[ "$loop_pods" -ge 2 ] || fail "the exit loop made $loop_pods pods in $window_seconds seconds, so it is not shown to loop"
echo "(c) the exit loop made $loop_pods pods in $window_seconds seconds ($((loop_pods * 60 / window_seconds)) per minute), never more than one at a time and none with a restart"
k scale "statefulset/$statefulset" --replicas=0
no_pod_left() { [ -z "$(k get pods -o name)" ]; }
wait_for 120 "the removal of the loop's last pod" no_pod_left
node_state_is_as_before() {
  local now
  now="$(node_state)" || exit 1
  [ "$now" = "$node_before" ]
}
wait_for 180 "the node's leases, links, sandboxes and CNI rules as they were" node_state_is_as_before
echo "(c) with the StatefulSet at 0 the node's leases, links, sandboxes and CNI rules equal their state before"

# (e) A lost sandbox: the worker runs again in the same pod, finds its scratch used and ends it; a fresh pod follows.
k apply -f - <<<"$(statefulset_manifest 1 serve)"
wait_for 180 "the pod's worker runs after the loop" worker_runs
stand_in_logged empty
lost_uid="$uid"
sandbox="$(crictl pods --namespace "$namespace" --state ready --label "io.kubernetes.pod.uid=$lost_uid" -q)" ||
  fail "the node's crictl cannot list the pod's sandbox"
[ -n "$sandbox" ] && [ "$(wc -l <<<"$sandbox")" = 1 ] || fail "the pod holds no single sandbox: '$sandbox'"
crictl stopp "$sandbox"
crictl rmp "$sandbox"
# trace: the distinct states the pod passed through, which says what the kubelet did.
trace=
traced_successor_of() {
  local reached=0 line
  is_successor_of "$1" || reached=1
  line="${uid:0:8} $phase init=$init_exit restarts=$restarts"
  [ "$line" = "${last_line:-}" ] || trace+="${trace:+; }$line"
  last_line="$line"
  return "$reached"
}
wait_until 180 traced_successor_of "$lost_uid" || fail "within the time: a pod with a new uid whose worker runs after the removal of the sandbox; the pod showed: $trace"
echo "(e) the pod showed: $trace"
fresh_pod_holds
stand_in_logged used empty
echo "(e) after the removal of its sandbox the worker ran again in the same pod, found its scratch used and ended it, and a pod with a new uid followed"

echo "presentator replacement cell ended after $((SECONDS - started_at)) seconds"
