# AGENTS.md

## Commands

- `quality hygiene .` runs the repository rules of quality at the release `.github/workflows/ci.yml` pins and must print `hygiene: clean`. Install it as
  quality's README says, at that release.
- `scripts/bootstrap_pc.sh --only tools` installs the mise its header pins, checks its sha256 and installs the
  tools `mise.lock` holds; a tool without a lock entry is an error. A fresh machine first needs `git`, `curl` and
  `sha256sum` (on Ubuntu, `apt-get install ca-certificates curl git`); the script names the first one missing and
  installs nothing. Change a tool with `mise lock` after editing
  `mise.toml`, never by hand.
- `mise run flux:export` regenerates `clusters/pc/flux-system/gotk-components.yaml` from the locked flux2.
- `mise run secrets:age-secret <key file>` creates the Secret `sops-age` in flux-system, the age key Flux decrypts
  `platform-secrets` with, from the given file; it has no default path. The PC calls it only through
  `bootstrap:secrets`, since a bare run talks to `~/.kube/config`.
- `mise run secrets:new-key` is the operator's: it creates the age key once in the file sops reads, `SOPS_AGE_KEY_FILE`
  if set and non-empty, else `${XDG_CONFIG_HOME:-~/.config}/sops/age/keys.txt` (mode 600 in a directory at 700), and
  prints only its recipient. It refuses, changing nothing, an existing key file, an existing directory at another mode
  and a `<key file>.drill`. The PC's key lives in that file, and its one copy in the operator's password manager.
- `scripts/apply_github_settings.sh` plans the GitHub settings `src/opentofu/github` declares, with the operator's own gh
  login, on any commit and without writing state (exit 0 no change, 2 changes, 1 failure). `--apply` applies that
  run's own plan, only from a clean `origin/main`, and is run only by the operator or on his word.
- `mise run github:test` checks that root: format, init against the committed lock, validate and the mocked tests.
- `mise run bootstrap:k3s` installs k3s at `K3S_VERSION` on the PC from k3s's `install.sh` at that tag, only after its
  pinned sha256 matched, with k3s's own containerd and no `kubectl`, `crictl` or `ctr` link. With that version
  installed, it restarts `k3s.service` when `/etc/rancher/k3s/config.yaml` changed after k3s's last start and else
  changes nothing; it stops when that file is missing or differs from `host/k3s/config.yaml`. Then it waits for the
  node. `mise run bootstrap:flux` applies Flux from `clusters/pc/flux-system` through k3s's own kubeconfig and waits
  for its controllers. `mise run bootstrap:secrets` is the operator's, since it reads the age key file: through k3s's
  own kubeconfig it creates `sops-age` from that file and the deploy-key Secret `platform-secrets`, each only when
  missing, and passes the deploy key only once GitHub's meta API lists every host key it holds, a check an existing
  one passes on every run. It prints the public key to add once, read-only, in GitHub's web form, then waits for
  `platform-secrets` to be Ready. `mise run bootstrap` runs the three in order, as a full `mise bootstrap` does after
  its declarative parts.

## The PC's host step

- It runs from a checkout, in this order: `scripts/bootstrap_pc.sh --only tools`; `scripts/bootstrap_pc.sh plan
  --detailed-exitcode` (the script sets `LC_ALL=C`, which mise needs to read a localized ufw), which must list only
  the entry state's changes; `scripts/bootstrap_pc.sh --only files,firewall`, which writes
  `/etc/rancher/k3s/config.yaml` and adds mise's one ufw rule on `cni0` before k3s first starts;
  `mise run bootstrap:k3s`; `mise run bootstrap:flux`; `mise run bootstrap:secrets`, by the operator.
- `/usr/local/bin/k3s` decides the entry state. Absent, it is a first install (no `mise:` ufw rule and no
  `/var/lib/mise/bootstrap/firewall.json`; the plan lists `/etc/rancher/k3s`, its config file, the firewall and the
  rule) or the uninstalled state (the `mise:` rule and the state file kept, `/etc/rancher` holding at most
  `node/password`; the plan lists only `/etc/rancher/k3s` and its config file). Present with `k3s-uninstall.sh`
  beside it, it is an existing install. Any other state, `/etc/rancher/k3s` without `/usr/local/bin/k3s` included,
  stops the step.
- The undo is `sudo /usr/local/bin/k3s-uninstall.sh`, then the firewall section applied with `state = "absent"`, which
  deletes mise's rule and its state file and keeps the operator's own; deleting the section or reverting the
  commit changes nothing on the host. The uninstall leaves `/etc/rancher/node/password` (k3s's node password), the
  empty `/var/lib/rancher`, `/var/log/pods` and `/var/log/containers`. The kernel settings k3s made and the empty
  `*mangle` tables it created in the IPv4 and IPv6 rules stay until a reboot, so the rules equal those before the
  install apart from those two tables. The uninstall runs without
  the operator's word only while the cluster holds no PersistentVolume, no claim and no Secret beyond its first
  install's; an inventory that differs or cannot be read stops k3s with `k3s-killall.sh`, which deletes nothing, and
  the uninstall waits for his word.
- The PC runs only the bootstrap parts and sub-tasks a slice names, never a full `mise bootstrap` or
  `scripts/bootstrap_pc.sh` without `--only`, except its `plan --detailed-exitcode` that only lists changes, because hal
  runs beside it.

## Layout

- `.github/workflows/ci.yml`: the `checks` job, the `cluster` job, the `bootstrap` job, the `opentofu` job and the `quality` job that
  calls quality's `gate.yml`. `bootstrap` installs the prerequisites in a bare `ubuntu:26.04` container, runs
  `scripts/bootstrap_pc.sh --only tools`, asserts the tools and fails when a second run changes the paths or the file
  sizes and timestamps under `~/.local/bin` and mise's data directory (directory timestamps are not compared, the paths
  inside every directory are).
  `cluster` reconciles `clusters/pc` in k3d, with `host/k3s/config.yaml` mounted alone and read-only at
  `/etc/rancher/k3s/config.yaml` on its one server, in both modes through an overlay whose one base is the PC's own
  `clusters/pc/flux-system`. The overlay adds only the root's `spec.patches` (the committed self-Kustomization dropped,
  each PC-only source swapped for one the job serves; a new PC-only source joins that list) and, on a pull request,
  the pull request's ref. The job proves decryption with an age key and a dummy Secret it generates and never prints.
  It also proves that `secrets:github-host-keys` passes flux's real export of a throwaway deploy key unchanged and
  refuses host keys GitHub does not list for `github.com`, and that `secrets:new-key` refuses a key directory not at
  700 and a drill file.
- `clusters/pc/flux-system/`: Flux's own components and its sync to this repository. `gotk-components.yaml` is
  generated by `mise run flux:export`; it is not edited by hand, and `cluster` fails when a regeneration differs.
  The root Kustomization `flux-system` health-checks only its controller Deployments and its own GitRepository, so a
  failing layer reports itself; a regeneration that adds, renames or removes a controller changes those
  `healthChecks` with it, and `cluster` fails when they differ from the root's inventory.
- `clusters/pc/secrets.yaml`: the reference to the private repository Flux fetches secrets from on the PC; platform holds no secret.
- `host/k3s/config.yaml`: the k3s server configuration the PC and k3d share; `cluster` proves its keys from the
  cluster, except `write-kubeconfig-group` and `write-kubeconfig-mode`: k3d's image has no `docker` group, so the PC's
  host step proves those two on the PC.
- `mise.toml`: the tools, the k3s version and its installer's sha256, the PC's bootstrap parts (the k3s config file
  and the ufw rule `k3s-cni`, with `k3s-pods` and `k3s-services` declared absent, which deletes them from a host whose mise
  state holds them) and the tasks. `mise.lock` is generated by `mise lock`, not edited by hand, and `cluster`
  fails when a regeneration differs.
- `src/opentofu/github/`: the security and merge settings of the managed fleet repositories. `.terraform.lock.hcl` is
  generated by `tofu providers lock -platform=linux_amd64`; the job `opentofu` runs `mise run github:test`. The state
  lives at `${XDG_STATE_HOME:-~/.local/state}/platform/opentofu/github.tfstate` and the working files (lock, provider,
  kept plan `last.tfplan`) under `${XDG_CACHE_HOME:-~/.cache}/platform/opentofu/github/`, both outside the checkout.
- `.github/workflows/code-scanning.yml`: CodeQL through quality's `codeql.yml`.
- `quality/config.toml`: the gate's mandatory jobs; a root entry outside quality's base list is declared here.
- `sonar-project.properties`: the SonarCloud project.

## Owners

- A GitHub setting `src/opentofu/github` holds changes only through that root and the command, never by hand.
- quality owns the gate, its workflows and its docs; the jobs and pins here follow its README and `docs/`.
- overnightworks/platform#1 holds the plan.
