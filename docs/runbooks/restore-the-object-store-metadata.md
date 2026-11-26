# Runbook: restore the object store's metadata

Symptom: the pod `garage-0` in Namespace `objectstore` crash-loops after a power loss or a kill, with an error from its
metadata database, or the store answers that every object is missing.
Impact: every app with a bucket (presentator and songmaker) cannot read or write its objects until Garage is back.

## Check

1. An agent: `kubectl -n objectstore logs garage-0 --previous`. A line that names `db.sqlite` as unreadable or corrupt
   confirms it; another error is not this runbook's.
2. An agent: `kubectl -n objectstore get pvc data-garage-0`. It is `Bound`: the claim holds the data blocks and the
   snapshots, and a lost claim is not a metadata loss (the objects are gone, and each app rebuilds what it keeps there).

## Fix

1. The operator's yes, since the store stops: an agent suspends the apps' layers and the store's, `flux suspend
   kustomization presentator`, `flux suspend kustomization songmaker` and `flux suspend kustomization objectstore`,
   scales the apps' web pods away, `kubectl -n presentator scale deployment web --replicas 0` and
   `kubectl -n songmaker scale deployment web --replicas 0`, which keeps S3 access closed until step 6 has reconciled
   the restored store, then scales the store away, `kubectl -n objectstore scale statefulset garage --replicas 0`, and
   deletes the Job, `kubectl -n objectstore delete job apply`.
2. An agent starts a Pod in `objectstore` that mounts the claim `data-garage-0` at `/data`, runs as user and group 1000
   with the busybox image of `PROBE_IMAGE` in `.github/workflows/ci.yml`, and meets Pod Security `restricted`
   (`automountServiceAccountToken: false`, no privilege escalation, every capability dropped, a seccomp profile of
   `RuntimeDefault`), with `sleep 3600` as its command.
3. In that Pod, an agent lists `/data/meta/snapshots`: one entry per snapshot, named by the UTC time it was taken,
   `metadata_auto_snapshot_interval` (6 hours) apart, the newest two kept. It moves `/data/meta/db.sqlite` aside as
   `/data/meta/db.sqlite.corrupt` and copies the newest snapshot to `/data/meta/db.sqlite`, then deletes the Pod.
4. An agent scales up, `kubectl -n objectstore scale statefulset garage --replicas 1`, and waits for `garage-0` to be Ready.
5. An agent: `kubectl -n objectstore exec garage-0 -- /garage repair -a --yes tables`. It makes the tables consistent
   with the restored database.
6. The snapshot holds the keys and grants of its time, so after a key rotation it still authorizes the revoked key and
   lacks the current one. An agent resumes the store's layer, `flux resume kustomization objectstore`, which recreates
   the Job `apply`: it imports the current key from each namespace's Secret `object-store`, and the backup's key from its
   Secret `object-store-backup` where one exists, and revokes every other key's rights, and the layer is Ready only when the
   Job has completed. Only then an agent resumes the apps, `flux resume kustomization presentator` and `flux resume
   kustomization songmaker`, which starts the web again, and checks that `kubectl -n objectstore logs job/apply` ends with
   one line `bucket <namespace> holds key <id>` per bucket, each followed by `holds backup key <id> read only` or `has no
   backup key granted`.

Objects written after the snapshot lose their metadata: they are unreachable, and their blocks stay on the claim until
Garage's own sweep. presentator rebuilds what its bucket holds, and songmaker's bucket holds only what it can rebuild
(its queue's stream snapshots); an app that keeps a file only in a declared bucket gets the objects written after the
snapshot back from that bucket's backup with `mise run db:load-dump` (restore-a-database.md).

Rollback: the corrupt file stays at `/data/meta/db.sqlite.corrupt` until the operator deletes it; copying it back
returns to the state before step 3.

## Escalate

No snapshot is older than the corruption, `/data/meta/snapshots` is empty, Garage still fails after step 5, or the Job
`apply` fails in step 6: stop and give the pod's log to the head. A store that is rebuilt from nothing deletes `data-garage-0`, which is the operator's
call, and every app then fills its bucket anew.
