# Runbook: change AI keys and budgets

Symptom: an app's budget or parallel limit or the person budget changes, an app gets a new key or a new key value, or
an admin needs the unlimited AI budget.
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
   A rotated value (step 3) takes the alias with `mise run litellm:key <app> --replace`: it deletes the old key and
   registers the Secret's value, then prints `<app> replaced`. The old value stops working at once and the app's spend
   of the period starts anew, since LiteLLM binds spend to the key. A failure between the delete and the registration
   names the alias as holding no key; the same command completes it.
5. An admin's unlimited budget, the operator: `mise run litellm:admin <username>`. A second run prints
   `<username> unchanged`.

Rollback: a pull request that reverts `keys.yaml`, then step 2; a replaced key is restored by putting the old value
back in `platform-secrets` and running step 4 with `--replace`.

## Escalate

`litellm:keys` names a row without a key: step 4 for that app. A failed write names what was made and what was not;
when its outcome is unknown, a value is refused or Check 2 prints `DIFFERS`, stop and ask the operator.
