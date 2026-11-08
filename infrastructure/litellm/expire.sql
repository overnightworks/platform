-- One statement, one snapshot: the five data-modifying CTEs delete all of it or nothing and write no other table.
-- The customer condition reads the daily rows at or after the cutoff, which this statement does not delete. A customer
-- row linked to its own budget, or with spend not yet reset, stays. LiteLLM writes days as UTC days in text, and the
-- period is the privacy text's, so it is no setting.
WITH cutoff AS (
  SELECT (now() AT TIME ZONE 'UTC') - interval '90 days' AS moment,
    to_char((now() AT TIME ZONE 'UTC') - interval '90 days', 'YYYY-MM-DD') AS day
), person_days AS (
  DELETE FROM "LiteLLM_DailyEndUserSpend" WHERE date < (SELECT day FROM cutoff) RETURNING 1
), tool_days AS (
  DELETE FROM "LiteLLM_DailyToolSpend" WHERE date < (SELECT day FROM cutoff) RETURNING 1
), tag_days AS (
  DELETE FROM "LiteLLM_DailyTagSpend" WHERE date < (SELECT day FROM cutoff) RETURNING 1
), tools AS (
  DELETE FROM "LiteLLM_ToolTable" WHERE coalesce(last_used_at, created_at) < (SELECT moment FROM cutoff) RETURNING 1
), people AS (
  DELETE FROM "LiteLLM_EndUserTable" AS person
  WHERE person.budget_id IS NULL AND person.spend = 0 AND NOT EXISTS (
    SELECT 1 FROM "LiteLLM_DailyEndUserSpend" AS kept
    WHERE kept.end_user_id = person.user_id AND kept.date >= (SELECT day FROM cutoff)
  ) RETURNING 1
)
SELECT (SELECT count(*) FROM person_days) AS person_days, (SELECT count(*) FROM tool_days) AS tool_days,
  (SELECT count(*) FROM tag_days) AS tag_days, (SELECT count(*) FROM tools) AS tools,
  (SELECT count(*) FROM people) AS people;
