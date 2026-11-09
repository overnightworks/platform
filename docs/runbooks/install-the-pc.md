# Runbook: install the PC

Symptom: the PC has no k3s, k3s was uninstalled, or `mise.toml` declares a host part the PC lacks.
Impact: the platform does not run on the PC before step 6. hal runs beside it throughout.

## Check

1. An agent: `scripts/bootstrap_pc.sh --only tools`.
2. The operator: `scripts/bootstrap_pc.sh plan --detailed-exitcode`. It lists only the entry state's changes,
   which `/usr/local/bin/k3s` decides, and the pod-log parts and the timer until they are applied:
   - absent, no `mise:` ufw rule, no `/var/lib/mise/bootstrap/firewall.json`: a first install; the plan lists
     `/etc/rancher/k3s`, its config file, the firewall and the rule;
   - absent, that rule and state file kept, `/etc/rancher` holding at most `node/password`: the uninstalled state;
     the plan lists only `/etc/rancher/k3s` and its config file;
   - present, with `k3s-uninstall.sh` beside it: an existing install, which goes on at step 9.

- Before step 10, an agent: `loginctl show-user "$USER" --property=Linger`. It must print `Linger=yes`.

## Fix

3. The operator: `scripts/bootstrap_pc.sh --only files,firewall,services`.
4. The operator: `mise run bootstrap:k3s`.
5. An agent: `mise run bootstrap:flux`.
6. The operator: `mise run bootstrap:secrets`.
7. The operator: `sudo systemctl start pod-logs-clean.service`, once, as the timer first runs at midnight.
8. The operator: `mise run check:pod-logs`. It passes.
9. A new pod-log part or inotify limit, the operator: `scripts/bootstrap_pc.sh --only files,services`. For the pod-log
   parts, steps 4, 7 and 8 follow.
10. New disk units, which run in the operator's user manager, which lingers; after step 1, an agent:
    `scripts/bootstrap_pc.sh --only dotfiles,linux-systemd-units`.

Rollback: [remove a host part](remove-a-host-part.md), or [uninstall k3s](uninstall-k3s.md).

## Escalate

Any other entry state, `/etc/rancher/k3s` without `/usr/local/bin/k3s` included, or a plan that lists more: stop and
ask the operator. A `Linger=no` answer too: without lingering, Docuum and the clean timers stop when he logs out. A
missing age key file comes back only from his password manager.

## Ruled

This section holds ruled sentences.

- The age key file sops reads: The PC's key lives in that file, and its one copy in the operator's password manager.
- `mise run bootstrap:k3s` installs k3s at `K3S_VERSION` on the PC from k3s's `install.sh` at that tag, only after its
  pinned sha256 matched, with k3s's own containerd and no `kubectl`, `crictl` or `ctr` link.
- `mise run bootstrap:secrets`: It then requests a reconcile of the source `platform-secrets`, and only when that is
  not Ready within a minute prints the public key to add once, read-only, in GitHub's web form, requesting a
  reconcile every 30 seconds for up to 15 minutes; then it waits for the Kustomization.
- The inotify limits: It needs sudo, so it is the operator's.
