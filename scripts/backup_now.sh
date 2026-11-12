#!/usr/bin/env bash
# `mise run backup:now <namespace>`: takes one Backup of the namespace now and runs its restore test on it, so a backup
# is proven the same hour and not on the next schedule. The Backup carries the backend and pod config of the namespace's
# one k8up Schedule, and the Job is the CronJob restore-test as it is. It creates two objects, deletes and prunes
# nothing, reads no Secret and prints names and outcomes, never a log.
# Usage: scripts/backup_now.sh <namespace>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
namespace="${1:?usage: backup_now.sh <namespace>}"
say() { echo "backup:now: $1"; }
fail() { echo "backup:now: $1" >&2; exit 1; }

# Both are read before the first object is made, so a refusal changes nothing.
schedules="$(kubectl --namespace "$namespace" get schedules.k8up.io --output json)" ||
  fail "cannot read the Schedules of $namespace; nothing changed"
schedule_count="$(yq --input-format json '.items | length' <<<"$schedules")"
[ "$schedule_count" = 1 ] || fail "$namespace holds $schedule_count k8up Schedules, not one; nothing changed"
restore_test="$(kubectl --namespace "$namespace" get cronjob restore-test --ignore-not-found --output name)" ||
  fail "cannot read the CronJob restore-test of $namespace; nothing changed"
[ -n "$restore_test" ] || fail "$namespace holds no CronJob restore-test; nothing changed"

backup="$(yq --input-format json --output-format json \
  '.items[0] | { "apiVersion": "k8up.io/v1", "kind": "Backup", "metadata": { "generateName": "backup-now-" },
     "spec": { "backend": .spec.backend, "podConfigRef": .spec.podConfigRef } }' <<<"$schedules" |
  kubectl --namespace "$namespace" create --filename - --output name)" ||
  fail "could not create the Backup in $namespace; nothing changed"
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
