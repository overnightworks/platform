#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=prometheus_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/prometheus_api.sh"
# The cell reads Prometheus' answers and creates nothing; it prints namespaces, names and counts.

# kube-state-metrics shows each Schedule the cluster holds, which names the namespaces BackupMissing judges.
schedules="$(kubectl get schedules.k8up.io --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
[ -n "$schedules" ] || fail "the cluster holds no k8up Schedule"
every_schedule_has_its_series() {
  local schedule
  for schedule in $schedules; do
    [ -n "$(query "k8up_schedule_created{namespace=\"${schedule%/*}\", name=\"${schedule#*/}\"}")" ] || return 1
  done
}
until_true 300 "k8up_schedule_created exists for every Schedule" every_schedule_has_its_series
echo "k8up_schedule_created exists for each of the $(wc -l <<<"$schedules") Schedules: ${schedules//$'\n'/ }"

# The recording rule holds the namespaces of the Backups that completed, and the P7d cells completed one in each.
every_backup_namespace_has_its_series() {
  local namespace
  for namespace in $BACKUP_NAMESPACES; do
    [ -n "$(query "namespace:kube_job_status_completion_time:backup_max{namespace=\"$namespace\"}")" ] || return 1
  done
}
until_true 300 "the backup recording rule has a series for every namespace of '$BACKUP_NAMESPACES'" every_backup_namespace_has_its_series
echo "the backup recording rule has a series for each namespace of: $BACKUP_NAMESPACES"
