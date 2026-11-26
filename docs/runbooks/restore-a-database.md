# Runbook: restore a database

Symptom: a namespace's Postgres must return to its latest backup, or a restored copy must prove an upgrade.
Impact: the namespace's writers stop, and its Flux Kustomization stays suspended until the load converges.

## Check

1. After loading `keycloak` with the evidence file of `mise run cutover:preflight --evidence <evidence>` at hand, an
   agent: `mise exec -- tests/keycloak/restored_copy_keeps_its_keys_and_people.sh <dump> <evidence>`. It passes, every
   compared line `equal`. Without that file, or for another namespace, the load's own comparison is the check.
2. After a load, so that the new data is backed up and proven the same hour and not on the next schedule, an agent:
   `mise run backup:now <namespace>`. It takes one Backup from the namespace's Schedule `postgres`, then runs its CronJob `restore-test` as a Job, and prints each object's name and
   outcome; it ends non-zero naming the Backup or the Job that failed. It refuses, creating nothing and saying what to do,
   a namespace without exactly one of those Schedules or without the CronJob. It deletes and prunes nothing;
   the two objects stay for `kubectl describe`.

## Fix

1. An agent: `mise run backup:fetch <namespace> <file>`. It writes the latest dump to a new file at 0600 and refuses a
   file that exists.
2. After the operator's yes to this load, an agent: `mise run db:load-dump --compare <namespace> <file>`. It verifies
   every table against the dump and only then resumes Flux. It refuses a Kustomization that is already suspended, except
   a claim layer's (step 3). Before
   the load it waits up to `DB_LOAD_DUMP_ALONE_SECONDS` seconds, 120 when unset, for other sessions to leave the
   database; when one stays, it loads nothing and refuses, resuming Flux unless the Kustomization was already suspended.
3. For a namespace whose layer declares a claim (songmaker's audio files), step 2 also restores the claim, and the
   bucket where the layer declares one, of the staging snapshot whose MANIFEST holds the dump's sha256: the same
   command, with the dump of step 1. Everything happens inside the cluster, in the Pod `db-load-snapshot`; no file of
   the claim or the bucket passes through this machine. Before any change it refuses a dump of no staging snapshot (a
   `pg_dump` of the live database is one), a node with too little free disk for the load, `--empty-bucket` on a layer
   without a bucket and `--resume`. After the database is verified, the claim is made equal to the snapshot's and
   compared with MANIFEST, the bucket is copied from the snapshot and compared by content, and only then does Flux
   resume; the load then names `mise run backup:now <namespace>`, since every restored object has a new server time. A
   restore puts back each object's key and bytes, not its Content-Type (rclone guesses it from the extension), its user
   metadata or its server time. A bucket that holds objects refuses the load before the database changes; the flag
   `--empty-bucket` deletes them first, after the claim, irreversibly. So before a load with that flag, in this order:
   fetch the dump to load (step 1, which reads only the latest dump), `mise run backup:now <namespace>`, fetch the new
   latest dump to another file as the rollback source, then load. Rolling back is loading that dump with
   `--empty-bucket`; the window lasts until the next Sunday 03:30 prune forgets its snapshot. Do not load at Sunday's
   backup time: a Backup that runs during the load stages a half-loaded claim or bucket into the newest snapshot.
4. After a hard kill of step 2 and the operator's yes to resuming without a verification, an agent:
   `mise run db:load-dump --resume <namespace>`. It verifies nothing. A claim layer's load has no resume: it stays
   suspended with its writers at 0, and the same command, run again, deletes an earlier loader Pod and converges, with
   `--empty-bucket` once the bucket may hold part of the load. When the source itself cannot converge (a bad dump), the
   operator's yes to resuming without it is `kubectl --namespace <namespace> delete pod db-load-snapshot
   db-load-source --ignore-not-found`, then `flux resume kustomization <namespace>` by hand. A loader that is left
   behind ends by itself after its deadline.

Rollback: a load whose `pg_restore` failed or was interrupted resumes Flux itself once the data reads as before, except
a claim layer's load, which stays suspended for its re-run. The bucket is unchanged until the load deletes its objects;
from then on it returns only to a staging snapshot, the one loaded or one taken before the load (step 3). A
verified load whose resume or rollout then failed names that: finish by hand, never load again. A
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
- `mise run backup:now`: It prints only names and outcomes, never a log body.
- `mise run db:load-dump`: It prints names, counts and outcomes, never a row, since a dump holds keys and hashes.
- `tests/keycloak/restored_copy_keeps_its_keys_and_people.sh`: It prints names, counts, key ids and `equal` or
  `DIFFERS`, never a row or a message of `pg_restore` or `psql`.
