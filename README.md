# platform

This repository builds nothing a maintained tool already does. It is the one description of the platform, the k3s and Flux configuration in Git, plus the few tools no tool covers: legal pages, AI keys and budgets, the restore test and the secret checks.

The platform of the overnightworks apps: k3s on one machine, with Flux reconciling its whole state from Git.

The GitHub security and merge settings of the fleet's repositories live here as OpenTofu code.

It is not an application and holds no app code or libraries. Libraries release through their own CI-gated GitHub
releases.

## Documentation

- [docs/commands.md](docs/commands.md): what each task and each proof on the PC does, refuses and prints.
- [docs/app.md](docs/app.md): what an app on the platform relies on and offers.
- [docs/legal-sections.md](docs/legal-sections.md): an app's legal files and the form `legal:check` accepts.
- [AGENTS.md](AGENTS.md): what an agent working here must know.
