# Runbook: change an app's object store key

Symptom: an app's key for its bucket is new, rotated or lost, or an app gets its first bucket.
Impact: the app's pods get 403 from the store until they hold the key that the Job `apply` granted.

## Check

1. An agent: `kubectl -n objectstore logs job/apply`. It ends with one line `bucket <namespace> holds key <id>` per bucket,
   followed by `bucket <namespace> holds backup key <id> read only` where the namespace holds a Secret `object-store-backup`
   and by `bucket <namespace> has no backup key granted` where it does not, and a second run of the Job reports no change.

## Fix

1. A new key value goes to `platform-secrets` first, in that repository, as the key `credentials` of the Secret
   `object-store` in the app's namespace: `[default]`, `aws_access_key_id = GK` and 24 hex digits, `aws_secret_access_key =` 64
   hex digits, both from `openssl rand -hex`. The key ID is new: a held ID takes no other secret, and a deleted ID takes no
   second import. The backup's read-only key is the same file under the key `credentials` of the Secret
   `object-store-backup`, made in a `platform-secrets` worktree by an agent, which never sees it:
   `printf '[default]\naws_access_key_id = GK%s\naws_secret_access_key = %s\n' "$(openssl rand -hex 12)" "$(openssl rand -hex 32)" | mise run secrets:put <namespace> object-store-backup credentials`.
   Its rotation is a new key ID the same way, and its removal is the Secret leaving `platform-secrets`. A backup key that
   equals the app's key fails the Job.
2. An agent: `kubectl -n objectstore delete job apply`, then `flux reconcile kustomization objectstore`. Flux recreates the
   Job, which imports the new keys, grants the app's read and write on the bucket and the backup's read alone, and revokes
   every other key's rights on it, a removed Secret's key included. Rights granted by hand through the admin API are revoked
   too, by design. The Job does not rerun by itself: when its change landed before the Secret `object-store-backup` reached the
   cluster, or when that Secret left, this step runs once the Secret exists or is gone. Where the app's layer includes
   `infrastructure/postgres/backup/files/bucket`, the backup's pod reads the Secret `object-store-backup` at every Backup,
   so a rotated backup key is imported by this Job before the next Backup, or that Backup fails with its step
   `bucket-pre-sync` named.
3. An agent: `kubectl -n <namespace> rollout restart deployment <web>`. The pods that kept the old key get 403 until they
   restart, since the key file is read at start.
4. A first bucket for a namespace, a pull request: its name in `infrastructure/objectstore/namespaces.txt`, the
   namespace's pods, and its PreBackupPod's pods where the layer includes `files/bucket`, in the NetworkPolicy `garage`
   of `infrastructure/objectstore/garage.yaml`, and the Secret in `platform-secrets`. The change of the list recreates the Job.

Rollback: the old value back in `platform-secrets`, then steps 2 and 3. The key that was revoked is granted again, and
the new one loses its rights. The Job's change reverted, the next run denies the backup key's read, since the old script
denies every key but the app's; the Secret `object-store-backup` can stay.

## Escalate

The Job fails: its log names the namespace and the step and never a secret. `Garage holds key <id> with another
secret` means step 1 reused an ID, so make a new one. `the backup key equals the app key` means the Secret
`object-store-backup` holds the app's key, and a line that names the key `credentials` of that Secret means the key is
missing, empty or malformed: make it by step 1's pipe. A refused import of a new ID, or a status the log names, goes to
the head with that line.
