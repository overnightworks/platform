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
3. For a namespace whose layer declares a claim (songmaker's audio files), step 2 takes `--files <dir>`:
   `mise run db:load-dump --compare --files <dir> <namespace> <file>`. A claim layer refuses a load without it and a
   layer without a claim refuses it, before any change. `<dir>` holds only regular files and directories, at least one
   file, every entry readable and no name with a newline; it is only read. After the database is verified, rsync
   makes the claim equal to `<dir>`, deleting what it lacks, and a `--checksum --dry-run` must list no difference, only then does Flux
   resume; a Kustomization that is already suspended does not stop it. rsync's messages go to `<file>.load.log`. Do not load at Sunday's backup time: a backup that runs during the
   load reads the claim half replaced.
4. After a hard kill of step 2 and the operator's yes to resuming without a verification, an agent:
   `mise run db:load-dump --resume <namespace>`. It verifies nothing. A load with `--files` has no resume: it stays
   suspended with its writers at 0 and the same command, run again, converges. When the source itself cannot converge (a
   bad dump), the operator's yes to resuming without it is `flux resume kustomization <namespace>` by hand.

Rollback: a load whose `pg_restore` failed or was interrupted resumes Flux itself once the data reads as before, except
a load with `--files`, which stays suspended for its re-run. A
load that committed is undone only by loading another dump; no command dumps the current state first, so the dump
that serves is a dump fetched before the load, other than the one loaded.

## Escalate

The load reports that whether it changed the data is unknown, that the loaded data is not verified, or a table that
`DIFFERS`: it stays suspended with its writers at 0 and names `--resume`. The operator decides before anyone resumes it.
The runner reads only what the command prints, never the dump or `<file>.load.log`, since a COPY error there quotes a
row.

## Ruled

This section holds ruled sentences.

- `mise run backup:fetch`: It prints only names and sizes, since a dump holds keys and hashes.
- `mise run db:load-dump`: It prints names, counts and outcomes, never a row, since a dump holds keys and hashes.
- `tests/keycloak/restored_copy_keeps_its_keys_and_people.sh`: It prints names, counts, key ids and `equal` or
  `DIFFERS`, never a row or a message of `pg_restore` or `psql`.
