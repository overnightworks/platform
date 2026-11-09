# Runbook: remove a host part

Symptom: the pod-log parts, the inotify limits or the disk units leave the PC.
Impact: without the pod-log parts nothing deletes pod logs after the 30 days the apps' privacy texts promise.
Deleted logs stay deleted.

## Check

1. The operator: `scripts/bootstrap_pc.sh plan --detailed-exitcode`. Before each apply it lists only the change
   of the step's pull request.

## Fix

Every pull request step is an agent's. It lands before the next step, and the next step runs from a checkout at the landed main.

The pod-log parts:

1. An agent, pull request: `pod-logs-clean.timer` gets `state = "stopped"` and `enabled = false`.
2. The operator: `scripts/bootstrap_pc.sh --only services`. systemd disables the timer while its file exists.
3. An agent, pull request: the timer's entry goes, which a plan reports unknown once its file is gone; the four files get
   `state = "absent"`; `host/k3s/config.yaml` drops its `kubelet-arg`.
4. The operator: `scripts/bootstrap_pc.sh --only files`.
5. The operator: `mise run bootstrap:k3s`.

The inotify limits:

6. An agent, pull request: `/etc/sysctl.d/90-inotify.conf` gets `state = "absent"`.
7. The operator: `scripts/bootstrap_pc.sh --only files,services`. The kernel keeps the raised values until the next
   reboot.

The disk units:

8. An agent, pull request: every disk unit, the Trash's included, gets `state = "absent"`.
9. An agent: `scripts/bootstrap_pc.sh --only dotfiles,linux-systemd-units`. `~/.config/user-tmpfiles.d/disk.conf`
   and `~/.local/share/docuum/state.yml` stay, inert without the units.

Rollback: [install the PC](install-the-pc.md), steps 9 and 10.

## Escalate

A plan that lists more than the step's change, or `bootstrap:k3s` stopping: stop and ask the operator.
