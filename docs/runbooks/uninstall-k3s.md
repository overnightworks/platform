# Runbook: uninstall k3s

Symptom: k3s must leave the PC, for a clean reinstall or for good.
Impact: every Pod stops, and `k3s-uninstall.sh` deletes the volume objects: the data comes back only through
restic.

## Fix

Every pull request step is an agent's. It lands before the next step, and the next step runs from a checkout at
the landed main.

1. The operator, after his word: `sudo /usr/local/bin/k3s-uninstall.sh`. A reinstall stops here and goes on with
   [install the PC](install-the-pc.md) from the uninstalled state.
2. For good only, an agent, pull request: the firewall section of `mise.toml` gets `state = "absent"`.
3. For good only, the operator: `scripts/bootstrap_pc.sh --only firewall`. It deletes mise's rule and its state file
   and keeps the operator's own; deleting the section or reverting the commit changes nothing on the host.

What stays: `/etc/rancher/node/password`, k3s's node password; the empty `/var/lib/rancher`; `/var/log/pods` and
`/var/log/containers`; the kernel settings k3s made and the empty `*mangle` tables in the IPv4 and IPv6 rules, until a
reboot. A finished uninstall leaves the rules equal to those before the install apart from those two tables.

Rollback: [install the PC](install-the-pc.md) from the uninstalled state. After steps 2 and 3, an agent reverts their
pull request first, as the plan then lists no firewall rule.

## Ruled

This section holds ruled sentences.

Every `k3s-uninstall.sh` waits for the operator's word; `k3s-killall.sh`, which deletes nothing, may stop k3s before it.
