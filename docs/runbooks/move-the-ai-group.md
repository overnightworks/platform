# Runbook: move the AI group

Symptom: the live switch moves the AI group's members from `/services/agent-service/api` to `/services/litellm`.
Impact: who may call the AI gateway. Keycloak's data changes.

## Check

1. Step 1's own lines: the old group's members are a subset of the new group's, and both groups' member counts.

## Fix

1. After the operator's yes, an agent: `mise run keycloak:move-group <file>`. It dumps `keycloak` first, then moves
   and verifies.
2. When the old group is to go, an agent: `mise run keycloak:move-group --delete-old <new file>`.

Rollback: after the operator's yes, an agent: `mise run db:load-dump keycloak <file>`, with step 1's file.

## Escalate

A failed dump, a failed subset check, or member counts the operator did not expect: stop and ask him.

## Ruled

This section holds ruled sentences.

`mise run keycloak:move-group [--delete-old] <file>` is for the rename of the AI group: it creates the new file at 0600
(and refuses one that exists), dumps `keycloak` into it with the messages of `pg_dump` and `pg_restore --list` in
`<file>.dump.log` at 0600, whose path and line count it prints, deletes only its own file after a failed dump, adds
every member of `/services/agent-service/api` to `/services/litellm` through kcadm in Keycloak's container, signed in
as config-cli, verifies the old members are a subset and prints the two groups' member counts; only `--delete-old`
deletes the old group. `db:load-dump keycloak <file>` rolls it back.
