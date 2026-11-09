# platform

This repository builds nothing a maintained tool already does. It is the one description of the platform, the k3s and Flux configuration in Git, plus the few tools no tool covers: legal pages, person export and erasure, AI keys and budgets, the restore test and the secret checks.

The platform of the overnightworks apps: k3s on one machine, with Flux reconciling its whole state from Git.

The GitHub security and merge settings of the fleet's repositories live here as OpenTofu code.

It is not an application and holds no app code or libraries. Libraries release through their own CI-gated GitHub
releases.

An app that runs on the platform follows [docs/app.md](docs/app.md).

## Start

Each runbook is one task with its commands and how to see it worked. A new PC starts with the first.

- [Install the PC](docs/runbooks/install-the-pc.md): the host step from a checkout, and a new host part.
- [Remove a host part](docs/runbooks/remove-a-host-part.md): the pod-log parts, the inotify limits, the journal's retention or the disk units.
- [Uninstall k3s](docs/runbooks/uninstall-k3s.md): k3s leaves the PC.
- [`check:pod-logs` fails](docs/runbooks/pod-logs-check-fails.md): a pod log past its bound or a clean that did not run.
- [GPU runtime handler missing](docs/runbooks/gpu-runtime-handler-missing.md): the card's runtime is missing.
- [Restore a database](docs/runbooks/restore-a-database.md): a namespace's Postgres from its latest backup.
- [Apply the GitHub settings](docs/runbooks/apply-github-settings.md): plan and apply `src/opentofu/github`.
- [Change AI keys and budgets](docs/runbooks/change-ai-keys-and-budgets.md): budgets, an app's key, an admin's budget.
- [Move the AI group](docs/runbooks/move-the-ai-group.md): the AI group's members move at the live switch.

The plan and the target picture are in [overnightworks/platform#1](https://github.com/overnightworks/platform/issues/1).
