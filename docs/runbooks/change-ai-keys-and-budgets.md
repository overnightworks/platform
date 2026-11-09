# Runbook: change AI keys and budgets

Symptom: an app's budget or parallel limit or the person budget changes, an app gets a new key, or an admin needs
the unlimited AI budget.
Impact: what the apps and the people may spend through LiteLLM.

## Check

1. An agent: `mise run litellm:keys --plan`. Exit 0: LiteLLM equals `infrastructure/litellm/keys.yaml`; 2: it lists
   each field with old and new; 1: a failure or a row without a key.
2. An agent: `mise exec -- tests/litellm/key_list_count_equals_key_table_rows.sh litellm`. It ends `equal`.

## Fix

1. Budgets and limits, a pull request: `infrastructure/litellm/keys.yaml` changes, lands and Flux applies it.
2. An agent: `mise run litellm:keys`. Check 1 then exits 0.
3. A new key value for an app: it goes to `platform-secrets` first, in that repository; no command here.
4. An agent: `mise run litellm:key <app>`. It registers the value of the key `litellm_key` of the Secret `<app>` in
   namespace `<app>` as the row's key; a second run prints `<app> unchanged`, and another value under the alias is
   refused, changing nothing.
5. An admin's unlimited budget, the operator: `mise run litellm:admin <username>`. A second run prints
   `<username> unchanged`.

Rollback: a pull request that reverts `keys.yaml`, then step 2.

## Escalate

`litellm:keys` names a row without a key: step 4 for that app. A failed write names what was made and what was not;
when its outcome is unknown or a value is refused, stop and ask the operator.
