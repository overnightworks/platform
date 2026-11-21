# platform

This repository builds nothing a maintained tool already does. It is the one description of the platform, the k3s and Flux configuration in Git, plus the few tools no tool covers: legal pages, person export and erasure, AI keys and budgets, the restore test and the secret checks.

The platform of the overnightworks apps: k3s on one machine, with Flux reconciling its whole state from Git.

The GitHub security and merge settings of the fleet's repositories and the lookups of the Cloudflare zone live here as OpenTofu code.

It is not an application and holds no app code or libraries. Libraries release through their own CI-gated GitHub
releases.

## Where to read on

- Changing the platform: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) holds its parts, boundaries and reasons;
  [AGENTS.md](AGENTS.md) holds the commands, rules and owners an agent needs.
- An app that runs on the platform: [docs/app.md](docs/app.md); its legal files: [docs/legal-sections.md](docs/legal-sections.md).
- A privacy text, or a change to a log, a store or a backup: [docs/personal-data.md](docs/personal-data.md).
- The operator: [docs/operations.md](docs/operations.md) for alerts, checks, pages, the disk and the AI budgets, and the
  runbooks below.
- The GitHub settings and the Cloudflare zone: [docs/github-settings.md](docs/github-settings.md) and
  [docs/cloudflare-zone.md](docs/cloudflare-zone.md).
- What the platform is for: [docs/VISION.md](docs/VISION.md).

## Start

Each runbook is one task with its commands and how to see it worked. A new PC starts with the first.

- [Install the PC](docs/runbooks/install-the-pc.md): the host step from a checkout, and a new host part.
- [Remove a host part](docs/runbooks/remove-a-host-part.md): the pod-log parts, the inotify limits, the journal's retention or the disk units.
- [Uninstall k3s](docs/runbooks/uninstall-k3s.md): k3s leaves the PC.
- [`check:pod-logs` fails](docs/runbooks/pod-logs-check-fails.md): a pod log past its bound or a clean that did not run.
- [GPU runtime handler missing](docs/runbooks/gpu-runtime-handler-missing.md): the card's runtime is missing.
- [Restore a database](docs/runbooks/restore-a-database.md): a namespace's Postgres from its latest backup.
- [Apply the GitHub settings](docs/runbooks/apply-github-settings.md): plan and apply `src/opentofu/github`.
- [Plan the Cloudflare zone](docs/runbooks/plan-the-cloudflare-zone.md): read `src/opentofu/cloudflare`'s lookups and measure the token's rights.
- [Change AI keys and budgets](docs/runbooks/change-ai-keys-and-budgets.md): budgets, an app's key, an admin's budget.
- [Move the AI group](docs/runbooks/move-the-ai-group.md): the AI group's members move at the live switch.
- [Change an app's object store key](docs/runbooks/change-an-object-store-key.md): an app's key for its bucket is new, rotated or lost.
- [Restore the object store's metadata](docs/runbooks/restore-the-object-store-metadata.md): `garage-0` crash-loops after a power loss or a kill.
