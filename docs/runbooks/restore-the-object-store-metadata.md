# Runbook: restore the object store's metadata

Symptom: the pod `garage-0` in Namespace `objectstore` crash-loops after a power loss or a kill, with an error from its
metadata database, or the store answers that every object is missing.
Impact: every app with a bucket (presentator) cannot read or write its objects until Garage is back.

## Check

1. An agent: `kubectl -n objectstore logs garage-0 --previous`. A line that names `db.sqlite` as unreadable or corrupt
   confirms it; another error is not this runbook's.
2. An agent: `kubectl -n objectstore get pvc data-garage-0`. It is `Bound`: the claim holds the data blocks and the
   snapshots, and a lost claim is not a metadata loss (the objects are gone, and each app rebuilds what it keeps there).

## Fix

1. The operator's yes, since the store stops: an agent suspends the layer, `flux suspend kustomization objectstore`, then
   scales the pod away, `kubectl -n objectstore scale statefulset garage --replicas 0`.
2. An agent starts a Pod in `objectstore` that mounts the claim `data-garage-0` at `/data`, runs as user and group 1000
   with the busybox image of `PROBE_IMAGE` in `.github/workflows/ci.yml`, and meets Pod Security `restricted`
   (`automountServiceAccountToken: false`, no privilege escalation, every capability dropped, a seccomp profile of
   `RuntimeDefault`), with `sleep 3600` as its command.
3. In that Pod, an agent lists `/data/meta/snapshots`: one entry per snapshot, named by the UTC time it was taken,
   `metadata_auto_snapshot_interval` (6 hours) apart, the newest two kept. It moves `/data/meta/db.sqlite` aside as
   `/data/meta/db.sqlite.corrupt` and copies the newest snapshot to `/data/meta/db.sqlite`, then deletes the Pod.
4. An agent resumes and scales up: `kubectl -n objectstore scale statefulset garage --replicas 1`, `flux resume
   kustomization objectstore`, and waits for `garage-0` to be Ready.
5. An agent: `kubectl -n objectstore exec garage-0 -- /garage repair -a --yes tables`. It makes the tables consistent
   with the restored database.

Objects written after the snapshot lose their metadata: they are unreachable, and their blocks stay on the claim until
Garage's own sweep. presentator rebuilds what its bucket holds; a later app that keeps a file only in a bucket restores
it from that bucket's backup, which the platform does not make yet.

Rollback: the corrupt file stays at `/data/meta/db.sqlite.corrupt` until the operator deletes it; copying it back
returns to the state before step 3.

## Escalate

No snapshot is older than the corruption, `/data/meta/snapshots` is empty, or Garage still fails after step 5: stop and
give the pod's log to the head. A store that is rebuilt from nothing deletes `data-garage-0`, which is the operator's
call, and every app then fills its bucket anew.
