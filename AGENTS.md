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
- `mise run charts:render` regenerates each `infrastructure/<component>/rendered.yaml` with the locked helm from the
  chart at the digest the task pins, the `values.yaml` beside it and `K3S_VERSION`, without CRDs and tests. It writes
  nothing when the chart cannot be fetched or rendered or the render holds a helm hook, which it names. helm runs
  only here, never on the PC.
- `mise run secrets:age-secret <key file>` creates the Secret `sops-age` in flux-system, the age key Flux decrypts
  `platform-secrets` with, from the given file; it has no default path.
- `scripts/apply_github_settings.sh` plans the GitHub settings `src/opentofu/github` declares, with the operator's own gh
  login, on any commit and without writing state (exit 0 no change, 2 changes, 1 failure). `--apply` applies that
  run's own plan, only from a clean `origin/main`, and is run only by the operator or on his word.
- `mise run github:test` checks that root: format, init against the committed lock, validate and the mocked tests.
- `mise run bootstrap:k3s` installs k3s at `K3S_VERSION` on the PC from k3s's `install.sh` at that tag, only after its
  pinned sha256 matched, with k3s's own containerd and no `kubectl`, `crictl` or `ctr` link. With that version
  installed, it restarts `k3s.service` when `/etc/rancher/k3s/config.yaml` changed after k3s's last start and else
  changes nothing; it stops when that file is missing or differs from `host/k3s/config.yaml`. Then it waits for the
  node. `mise run bootstrap:flux` applies Flux from `clusters/pc/flux-system` through k3s's own kubeconfig and waits
  for its controllers. `mise run bootstrap` runs the two in order, as a full `mise bootstrap` does after its
  declarative parts.

## The PC's host step

- It runs from a checkout, in this order: `scripts/bootstrap_pc.sh --only tools`; `scripts/bootstrap_pc.sh plan
  --detailed-exitcode` (the script sets `LC_ALL=C`, which mise needs to read a localized ufw), which must list only
  the entry state's changes; `scripts/bootstrap_pc.sh --only files,firewall`, which writes
  `/etc/rancher/k3s/config.yaml` and adds mise's one ufw rule on `cni0` before k3s first starts;
  `mise run bootstrap:k3s`; `mise run bootstrap:flux`.
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

- `.github/workflows/ci.yml`: the `checks` job, the `cluster` job, the `bootstrap` job, the `opentofu` job, the `images`
  job and the `quality` job that calls quality's `gate.yml`.
  `images` runs `scripts/verify_image_release.sh`. It renders the tree as Flux applies it with the locked flux2
  (`flux build kustomization --dry-run --recursive` from the root Kustomization in
  `clusters/pc/flux-system/gotk-sync.yaml`, this checkout as the root's source, in a container without network).
  It judges every image of every rendered Pod template, image volumes included: a vendor ref passes only as a
  repository of the vendor list at a sha256 digest, an app ref under `ghcr.io/<owner>/` passes only through its
  release checks (its tag v<version> resolved through `git ls-remote` and peeled, `gh attestation verify` by digest
  with that commit as source digest, and the signer commit on quality's main; the job logs in to ghcr.io through
  stdin and grants `packages: read`), and Flux's controllers pass in flux-system as `flux install --export` names
  them for the components `FLUX_COMPONENTS` in `mise.toml` lists. It refuses another
  kind that carries an image, every Helm object, a `substituteFrom` ConfigMap, a remote kustomize resource, a changed
  root, and every source but this repository's default branch and the owner's repository `platform-secrets`, as well as
  the source fields, ignore files, symlinks and Kustomization paths above their source's root that would make what
  Flux applies differ from the render. Its gaps: it does not
  render `platform-secrets`, and a `substituteFrom` Secret's variables render empty or at their defaults. No check
  on the PC judges these yet; overnightworks/platform#50 owns that check, and overnightworks/platform#49 lists the
  gaps. `tests/images/` holds the matrix's cases, which the job runs.
  `bootstrap` installs the prerequisites in a bare `ubuntu:26.04` container, runs
  `scripts/bootstrap_pc.sh --only tools`, asserts the tools and fails when a second run changes the paths or the file
  sizes and timestamps under `~/.local/bin` and mise's data directory (directory timestamps are not compared, the paths
  inside every directory are).
  `cluster` reconciles `clusters/pc` in k3d, with `host/k3s/config.yaml` mounted alone and read-only at
  `/etc/rancher/k3s/config.yaml` on its one server, in both modes through an overlay whose one base is the PC's own
  `clusters/pc/flux-system`. The overlay adds only the root's `spec.patches` (the committed self-Kustomization dropped,
  each PC-only source swapped for one the job serves; a new PC-only source joins that list; `tunnel` given its own
  `spec.patches`, which only scale the Deployment `cloudflared` to 0, as k3d holds no tunnel token) and, on a pull
  request, the pull request's ref. It first fails when the committed root or `tunnel` carries `spec.patches`, which
  the overlay would replace. The job proves decryption with an age key and a dummy Secret it generates and never prints.
  Before the cluster starts, it regenerates `gotk-components.yaml`, `mise.lock` and the renders, and fails when git
  status over them and `infrastructure/` is not empty or git ignores one of those files. After the reconcile it reads
  Traefik from the cluster: its Service is ClusterIP with the one port `web`, an unrouted host gets 404, its container
  runs the Deployment's digest, and no Service of type NodePort or LoadBalancer and no Pod on a host port or the host
  network exists in the cluster. It fails naming a Namespace of the layer `namespaces` without the prune annotation.
  It runs Pods built from `cloudflared`'s template, its Secret volumes dropped and its arguments replaced: Pod Security
  `restricted` admits them, `cloudflared tunnel ingress validate` passes on the committed config, an unrouted host gets
  `http_status:404`, and hopin's rule names Traefik's `web` port, where a client Pod in namespace `cloudflared` gets
  Traefik's 404. k3d does not prove the edge connection, the token mount or `/ready`.
- `clusters/pc/flux-system/`: Flux's own components and its sync to this repository. `gotk-components.yaml` is
  generated by `mise run flux:export` for the components `FLUX_COMPONENTS` in `mise.toml` lists, which hold no Helm reconciler
  (every chart is rendered into Git); it is not edited by hand, and `cluster` fails when a regeneration differs.
  The root Kustomization `flux-system` health-checks only its controller Deployments and its own GitRepository, so a
  failing layer reports itself; a regeneration that adds, renames or removes a controller changes those
  `healthChecks` with it, and `cluster` fails when they differ from the root's inventory.
- `clusters/pc/infrastructure.yaml`: one Flux Kustomization per directory under `infrastructure/`, each with
  `wait: true` and a `timeout`. `namespaces`, then `platform-secrets` (in `clusters/pc/secrets.yaml`), then `tunnel`
  apply in that order through `dependsOn`.
- `infrastructure/namespaces/`: the Namespaces that receive Secrets from `platform-secrets`, each carrying
  `kustomize.toolkit.fluxcd.io/prune: disabled`, so Flux never deletes one with its Secrets.
  A Namespace removed from Git stays in the cluster; it leaves only after its Secrets left `platform-secrets`, by a
  deletion on the PC.
- `infrastructure/cloudflared/`: the platform's own tunnel `platform`. The ConfigMap holds its lines, one per host to
  Traefik's Service and a final `http_status:404`; the Deployment `cloudflared` reads the tunnel and its credential
  only from the token file of the Secret `tunnel-token`, which `platform-secrets` applies, so no tunnel id, credential
  or Cloudflare API token is in this tree. Its image moves by hand, in a pull request the operator merges.
- `infrastructure/traefik/`: Traefik, the cluster's ingress for Kubernetes Ingress objects, in a Namespace that
  enforces Pod Security `restricted`. `values.yaml` is its hand-written source; `rendered.yaml` is generated by
  `mise run charts:render`, not edited by hand, and `cluster` fails when a regeneration differs. A chart or image bump
  changes the task's chart digest, `image.digest` and `versionOverride` together and regenerates, by hand in a pull
  request the operator merges.
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
- `infrastructure/admission/image-vendors.yaml` is the one vendor list, which `images` and the admission layer read;
  platform's head owns it. An entry changes only when a vendor is added or removed, with its first or last ref, in a
  pull request the operator merges; its review checks the vendor's page and that the repository is no app of ours.
- The tunnel's lines, the ConfigMap in `infrastructure/cloudflared/cloudflared.yaml`, change only in a pull request
  the operator merges.
- quality owns the gate, its workflows and its docs; the jobs and pins here follow its README and `docs/`.
- overnightworks/platform#1 holds the plan.
