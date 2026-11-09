# Runbook: uninstall k3s

Symptom: k3s must leave the PC, for a clean reinstall or for good.
Impact: every Pod stops, and `k3s-uninstall.sh` deletes the volume objects: the data comes back only through
restic.

## Check

1. An agent: the inventory of PersistentVolumes, claims and Secrets against the first install's.
   No shipped command takes it.

## Fix

Every pull request step is an agent's. It lands before the next step, and the next step runs from a checkout at the landed main.

1. An inventory that differs or cannot be read, the operator: `sudo /usr/local/bin/k3s-killall.sh`. Then Escalate.
2. The operator: `sudo /usr/local/bin/k3s-uninstall.sh`. A reinstall stops here and goes on with
   [install the PC](install-the-pc.md) from the uninstalled state.
3. For good only, an agent, pull request: the firewall section of `mise.toml` gets `state = "absent"`.
4. For good only, the operator: `scripts/bootstrap_pc.sh --only firewall`. It deletes mise's rule and its state file and keeps the
   operator's own; deleting the section or reverting the commit changes nothing on the host.

What stays: `/etc/rancher/node/password`, k3s's node password; the empty `/var/lib/rancher`; `/var/log/pods` and
`/var/log/containers`; the kernel settings k3s made and the empty `*mangle` tables in the IPv4 and IPv6 rules, until a
reboot. A finished uninstall leaves the rules equal to those before the install apart from those two tables.

Rollback: [install the PC](install-the-pc.md) from the uninstalled state.

## Escalate

An inventory that differs or cannot be read: k3s stays stopped until the operator's word.

## Ruled

This section holds ruled sentences.

The uninstall runs without the operator's word only while the cluster holds no PersistentVolume, no claim and no
Secret beyond its first install's; an inventory that differs or cannot be read stops k3s with `k3s-killall.sh`, which
deletes nothing, and the uninstall waits for his word.
