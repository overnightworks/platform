# platform

## Commands

`mise tasks` lists every task; all need the locked tools: `scripts/bootstrap_pc.sh --only tools`, which needs `git`,
`curl` and `sha256sum`.

- `quality check`: the repository's rules; needs quality at the pin in `ci.yml`, installed by `mise run bootstrap:hook`.
- `mise run github:test` and `cloudflare:test`: check `src/opentofu`'s roots; need only the tools.
- `mise run legal:test`: tests `src/legal`; `mise run legal:check <key> <dir>`: checks an app's legal files; needs its checkout.
- `mise run check:secrets-expiry`: names Secrets expiring within 30 days; needs the PC's k3s.
- The operator's: `mise run secrets:new-key` (the age key, its one copy in his password manager), `check:pod-logs`
  (sudo) and `keycloak:admin` (his console sign-in).
- An agent runs `mise run bootstrap:secrets` once the age key file is in place, `litellm:admin <username>` only for
  a person he names and `gpu:use <songs|speech|free>` only inside a window he named.
- `mise run offline` and `online` take the public names off the internet and back: see
  `docs/runbooks/take-the-platform-offline.md`.
- `mise run admission:pause` and `admission:resume` are the head's: they suspend and restore the attestation check.

## Rules

- Never edit a generated file: after `mise.toml` run `mise lock`; regenerate with `mise run flux:export`,
  `charts:render` or `legal:build`; `.terraform.lock.hcl` comes from `tofu providers lock -platform=linux_amd64`.
- helm runs only in `charts:render`, never on the PC.
- On the PC run only the bootstrap parts and sub-tasks a slice names, never `mise bootstrap` or
  `scripts/bootstrap_pc.sh` without `--only` (`plan --detailed-exitcode` aside), because hal runs beside it.
- On the PC `secrets:age-secret` runs only through `bootstrap:secrets`, since a bare run reads `~/.kube/config`.
- A cell is a script under `tests/<area>/`, named for what it proves, called from `ci.yml`; it joins the part in
  `tests/flux/parts.yaml` that declares the layers it reads.
- A bump comes from Renovate's Dependency Dashboard, a release at least 7 days old unless it fixes a vulnerability.
  A Keycloak or LiteLLM bump proves itself on a restored copy; a Keycloak bump compares `realm.yaml`'s `profile` and
  `email` scopes and `default-user-profile.json` with its own; read the hooks of a chart rendered with `--no-hooks`.
- A new PC-only source joins `PC_ONLY_SOURCE` in `scripts/verify_image_release.sh`.

## Owners

- A GitHub setting `src/opentofu/github` holds changes only through that root and the command, never by hand.
  The command is `scripts/apply_opentofu.sh github`.
- `infrastructure/admission/image-vendors.yaml` is the one vendor list, which `images` and the admission layer read;
  platform's head owns it. An entry changes only when a vendor is added or removed, with its first or last ref, in a
  pull request; its review checks the vendor's page and that the repository is no app of ours.
- The tunnel's lines, the ConfigMap in `infrastructure/cloudflared/config.yaml`, change only in a pull request.
- The sections under `infrastructure/legal/sections/` stand word for word: a changed sentence is the operator's.
- quality owns the gate, its workflows and its docs; the jobs and pins here follow its README and `docs/`.

## Documents

- `docs/ARCHITECTURE.md`: read before changing a layer, a boundary or who reaches what.
- `docs/app.md`: read when an app moves onto the platform or changes how it runs.
- `docs/personal-data.md`: read when a change touches a log, a store, a backup or what LiteLLM or speech admits.
- `docs/operations.md`: read when a change touches an alert, a check, a page's reach, the PC's disk or the AI budgets.
- `docs/github-settings.md`: read before changing `src/opentofu/github`.
- `docs/cloudflare-zone.md`: read before changing `src/opentofu/cloudflare`.
- `docs/legal-sections.md`: read when an app's legal files or `legal:check` change.
- `docs/runbooks/`: read before a step on the PC, a host check, a restore or a change of AI keys, budgets or group.
