#!/usr/bin/env bash
# `mise run backup:now <namespace>`: takes one Backup of the namespace now and runs its restore test on it, so a backup
# is proven the same hour and not on the next schedule. The Backup carries the backend and pod config of the namespace's
# Schedule `backup` (`postgres` where the Postgres component renames it), and the Job is the CronJob restore-test as it
# is. Where the layer has the PreBackupPod `files`, the Backup's pre-sync phase runs first as the Pod backup-seed, with no
# deadline, so that a first copy larger than one pre-sync is staged and the Backup finds it. It creates the seed Pod where
# the layer has the PreBackupPod files, the Backup and the Job, and deletes only that seed Pod and an ended one an earlier
# run left; it prunes nothing, reads no Secret and prints names and outcomes, never a log.
# Usage: scripts/backup_now.sh <namespace>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
namespace="${1:?usage: backup_now.sh <namespace>}"
say() { echo "backup:now: $1"; }
fail() { echo "backup:now: $1" >&2; exit 1; }

# Both are read before the first object is made, so a refusal makes no object. The Schedule is `backup`, or `postgres`
# where the Postgres component renames it; one namespace holds exactly one of the two.
schedules="$(kubectl --namespace "$namespace" get schedules.k8up.io --output json)" ||
  fail "cannot read the Schedules of $namespace; check the namespace's name and that the kubeconfig $KUBECONFIG reaches the cluster, then run it again"
schedules="$(yq --input-format json --output-format json \
  '[.items[] | select(.metadata.name == "backup" or .metadata.name == "postgres")]' <<<"$schedules")"
schedule_count="$(yq --input-format json 'length' <<<"$schedules")"
[ "$schedule_count" = 1 ] ||
  fail "$namespace holds $schedule_count k8up Schedules named backup or postgres, not one; run it in a namespace that includes the backup component, or leave only one of the two"
restore_test="$(kubectl --namespace "$namespace" get cronjob restore-test --ignore-not-found --output name)" ||
  fail "cannot read the CronJob restore-test of $namespace; check that the kubeconfig $KUBECONFIG reaches the cluster, then run it again"
[ -n "$restore_test" ] ||
  fail "$namespace holds no CronJob restore-test; wait until Flux has applied the namespace's backup component, then run it again"

# The seed Pod's backstop in seconds (activeDeadlineSeconds), which ends a seed that stages too slowly. One pass of the
# claim and the bucket together writes at most the room above the kubelet's eviction on the PC's disk after its cleanup,
# 108.55 GB.
seed_backstop_seconds=3600
seed_start_seconds=300
seed_pod=backup-seed
seed_made=0

seed_delete() { kubectl --namespace "$namespace" delete pod "$seed_pod" --ignore-not-found --wait --timeout=2m >/dev/null; }
# Deletes only a seed Pod this run made, whatever ends the run, a signal included.
end_run() { [ "$seed_made" = 0 ] || seed_delete || true; }
trap end_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# settle_earlier_seed: an earlier run's seed Pod that has ended, or never started, is deleted; one that lives refuses.
settle_earlier_seed() {
  local earlier phase age said
  earlier="$(kubectl --namespace "$namespace" get pod "$seed_pod" --ignore-not-found --output json)" ||
    fail "cannot read the Pod $seed_pod of $namespace; check that the kubeconfig $KUBECONFIG reaches the cluster, then run it again; nothing was made"
  [ -n "$earlier" ] || return 0
  phase="$(yq --input-format json '.status.phase' <<<"$earlier")"
  age=$(($(date +%s) - $(date --date "$(yq --input-format json '.metadata.creationTimestamp' <<<"$earlier")" +%s)))
  said="the earlier seed Pod $seed_pod of $namespace had ended; it was deleted"
  if [ "$phase" = Pending ] && [ "$age" -gt "$seed_start_seconds" ]; then
    said="the earlier seed Pod $seed_pod of $namespace never started within 5 minutes; it was deleted"
  elif [ "$phase" != Succeeded ] && [ "$phase" != Failed ]; then
    fail "another run's seed Pod $seed_pod of $namespace is still running; wait for it to end, then run it again; nothing was made"
  fi
  seed_delete || fail "the earlier seed Pod $seed_pod of $namespace did not go within 2 minutes; nothing was made"
  say "$said"
}

# seed_fields: "<phase>|<reason>|<stager state>|<stager exit>|<stager message>|<vendor container ended non-zero>|<its exit>|
# <creation time>".
seed_fields() {
  kubectl --namespace "$namespace" get pod "$seed_pod" --output json | yq --input-format json '
    (.status.containerStatuses // []) as $containers |
    ([$containers[] | select(.name == "stager")] | .[0]) as $stager |
    ([$containers[] | select(.name != "stager" and .state.terminated.exitCode != null and .state.terminated.exitCode != 0)] | .[0]) as $vendor |
    [.status.phase, .status.reason // "", (($stager.state // {}) | keys | .[0]) // "", $stager.state.terminated.exitCode // "",
     $stager.state.terminated.message // "", $vendor.name // "", $vendor.state.terminated.exitCode // "",
     .metadata.creationTimestamp] | join("|")'
}

# judge_seed <fields>: sets seed_outcome to seeded or to the sentence that ends the wait, by the first rule that holds.
seed_outcome=
judge_seed() {
  local phase reason state code message vendor vendor_code created age need free total margin step status
  IFS='|' read -r phase reason state code message vendor vendor_code created <<<"$1"
  age=$(($(date +%s) - $(date --date "$created" +%s)))
  if [ "$reason" = DeadlineExceeded ]; then
    seed_outcome="the seed Pod $seed_pod of $namespace reached its $((seed_backstop_seconds / 3600))-hour backstop before the copies were staged"
  elif [ "$phase" = Failed ] && [ -n "$reason" ]; then
    seed_outcome="the seed Pod $seed_pod of $namespace ended Failed with reason $reason"
  elif [ "$state" = terminated ]; then
    case "$code:$message" in
      0:seeded) seed_outcome=seeded ;;
      3:"refused-room "*)
        read -r _ need free total margin <<<"$message"
        seed_outcome="the seed of $namespace refused: the copies need $need bytes beside the kubelet's eviction margin of $margin, and the staging volume has $free of $total bytes free; free disk space first (mise run disk shows what holds it)" ;;
      4:"refused-held "*)
        seed_outcome="the seed of $namespace refused: ${message#refused-held } other pods mount the staging claim; wait until they end, then run it again" ;;
      1:"failed "*)
        read -r _ step status <<<"$message"
        seed_outcome="the seed of $namespace failed at $step with exit $status"
        [ "$status" != - ] || seed_outcome="the seed of $namespace failed at $step" ;;
      *) seed_outcome="the seed's stager of $namespace ended with exit $code and no outcome backup:now reads" ;;
    esac
  elif [ "$state" = running ] && [ -n "$vendor" ]; then
    seed_outcome="the seed's $vendor container of $namespace ended with exit $vendor_code before its step reported"
  elif [ "$state" != running ] && [ "$state" != terminated ] && [ "$age" -ge "$seed_start_seconds" ]; then
    seed_outcome="the seed Pod $seed_pod of $namespace did not start within 5 minutes"
  elif [ "$age" -ge $((seed_backstop_seconds + 600)) ]; then
    seed_outcome="the seed Pod $seed_pod of $namespace did not end within $((seed_backstop_seconds / 3600)) hours"
  fi
}

# seed: stages the first copy of the layer's claim and bucket in the Pod backup-seed, built from the live PreBackupPod's
# spec without the container postgres and its password, and waits for its outcome.
seed() {
  local pre_backup_pod="$1" manifest fields
  settle_earlier_seed
  # shellcheck disable=SC2016 # $c is yq's variable
  manifest="$(BACKSTOP="$seed_backstop_seconds" yq --input-format json --output-format json '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "'"$seed_pod"'", "labels": {"k8up.io/preBackupPod": "files"}},
     "spec": (.spec.pod.spec | del(.containers[] | select(.name == "postgres")) | del(.volumes[] | select(.name == "password")) |
       .restartPolicy = "Never" | .activeDeadlineSeconds = env(BACKSTOP) | .containers[].env += [{"name": "STAGE_SEED", "value": "1"}])}' <<<"$pre_backup_pod")"
  seed_made=1
  kubectl --namespace "$namespace" create --filename - <<<"$manifest" >/dev/null || {
    seed_made=0
    fail "could not create the seed Pod $seed_pod in $namespace; no Backup was made"
  }
  seed_outcome=
  while [ -z "$seed_outcome" ]; do
    fields="$(seed_fields)" || fail "cannot read the seed Pod $seed_pod of $namespace; no Backup was made"
    judge_seed "$fields"
    [ -n "$seed_outcome" ] || { sleep 5 & wait "$!"; }
  done
  seed_delete || fail "the seed Pod $seed_pod of $namespace did not go within 2 minutes; no Backup was made"
  seed_made=0
  [ "$seed_outcome" = seeded ] || fail "$seed_outcome; no Backup was made"
  say "the seed of $namespace staged its copies"
}

pre_backup_pod="$(kubectl --namespace "$namespace" get prebackuppods.k8up.io files --ignore-not-found --output json)" ||
  fail "cannot read the PreBackupPod files of $namespace; check that the kubeconfig $KUBECONFIG reaches the cluster, then run it again"
[ -z "$pre_backup_pod" ] || seed "$pre_backup_pod"

backup="$(yq --input-format json --output-format json \
  '.[0] | { "apiVersion": "k8up.io/v1", "kind": "Backup", "metadata": { "generateName": "backup-now-" },
     "spec": { "backend": .spec.backend, "podConfigRef": .spec.podConfigRef } }' <<<"$schedules" |
  kubectl --namespace "$namespace" create --filename - --output name)" ||
  fail "could not create the Backup in $namespace; check that the kubeconfig $KUBECONFIG may create Backups there, then run it again"
backup="${backup#*/}"
kubectl --namespace "$namespace" wait "backup/$backup" --timeout=30m \
  --for='jsonpath={.status.conditions[?(@.type=="Completed")].reason}' >/dev/null ||
  fail "the Backup $backup of $namespace did not complete within 30 minutes; the restore test was not run"
reason="$(kubectl --namespace "$namespace" get backup "$backup" \
  --output jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')"
[ "$reason" = Succeeded ] || fail "the Backup $backup of $namespace ended with reason $reason; the restore test was not run"
say "Backup $backup of $namespace Succeeded"

job="restore-test-${backup#backup-}"
kubectl --namespace "$namespace" create job "$job" --from=cronjob/restore-test >/dev/null ||
  fail "could not create the Job $job in $namespace; the Backup $backup Succeeded"
# The Job's activeDeadlineSeconds ends it, as Failed, within the hour.
deadline=$((SECONDS + 3900))
while :; do
  state="$(kubectl --namespace "$namespace" get job "$job" --output jsonpath='{.status.conditions[?(@.status=="True")].type}')"
  case "$state" in
    *Complete*) break ;;
    *Failed*) fail "the restore test Job $job of $namespace Failed; the Backup $backup Succeeded" ;;
  esac
  [ "$SECONDS" -lt "$deadline" ] || fail "the restore test Job $job of $namespace did not end within 65 minutes; the Backup $backup Succeeded"
  sleep 5
done
say "Job $job of $namespace Complete"
