# platform

This repository builds nothing a maintained tool already does. It is the one description of the platform, the k3s and Flux configuration in Git, plus the few tools no tool covers: legal pages, person export and erasure, AI keys and budgets, the restore test and the secret checks.

The platform of the overnightworks apps: k3s on one machine, with Flux reconciling its whole state from Git.

The GitHub security and merge settings of the fleet's repositories live here as OpenTofu code.

It is not an application and holds no app code or libraries. Libraries release through their own CI-gated GitHub
releases.

The plan and the target picture are in [overnightworks/platform#1](https://github.com/overnightworks/platform/issues/1).
