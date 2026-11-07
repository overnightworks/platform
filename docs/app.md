# An app on the platform

Reference for the head who moves an app onto the platform or changes how it runs there. It says what an app may rely on,
what every app offers, what its move proves, and where each rule is checked. It restates no mechanics of its owners:
`AGENTS.md` (the manifests and their checks) and quality's release path and gate.

## Scope and trigger

This section holds ruled sentences.

- The standard covers every app that runs on the platform or moves onto it. The rules on state bind only an app that
  keeps state. Libraries are not covered; they release through quality's path alone.
- An app meets the standard with its move onto the platform; an app already there meets it in its next platform change.
  A deploy path that is leaving is never changed to conform.
- Platform owns the rule. Each rule a machine can check is checked where the checked file lives: platform's CI and
  admission for the manifests under `apps/`, quality's gate for what lives in an app repository. A check of an app
  repository cites this document.

## What an app may rely on

An app uses only the capabilities it needs; nothing obliges it to consume one.

- A host on Traefik's `web`, reached only through the platform's tunnel. A tunnel line changes in a pull request the
  operator merges.
- Its own Namespace with Pod Security `restricted`, never pruned, and a NetworkPolicy naming its senders. The Namespace
  is an entry in the platform's namespaces layer (`infrastructure/namespaces/namespaces.yaml`, prune disabled), added in
  a pull request.
- Secrets from `platform-secrets` (SOPS with age), mounted as files. An app with no Secret of its own has none.
- Its private image, pulled through the Secret `ghcr-pull`. The ref moves in a pull request the operator merges.
- Provenance: platform's `images` job checks a bumped ref's tag, attestation and signer. Admission on the PC checks the
  ref's form only.

Not provided: a backup of an app's state and a copy of anything off the PC. A dead disk loses every app's data.

## What every app offers

- **Release.** Its images come from quality's release path; their number, names and tags are that path's and the app's.
- **Description.** Its manifests live only in platform, under `apps/<app>/`. Its image ref changes only in a pull
  request the operator merges; a value the image validates, such as a caller table, changes in the same pull
  request as the ref.
- **Pod shape.** Each pod passes Pod Security `restricted` in its namespace and admission's image policy.
- **Readiness.** Each long-running process exposes a readiness check, an HTTP route or a command, that fails while it
  cannot serve. Flux reports a layer Ready only once its pods are, so a check that passes too early hides a broken start.
- **Configuration.** Live settings come from the manifest's environment, secrets from files `platform-secrets`
  supplies; no live secret is a plain environment value, since an environment value passes to every child process. How
  the app finds its files (`*_FILE`, a secrets directory) is the app's.
- **No second deploy path.** For the live app, its repository keeps no compose file, deploy script, systemd unit,
  backup script or monitoring stack; each leaves through an item on the app's board.

## Where each rule is checked

| Rule | Checked by |
|---|---|
| Image ref is a full app ref at a release, verified by tag, attestation and signer; the image comes from quality's path | platform's `images` job (tag, attestation, signer commit on quality's main); [quality's release path](https://github.com/overnightworks/quality/blob/main/docs/release.md) in the app's own release |
| Image form (listed vendor at a digest, or a full app ref) on every Pod create or change | admission policy `app-and-vendor-images` |
| Namespace enforces `restricted`; Deployment is `Recreate`, Available with one Ready pod, every container at the Deployment's digest | platform's `cluster` job, for each Deployment under `apps/` |
| Manifests live under `apps/<app>/` and reconcile | the `cluster` job through the Kustomization `apps` |
| Env files and published compose ports pass quality's rules | quality's gate rules `env-file` and `compose-port`, in the app repository |
| A readiness check exists; secrets are files; no second deploy path | not machine-checked; the move checklist's answers carry them |

## The move checklist

Each app's move item answers every line with evidence before the app takes live traffic on the platform. Platform's head
checks the answers as owner; a line not yet held names its owning item and stays open on the move.

1. **Capabilities.** Which capabilities above the app uses, and which it needs that the platform does not provide yet.
2. **Open prerequisites.** Each with its owner item.
3. **Runtime and configuration interface.** Its processes and the Deployment each runs in, its images, ports, readiness
   checks, settings, secret files, writable paths and resource needs.
4. **State recovery** (an app that keeps state). Each piece of state named as truth or cache; where its truth lives
   (database kind, claims or another store, its queue) and why, against the alternatives; how database and files are
   backed up and restored into one consistent state; a restore driven once and verified at the application level (the
   app serves the restored data), not by row counts alone. What a lost queue or lock costs goes to the operator when it
   is a data loss.
5. **Rollout and migration safety.** Who runs migrations and when; whether old and new versions run side by side safely
   or writers stop first; what a failed migration leaves; how a rollback works once the schema has moved.
6. **Security boundary.** What each process runs under `restricted`, its network senders and receivers, and where it
   runs code it does not trust. A pod passes `restricted`, or the move carries an explicit operator-ruled deviation
   under marketplace's standards deviation clause; a review alone cannot authorise one.
7. **Predecessor exit.** Each part that leaves (compose files, scripts, units, monitoring, the old backups), its item,
   the proof that replaces a check it carried, and when the old path stops.

## Where it ends against quality's release path

[quality's release path](https://github.com/overnightworks/quality/blob/main/docs/release.md) ends at a released tag and a pushed, attested image. From the pull request that moves the
ref on, this standard holds. A compose file used only by CI or local runs is not covered by the no-second-deploy-path rule; quality's
gate judges it by its own rules.

## The GPU

No GPU workload runs on the platform, and this standard says nothing about the card.
