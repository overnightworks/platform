#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
namespace="$LITELLM_NAMESPACE"
marker=expire-cell
backdated=100
fresh=10
kubectl --namespace "$namespace" rollout status statefulset/postgres --timeout=5m
sql() { kubectl --namespace "$namespace" exec --stdin postgres-0 -- psql --no-psqlrc --set ON_ERROR_STOP=1 --tuples-only --no-align; }
# LiteLLM creates its tables when it starts; the cell needs them before it plants a row.
for _ in $(seq 60); do
  [ "$(sql <<<"SELECT to_regclass('\"LiteLLM_EndUserTable\"') IS NOT NULL AND to_regclass('\"LiteLLM_ToolTable\"') IS NOT NULL")" = t ] && break
  sleep 2
done
# The real CronJob fires at 04:00 UTC and would delete the planted rows before the cell's own Job; the cell holds it
# for its run. The hold is set under its own field manager: kustomize-controller reassigns the fields of every manager
# whose name starts with "kubectl" (kubectl-patch included) to itself and then removes them, as its manifest sets no
# suspend, while it leaves the fields of any other manager alone.
hold_manager=expire-cell
cronjob=litellm-expire
prior_suspend=
holding=false
set_suspend() {
  kubectl --namespace "$namespace" patch cronjob "$cronjob" --type merge --field-manager "$hold_manager" \
    --patch "{\"spec\":{\"suspend\":$1}}"
}
cleanup() {
  local cell_status=$?
  kubectl --namespace "$namespace" delete job --selector "$marker=job" --wait=false || true
  sql <<EOSQL || true
DELETE FROM "LiteLLM_DailyEndUserSpend" WHERE end_user_id LIKE '$marker-%';
DELETE FROM "LiteLLM_DailyToolSpend" WHERE tool_name LIKE '$marker-%';
DELETE FROM "LiteLLM_DailyTagSpend" WHERE tag LIKE '$marker-%';
DELETE FROM "LiteLLM_ToolTable" WHERE tool_name LIKE '$marker-%';
DELETE FROM "LiteLLM_EndUserTable" WHERE user_id LIKE '$marker-%';
DELETE FROM "LiteLLM_BudgetTable" WHERE budget_id LIKE '$marker-%';
EOSQL
  # A CronJob left suspended would hide the next cell's failure, so a failed restore fails the cell.
  if $holding && ! set_suspend "${prior_suspend:-false}"; then
    echo "::error::the CronJob $cronjob could not be restored to suspend=${prior_suspend:-false}"
    deletion_failures=$((deletion_failures + 1))
  fi
  end_deletions "$cell_status"
}
trap cleanup EXIT

prior_suspend="$(kubectl --namespace "$namespace" get cronjob "$cronjob" -o jsonpath='{.spec.suspend}')"
holding=true
set_suspend true
echo "the CronJob $cronjob is held (suspend was '${prior_suspend:-unset}'); the managers of spec.suspend now:"
kubectl --namespace "$namespace" get cronjob "$cronjob" -o json --show-managed-fields |
  jq -r '.metadata.managedFields[] | select(.fieldsV1."f:spec"."f:suspend") | "\(.manager) \(.operation)"'
cronjob_has_no_active_job() {
  local active
  active="$(kubectl --namespace "$namespace" get cronjob "$cronjob" -o jsonpath='{.status.active[*].name}')" ||
    fail "the CronJob $cronjob could not be read"
  [ -z "$active" ]
}
until_true 300 "the CronJob $cronjob has no active Job" cronjob_has_no_active_job
# Days relative to the database's own UTC day. One backdated and one fresh row per table; the customers are the
# backdated one (idle), the fresh one (a daily row inside the period), one linked to its own budget and one with
# spend, both idle.
sql <<EOSQL
INSERT INTO "LiteLLM_BudgetTable" (budget_id, created_by, updated_by) VALUES ('$marker-budget', '$marker', '$marker');
INSERT INTO "LiteLLM_EndUserTable" (user_id, budget_id, spend) VALUES
  ('$marker-backdated', NULL, 0), ('$marker-fresh', NULL, 0),
  ('$marker-budgeted', '$marker-budget', 0), ('$marker-spent', NULL, 5);
INSERT INTO "LiteLLM_DailyEndUserSpend" (id, end_user_id, date, api_key, updated_at) VALUES
  ('$marker-backdated', '$marker-backdated', to_char(now() AT TIME ZONE 'UTC' - interval '$backdated days', 'YYYY-MM-DD'), '$marker', now()),
  ('$marker-fresh', '$marker-fresh', to_char(now() AT TIME ZONE 'UTC' - interval '$fresh days', 'YYYY-MM-DD'), '$marker', now());
INSERT INTO "LiteLLM_DailyToolSpend" (date, tool_name, updated_at) VALUES
  (to_char(now() AT TIME ZONE 'UTC' - interval '$backdated days', 'YYYY-MM-DD'), '$marker-backdated', now()),
  (to_char(now() AT TIME ZONE 'UTC' - interval '$fresh days', 'YYYY-MM-DD'), '$marker-fresh', now());
INSERT INTO "LiteLLM_DailyTagSpend" (id, tag, date, api_key, updated_at) VALUES
  ('$marker-backdated', '$marker-backdated', to_char(now() AT TIME ZONE 'UTC' - interval '$backdated days', 'YYYY-MM-DD'), '$marker', now()),
  ('$marker-fresh', '$marker-fresh', to_char(now() AT TIME ZONE 'UTC' - interval '$fresh days', 'YYYY-MM-DD'), '$marker', now());
INSERT INTO "LiteLLM_ToolTable" (tool_id, tool_name, last_used_at, created_at, updated_at) VALUES
  ('$marker-backdated', '$marker-backdated', NULL, now() AT TIME ZONE 'UTC' - interval '$backdated days', now()),
  ('$marker-fresh', '$marker-fresh', now() AT TIME ZONE 'UTC' - interval '$fresh days', now() AT TIME ZONE 'UTC' - interval '$backdated days', now());
EOSQL

# remaining: what of the planted rows is left, one line per table and name.
remaining() {
  sql <<EOSQL
SELECT 'person_days ' || end_user_id FROM "LiteLLM_DailyEndUserSpend" WHERE end_user_id LIKE '$marker-%'
UNION ALL SELECT 'tool_days ' || tool_name FROM "LiteLLM_DailyToolSpend" WHERE tool_name LIKE '$marker-%'
UNION ALL SELECT 'tag_days ' || tag FROM "LiteLLM_DailyTagSpend" WHERE tag LIKE '$marker-%'
UNION ALL SELECT 'tools ' || tool_name FROM "LiteLLM_ToolTable" WHERE tool_name LIKE '$marker-%'
UNION ALL SELECT 'people ' || user_id FROM "LiteLLM_EndUserTable" WHERE user_id LIKE '$marker-%'
ORDER BY 1
EOSQL
}
count_line='^(person_days|tool_days|tag_days|tools|people)\|'
# Every planted identifying string (names, ids, key, creator) starts with the marker; the Job's log may hold none.
assert_log_holds_no_planted_value() {
  if grep -qF "$marker" <<<"$1"; then
    fail "the Job's log holds a value the cell planted"
  fi
}
# run_expire <job name>: a Job made from the CronJob; sets log to the statement's counts and failed_tries to the rest.
run_expire() {
  kubectl --namespace "$namespace" create job "$1" --from=cronjob/litellm-expire
  kubectl --namespace "$namespace" label job "$1" "$marker=job"
  kubectl --namespace "$namespace" wait "job/$1" --for=condition=complete --timeout=3m || {
    kubectl --namespace "$namespace" describe "job/$1"
    kubectl --namespace "$namespace" get pods --selector "job-name=$1" \
      -o jsonpath='{range .items[*].status.containerStatuses[*]}{.state.terminated.exitCode} {.state.terminated.reason}{"\n"}{end}' || true
    # A failed Pod's log holds psql's connection error, which quotes no row.
    for pod in $(kubectl --namespace "$namespace" get pods --selector "job-name=$1" --output name); do
      echo "log of $pod:"
      kubectl --namespace "$namespace" logs "$pod" || true
    done
    # The shipped Job discards psql's stderr because an error can quote a row; here the statement runs once more
    # against the cell's own dummy rows so the cause is printed.
    echo "the statement run again in the Postgres container:"
    sql <"$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/litellm/expire.sql" 2>&1 || true
    fail "the Job $1 did not complete"
  }
  # A retried Job leaves failed Pods beside the one that completed.
  full_log="$(kubectl --namespace "$namespace" logs "$(kubectl --namespace "$namespace" get pods --selector "job-name=$1" \
    --field-selector status.phase=Succeeded --output name)")"
  assert_log_holds_no_planted_value "$full_log"
  # The lines that are no count are psql's failed connection tries.
  log="$(grep -E "$count_line" <<<"$full_log" || true)"
  failed_tries="$(grep -vE "$count_line" <<<"$full_log" || true)"
}
counts() { printf 'person_days|%s\ntool_days|%s\ntag_days|%s\ntools|%s\npeople|%s' "$@"; }

run_expire "$marker-first"
[ "$log" = "$(counts 1 1 1 1 1)" ] || fail "the first run printed [${log//$'\n'/ }], not one deletion in each of the five counts"
echo "the first run deleted one row of each table: ${log//$'\n'/ }"
# A fresh Pod can be refused before its address is admitted; the count is evidence, never asserted.
echo "the first Job's log shows $(grep -c . <<<"$failed_tries" || true) lines of failed connection tries; their kinds:"
sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<ip>/g' <<<"$failed_tries" | grep . | sort | uniq -c || true
expected="$(printf '%s\n' "person_days $marker-fresh" "tool_days $marker-fresh" "tag_days $marker-fresh" "tools $marker-fresh" \
  "people $marker-budgeted" "people $marker-fresh" "people $marker-spent" | LC_ALL=C sort)"
[ "$(remaining | LC_ALL=C sort)" = "$expected" ] ||
  fail "the planted rows left are [$(remaining | tr '\n' ',')], not the fresh row of each table and the three customers it keeps"
echo "the fresh rows and the idle customers with a budget or spend stayed"

run_expire "$marker-second"
[ "$log" = "$(counts 0 0 0 0 0)" ] || fail "the second run printed [${log//$'\n'/ }], not five zero counts"
echo "the second run deleted nothing"

# The Pod ran in a namespace that enforces restricted, so the Pod Security admission and the image policy passed it.
level="$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
[ "$level" = restricted ] || fail "namespace $namespace enforces '$level', not restricted"
job_image="$(kubectl --namespace "$namespace" get cronjob litellm-expire \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')"
postgres_image="$(kubectl --namespace "$namespace" get statefulset postgres -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$job_image" = "$postgres_image" ] || fail "the expiry runs $job_image, not its Postgres's $postgres_image"
echo "the expiry's Pod passed restricted and the image policy with its Postgres's image"
