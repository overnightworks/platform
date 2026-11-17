# Runbook: change an app's object store key

Symptom: an app's key for its bucket is new, rotated or lost, or an app gets its first bucket.
Impact: the app's pods get 403 from the store until they hold the key that the Job `apply` granted.

## Check

1. An agent: `kubectl -n objectstore logs job/apply`. It ends with one line `bucket <namespace> holds key <id>` per bucket,
   and a second run of the Job reports no change.

## Fix

1. A new key value goes to `platform-secrets` first, in that repository, as the key `credentials` of the Secret
   `object-store` in the app's namespace: `[default]`, `aws_access_key_id = GK` and 24 hex digits, `aws_secret_access_key =` 64
   hex digits, both from `openssl rand -hex`. The key ID is new: a held ID takes no other secret, and a deleted ID takes no
   second import.
2. An agent: `kubectl -n objectstore delete job apply`, then `flux reconcile kustomization objectstore`. Flux recreates the
   Job, which imports the new key, grants it read and write on the bucket and revokes every other key's rights on it.
   Rights granted by hand through the admin API are revoked too, by design.
3. An agent: `kubectl -n <namespace> rollout restart deployment <web>`. The pods that kept the old key get 403 until they
   restart, since the key file is read at start.
4. A first bucket for a namespace, a pull request: its name in `infrastructure/objectstore/namespaces`, a Role and
   binding for the Job `apply` beside the existing ones in `infrastructure/objectstore/apply.yaml`, the namespace's pods
   in the NetworkPolicy `garage` of `infrastructure/objectstore/garage.yaml`, and the Secret in `platform-secrets`.
   The change of the list recreates the Job.

Rollback: the old value back in `platform-secrets`, then steps 2 and 3. The key that was revoked is granted again, and
the new one loses its rights.

## Escalate

The Job fails: its log names the namespace and the step and never a secret. `Garage holds key <id> with another
secret` means step 1 reused an ID, so make a new one. A refused import of a new ID, or a status the log names, goes to
the head with that line.
