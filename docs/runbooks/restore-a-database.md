# Runbook: restore a database

Symptom: a namespace's Postgres must return to its latest backup, or a restored copy must prove an upgrade.
Impact: the namespace's writers stop, and its Flux Kustomization stays suspended until the load converges.

## Check

1. After loading `keycloak` with the evidence file of `mise run cutover:preflight --evidence <evidence>` at hand, an
   agent: `mise exec -- tests/keycloak/restored_copy_keeps_its_keys_and_people.sh <dump> <evidence>`. It passes, every
   compared line `equal`. Without that file, or for another namespace, the load's own comparison is the check.

## Fix

1. An agent: `mise run backup:fetch <namespace> <file>`. It writes the latest dump to a new file at 0600 and refuses a
   file that exists.
2. After the operator's yes to this load, an agent: `mise run db:load-dump --compare <namespace> <file>`. It verifies
   every table against the dump and only then resumes Flux. It refuses a Kustomization that is already suspended.
3. After a hard kill of step 2, an agent: `mise run db:load-dump --resume <namespace>`. It verifies nothing.

Rollback: a load whose `pg_restore` failed or was interrupted resumes Flux itself once the data reads as before. A
load that committed is undone only by loading another dump; no command dumps the current state first, so the dump
that serves is the one fetched before.

## Escalate

The load reports that whether it changed the data is unknown, that the loaded data is not verified, or a table that
`DIFFERS`: it stays suspended with its writers at 0 and names `--resume`. The operator decides before anyone resumes it.

## Ruled

This section holds ruled sentences.

- `mise run backup:fetch`: It prints only names and sizes, since a dump holds keys and hashes.
- `mise run db:load-dump`: It prints names, counts and outcomes, never a row, since a dump holds keys and hashes.
- `tests/keycloak/restored_copy_keeps_its_keys_and_people.sh`: It prints names, counts, key ids and `equal` or
  `DIFFERS`, never a row or a message of `pg_restore` or `psql`.
