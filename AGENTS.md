# AGENTS.md

## Commands

- `quality check` runs the repository rules of quality at the release `.github/workflows/ci.yml` pins and must exit 0 and print a `✓ clean · <n> areas` line. Install it as
  quality's README says, at that release.
- `scripts/bootstrap_pc.sh --only tools` installs the mise its header pins, checks its sha256 and installs the
  tools `mise.lock` holds; a tool without a lock entry is an error. A fresh machine first needs `git`, `curl` and
  `sha256sum` (on Ubuntu, `apt-get install ca-certificates curl git`); the script names the first one missing and
  installs nothing. Change a tool with `mise lock` after editing
  `mise.toml`, never by hand.
- `mise run flux:export` regenerates `clusters/pc/flux-system/gotk-components.yaml` from the locked flux2.
- `mise run charts:render` regenerates each `infrastructure/<component>/rendered.yaml` with the locked helm from the
  chart the task pins (traefik and loki by digest, k8up by the sha256 of its tgz), the `values.yaml` beside it and `K3S_VERSION`,
  without CRDs and tests, and `infrastructure/k8up/crds.yaml` from k8up's release asset at its pinned sha256. It writes
  nothing for a chart that cannot be fetched or rendered, whose pin does not match or whose render holds a helm hook,
  which it names; each output is replaced alone, so such a failure can follow an earlier chart's written render (k8up's
  chart is rendered with `--no-hooks`: its one hook is a cleanup Job for Helm upgrades). helm runs only here, never on
  the PC.
- `mise run secrets:age-secret <key file>` creates the Secret `sops-age` in flux-system, the age key Flux decrypts
  `platform-secrets` with, from the given file; it has no default path. The PC calls it only through
  `bootstrap:secrets`, since a bare run talks to `~/.kube/config`.
- `mise run secrets:new-key` is the operator's: it creates the age key once in the file sops reads, `SOPS_AGE_KEY_FILE`
  if set and non-empty, else `${XDG_CONFIG_HOME:-~/.config}/sops/age/keys.txt` (mode 600 in a directory at 700), and
  prints only its recipient. It refuses, changing nothing, an existing key file, an existing directory (or a link's
  target) at another mode, a key directory a file blocks and a `<key file>.drill`. The PC's key lives in that file, and
  its one copy in the operator's password manager.
- `scripts/apply_github_settings.sh` plans the GitHub settings `src/opentofu/github` declares, with the operator's own gh
  login, on any commit and without writing state (exit 0 no change, 2 changes, 1 failure). `--apply` applies that
  run's own plan, only from a clean `origin/main`. A plan with a `delete` action, a replacement included, fails with
  exit 1 on both runs, names each address and applies nothing; a deliberate removal is a `removed` block with
  `lifecycle { destroy = false }`, which plans a forget.
- `mise run github:test` checks that root: format, init against the committed lock, validate, the mocked tests and
  `tests/github/plan_with_a_delete_is_refused.sh`, which drives the script against a fake tofu and gh.
- `mise run check:pod-logs` is the operator's, since it runs through sudo: it runs the installed `check-pod-logs`,
  which names every pod log file past its bound and a daily clean that has not run within 25 hours or failed, by file
  names and times only, and fails on any; it passes with no pod logs yet while `/var/log/pods` does not exist, and
  fails when it cannot list the directory. It reads the clean's last start (the later of the service's and the timer's
  last trigger, which a reboot keeps) and result, whoever started it, so a failed or never-run clean keeps failing the
  check until `sudo systemctl start pod-logs-clean.service` has run, then `mise run check:pod-logs`.
- `mise run check:secrets-expiry` runs on the PC through k3s's own kubeconfig, without sudo, and reads only metadata: it
  names, by namespace, name and date, every Secret whose annotation `platform.hallucinai.de/expires-on: YYYY-MM-DD` lies
  within 30 days or in the past, and each whose value is no such date, and fails on any or when the listing fails; it
  passes with no annotated Secret.
- `mise run backup:fetch <namespace> <file>` writes the latest dump of the namespace's k8up repository to a new file at
  0600, through a Pod built from the restore test's init container, the file it refuses to overwrite; `db:load-dump
  <namespace> <file>` then restores it. It prints only names and sizes, since a dump holds keys and hashes.
- `mise run disk` runs without sudo and prints what fills the disk of the home directory by size and name (named
  directories of `$HOME`, the rest of `$HOME`, and what lies outside it, which is Docker's `/var/lib/docker` and the
  system, since only root reads that), then Docker's own count when the daemon answers within 2 minutes, else one line
  saying it does not answer in time; from 85 % use it first prints a `WARNING` line on stderr, and it still exits 0. A directory du cannot
  read marks its row incomplete and prints the remainders as `?`, never as a number.
- `mise run db:load-dump [--compare] <namespace> <file>` is the platform's restore command:
  it loads a custom-format dump into the namespace's Postgres with Flux's Kustomization of that name suspended, its
  Deployments at 0 and its Flux Jobs deleted, waiting for the deletion of the Pods a ReplicaSet owns except those in phase
  `Failed` or `Succeeded` none of whose containers or init containers reports `running` (an evicted Pod stays and holds
  no session; a Pod marked `Failed` from outside can still run, and one with no readable phase is waited for), in one `pg_restore` transaction whose messages go to `<file>.load.log`
  at 0600, verifies each table `key-tables` names (all tables and their sorted rows' sha256 with `--compare`) and only
  then resumes Flux and waits for the namespace to converge. It refuses a suspended Kustomization. Another session
  that holds the database before the load, a database it cannot read then, or an INT before the load costs at most one
  wait of 2 minutes and one line, loads nothing and resumes. A restore that fails or is interrupted reports the data
  unchanged and resumes once no session and no `pg_restore` process remains in the database's Postgres, it holds no
  materialized view or extension table, whose rows `pg_dump` does not write, and the sha256 of its whole `pg_dump`
  equals the one taken before the load. Otherwise, a TERM during that check included, it reports the outcome unknown
  and, like a differing load or one that ends before the comparison did, stays suspended with its writers at 0, naming
  `--resume`. After a hard kill, `mise run db:load-dump --resume <namespace>` resumes once no other session and no
  `pg_restore` process holds the database, stops at once when the Kustomization does not exist, and verifies nothing.
  It prints names, counts and outcomes, never a row, since a dump holds keys and hashes.
  `tests/postgres/interrupt_load.sh <namespace> <dump> <INT|KILL>` interrupts a load inside its transaction and asserts
  that recovery, writers included. `tests/postgres/load_dump.sh` drives the task and that script against fake commands
  for the outcomes the cluster cannot arrange: a failed `flux resume`, an unreadable suspension (also after a kill), a
  signal during the comparison, an evicted Pod beside a running one, which alone is waited for, and one alone, which costs
  no wait, a `Failed` Pod that reports a running container, which is waited for, a table only the database holds, a database it cannot read before or after the load,
  a materialized view, a `pg_restore` that outlives its status while its backend commits, a TERM during the check
  after a failed restore, and an INT after the commit, whose outcome reaches the operator and not the load log.
- `mise run legal:check <key> <dir>` checks an app's `<dir>/legal/datenschutz.html` and, if present,
  `<dir>/legal/nutzungsbedingungen.html` with the section validator of `src/legal/` (grammar and format in
  `docs/legal-sections.md`): it prints `legal:check: <key> valid: <pages>` and exits 0, or prints `legal: <file>: line N:
  <rule>`, never the text, and exits non-zero. It refuses a link or directory in place of a file, a missing
  `datenschutz.html` and a `<dir>` that is none; a relative `<dir>` is read from this checkout; it writes nothing. The
  `zone` is the host of the Ingress in `infrastructure/legal/legal.yaml`. `mise run legal:test` runs the project's tests
  with branch coverage at 100 % and writes `src/legal/coverage.xml`. `mise run legal:build` reads, from this checkout's root, the frame of
  `infrastructure/legal/frame/`, the sections of `infrastructure/legal/sections/` and their `stand.toml`, the app texts of
  `infrastructure/legal/app-texts/` and their list `app-texts.toml`, builds the three pages with
  `src/legal/src/legal/pages.py`, which checks their ids and links, and writes all three to `infrastructure/legal/built/`; it needs no
  network, prints `legal:build: wrote <file>` per page and exits 0, or prints `legal: <file> is missing; the frame is required`
  (or the failed check's line, which names a directory under `sections/` that is neither `allgemein` nor one of `keycloak`,
  `litellm` or `speech-runtime`, a section with no `stand.toml` entry, an entry without a file or a section whose sha256
  differs from its entry, printing the file's, and the same for an app text and `app-texts.toml`, an app with no
  `datenschutz` and an app key that is `allgemein` or a service's) and exits non-zero, writing nothing. It reads the `zone` as `legal:check`
  does. All three run through `uv` (locked in `mise.toml`),
  which fetches Python 3.14 on first use and keeps its environment under `~/.cache/platform/legal`.
- `mise run keycloak:admin` is the operator's: it forwards `127.0.0.1` at the port of Keycloak's `KC_HOSTNAME_ADMIN`
  to Keycloak's Service and prints the console's address, to open in a private window, since a browser keeps cookies
  per host and hal's console answers on another port of `localhost`.
- `mise run gatus:open` forwards `127.0.0.1` at a free local port kubectl chooses to the port of Gatus's Service and prints
  the address of the status page once kubectl listens, none when the forward fails, which exits non-zero; the page has no
  other way in.
- `mise run grafana:open` does the same for Grafana's Service, through the one hidden task `page:forward` that
  `gatus:open` shares.
- `mise run keycloak:agent-owner [--adder] <client> <username>` runs through kcadm in Keycloak's
  container, signed in as config-cli, it sets the service account's `agent_owner` of a service-account client of
  `realm.yaml` with `agent-identity` among its default scopes to that one person's id, keeping the account's other
  attributes, and adds the person to `/agent-owners`, with `--adder` also to `/agent-adders`. It refuses another
  client, a username that no person carries, which Keycloak's user search finds without service accounts and
  matches by the lowercase username, so a service account's name in any case is refused with the rest, and an
  `agent_owner` naming someone else; before its first write a refusal ends in `nothing changed`, after one it names what was written or may
  have been and says that running it again completes it. It reads everything back, prints names and member counts and
  prints `nothing changed` on a second run.
- `mise run keycloak:move-group [--delete-old] <file>` is for the rename of the AI group: it creates
  the new file at 0600 (and refuses one that exists), dumps `keycloak` into it with the messages of `pg_dump` and
  `pg_restore --list` in `<file>.dump.log` at 0600, whose path and line count it prints, deletes only its own file
  after a failed dump, adds every member of `/services/agent-service/api` to `/services/litellm` through kcadm in
  Keycloak's container, signed in as config-cli, verifies the old members are a subset and prints the two groups'
  member counts; only `--delete-old` deletes the old group. `db:load-dump keycloak <file>` rolls it back.
- `mise exec -- tests/keycloak/restored_copy_keeps_its_keys_and_people.sh <dump>` runs on the PC after
  `db:load-dump keycloak <dump>` converged, through k3s's own kubeconfig, without sudo or a fetched secret: it fails
  unless config-cli's Job completed within its `backoffLimit`, no client or user carries Keycloak's
  `is_temporary_admin`, the realm's key ids equal those of the public issuer, and the rows of `user_entity`,
  `credential`, `user_group_membership` and `user_attribute` equal the dump's by count and the sha256 of their sorted
  lines, except the rows of the service accounts that clients declared in `realm.yaml` gained since the dump, whose
  count its "added" line prints. It prints names, counts, key ids and `equal` or `DIFFERS`, never a row or a message of `pg_restore` or `psql`. Each database
  step runs under a statement and lock timeout and a 2-minute local deadline; pg_dump and pg_restore also run under
  the container's own 100-second timeout, so no database session outlives the check. Either deadline's end fails it
  naming the step and which deadline.
- `mise run bootstrap:k3s` installs k3s at `K3S_VERSION` on the PC from k3s's `install.sh` at that tag, only after its
  pinned sha256 matched, with k3s's own containerd and no `kubectl`, `crictl` or `ctr` link. With that version
  installed, it restarts `k3s.service` when `/etc/rancher/k3s/config.yaml` changed after k3s's last start and else
  changes nothing; it stops when that file is missing or differs from `host/k3s/config.yaml`. Then it waits for the
  node. `mise run bootstrap:flux` applies Flux from `clusters/pc/flux-system` through k3s's own kubeconfig and waits
  for its controllers. `mise run bootstrap:secrets` is the operator's, since it reads the age key file: through k3s's
  own kubeconfig it creates `sops-age` from that file and the deploy-key Secret `platform-secrets`, each only when
  missing, and passes the deploy key only once GitHub's meta API lists every host key it holds, a check an existing
  one passes on every run. It then requests a reconcile of the source `platform-secrets`, and only when that is not
  Ready within a minute prints the public key to add once, read-only, in GitHub's web form, requesting a reconcile
  every 30 seconds for up to 15 minutes; then it waits for the Kustomization. Its lines name each object as `<Kind>
  <name>`; the `secrets:` tasks it calls print only their refusals, under their own prefix. A refusal reads `<task>:
  <condition>; <the way back>`, except the host-key filter's `; nothing passed on`, after which `bootstrap:secrets`
  names the way back. `mise run bootstrap` runs the three in order, as a full `mise bootstrap` does after its
  declarative parts.

## The PC's host step

- It runs from a checkout, in this order: `scripts/bootstrap_pc.sh --only tools`; `scripts/bootstrap_pc.sh plan
  --detailed-exitcode` (the script sets `LC_ALL=C`, which mise needs to read a localized ufw), which must list only
  the entry state's changes; `scripts/bootstrap_pc.sh --only files,firewall,services`, which writes
  `/etc/rancher/k3s/config.yaml` and the pod-log parts, adds mise's one ufw rule on `cni0` before k3s first starts and
  starts `pod-logs-clean.timer`; `mise run bootstrap:k3s`; `mise run bootstrap:flux`; `mise run bootstrap:secrets`, by
  the operator; `sudo systemctl start pod-logs-clean.service` once, since the timer's first run is the coming midnight
  and the check fails until a clean has run; `mise run check:pod-logs`, by the operator.
- `/usr/local/bin/k3s` decides the entry state. Absent, it is a first install (no `mise:` ufw rule and no
  `/var/lib/mise/bootstrap/firewall.json`; the plan lists `/etc/rancher/k3s`, its config file, the firewall and the
  rule) or the uninstalled state (the `mise:` rule and the state file kept, `/etc/rancher` holding at most
  `node/password`; the plan lists only `/etc/rancher/k3s` and its config file). Present with `k3s-uninstall.sh`
  beside it, it is an existing install. Each plan also lists the pod-log parts and the timer until they are applied.
  Any other state, `/etc/rancher/k3s` without `/usr/local/bin/k3s` included, stops the step.
- The undo is `sudo /usr/local/bin/k3s-uninstall.sh`, then the firewall section applied with `state = "absent"`, which
  deletes mise's rule and its state file and keeps the operator's own; deleting the section or reverting the
  commit changes nothing on the host. The uninstall leaves `/etc/rancher/node/password` (k3s's node password), the
  empty `/var/lib/rancher`, `/var/log/pods` and `/var/log/containers`. The kernel settings k3s made and the empty
  `*mangle` tables it created in the IPv4 and IPv6 rules stay until a reboot, so the rules equal those before the
  install apart from those two tables. The uninstall runs without
  the operator's word only while the cluster holds no PersistentVolume, no claim and no Secret beyond its first
  install's; an inventory that differs or cannot be read stops k3s with `k3s-killall.sh`, which deletes nothing, and
  the uninstall waits for his word.
- The pod-log parts (`host/pod-logs/`) keep every pod log line at most 30 days, as the apps' privacy texts promise:
  `pod-logs.conf` in `/etc/tmpfiles.d/` deletes each file under `/var/log/pods` 28 days after its creation, with its
  emptied directories, and every `.gz` and `.tmp` in each container directory whatever its age, since the kubelet
  makes none and a copy's creation time is younger than its lines; `pod-logs-clean.timer` and `.service` in
  `/etc/systemd/system/` run that clean daily by the wall clock and after boot, then `scripts/check_pod_logs.sh` as
  `/usr/local/sbin/check-pod-logs`;
  `container-log-max-files=2` in `host/k3s/config.yaml` keeps the kubelet from compressing a rotated file. A first
  apply on an existing install is `scripts/bootstrap_pc.sh --only files,services`, then `mise run bootstrap:k3s`,
  `sudo systemctl start pod-logs-clean.service` and `mise run check:pod-logs`. Their undo declares the timer
  `state = "stopped"` and `enabled = false` and applies `--only services`, so systemd disables it while its file
  exists; then deletes the timer's entry, which a plan reports unknown once its file is gone, declares the four files
  `state = "absent"` and applies `--only files`; then drops the `kubelet-arg` and runs `mise run bootstrap:k3s`.
  Deleted logs stay deleted.
  `check-pod-logs` never reads Loki's copy of the lines, whose bound `infrastructure/loki/` sets; the `cluster` cell on
  Loki's running configuration is the only check of it.
- The inotify limits (`host/sysctl/inotify.conf`: 512 instances and 524288 watches per user, so root's inotify instances
  suffice for the kubelet's log follows and for hal's containers beside k3s) go to `/etc/sysctl.d/90-inotify.conf` by
  `scripts/bootstrap_pc.sh --only files,services`, whose file entry notifies `systemd-sysctl.service`, which the services
  step restarts so the values apply without a reboot. It needs sudo, so it is the operator's. Undo: declare
  the file `state = "absent"` and apply `--only files,services`; the kernel keeps the raised values until the next reboot, or
  until `sudo sysctl -w` sets them back.
- The disk's bounds run in the operator's user manager, which lingers, and need no sudo: after `scripts/bootstrap_pc.sh
  --only tools` (the units' binaries must exist first), `scripts/bootstrap_pc.sh --only dotfiles,linux-systemd-units`
  writes `~/.config/user-tmpfiles.d/disk.conf` from `host/disk/` and the units `dev.mise.docuum.service`,
  `dev.mise.uv-cache-clean-weekly.timer`, `dev.mise.user-tmpfiles-clean-daily.timer` and
  `dev.mise.trash-prune-daily.timer` with their services, from `mise.toml`, and restarts Docuum. Docuum keeps `docker system df`'s Images line, which counts a shared layer once,
  at 100 GB, deleting images least recently used first, never one younger than a day, one a container uses, one tagged
  `previous`, a `-base` image or one of the vendor repositories its `--keep` flags name; its state is
  `~/.local/share/docuum/state.yml`, and an image it has never seen counts as last used at its creation. uv's cache
  is emptied weekly without `--force`. The tmpfiles line deletes a Codex session 30 days after the newest of its
  timestamps. `gtrash prune --day 30`, restricted to `~/.local/share/Trash`, deletes daily each Trash entry whose
  `.trashinfo` deletion date is older than 30 days, with that file, and leaves an entry without a `.trashinfo`, one
  whose `.trashinfo` it cannot read and the Trash of other mounts; the unit creates the home Trash first, since gtrash
  fails on a missing one. Claude's sessions, Docker's volumes and its build cache (hal's) are never cleaned here. Undo: declare the
  units, the Trash's included, `state = "absent"` and apply the same parts; `~/.config/user-tmpfiles.d/disk.conf` and
  `~/.local/share/docuum/state.yml` stay and are inert without the units.
- The PC runs only the bootstrap parts and sub-tasks a slice names, never a full `mise bootstrap` or
  `scripts/bootstrap_pc.sh` without `--only`, except its `plan --detailed-exitcode` that only lists changes, because hal
  runs beside it.

## Layout

- `.github/workflows/ci.yml`: the `checks` job, which fails when a directory under `apps/` has no Kustomization of its
  name over it in `clusters/pc/apps.yaml` or such a Kustomization has no directory, and when a value of Keycloak's
  `realm.yaml` or `master.yaml` whose key ends in secret or password is no `$(env:NAME)` reference, naming the file
  and key path, never the value; the `cluster` job, the `bootstrap` job, the `opentofu` job, the `images` job and the
  `quality` job that calls quality's `gate.yml`.
  The cells of `cluster` and `bootstrap` live as scripts under `tests/<area>/`, named after what they prove, which the
  steps call; `ci.yml` holds the job structure, the setup and the calls.
  `cluster` runs in three parts, each on its own k3d cluster and all listed as `cluster`: `postgres` holds the Docuum
  check, the "P7a cells", the "P9c cells", the Alertmanager step and the Grafana step; `backup` holds the "P7d cells" and
  the step of `tests/no_network/`, the shortest part; `core` every other cell and the checks that need no cluster. The setup through the reconcile's
  assertion runs in all three, and a new cell joins the part with more room.
  `images` runs `scripts/verify_image_release.sh`. It renders the tree as Flux applies it with the locked flux2
  (`flux build kustomization --dry-run --recursive` from the root Kustomization in
  `clusters/pc/flux-system/gotk-sync.yaml`, this checkout as the root's source, in a container of an image pinned by its index digest, without network, ending red
  when it runs past 2 minutes).
  It judges every image of every rendered Pod template, image volumes included, and every host-qualified value of every
  `env` map in this workflow, the workflow's, each job's and each step's: a vendor ref passes only as a repository of
  the vendor list at a sha256 digest, an app ref under `ghcr.io/<owner>/` passes only through its release checks (its
  tag v<version> resolved through `git ls-remote` and peeled, `gh attestation verify` by digest with that commit as
  source digest, and the signer commit on quality's main; the job logs in to ghcr.io through stdin and grants
  `packages: read`), and Flux's controllers pass in flux-system as `flux install --export` names them for the
  components `FLUX_COMPONENTS` in `mise.toml` lists. It
  refuses another kind that carries an image, every Helm object, a `substituteFrom` ConfigMap, a remote kustomize resource, a changed
  root, and every source but this repository's default branch and the owner's repository `platform-secrets`, as well as
  the source fields, ignore files, symlinks and Kustomization paths above their source's root that would make what
  Flux applies differ from the render. Its gaps: it does not
  render `platform-secrets`, and a `substituteFrom` Secret's variables render empty or at their defaults. On the PC
  the admission policy judges their images by form only; overnightworks/platform#50 owns the attestation check, and
  overnightworks/platform#49 lists the gaps. `tests/images/` holds the matrix's cases, which the job runs.
  `bootstrap` installs the prerequisites in a bare `ubuntu:26.04` container, runs
  `scripts/bootstrap_pc.sh --only tools`, asserts the tools and fails when a second run changes the paths or the file
  sizes and timestamps under `~/.local/bin` and mise's data directory (directory timestamps are not compared, the paths
  inside every directory are). It then runs `systemd-tmpfiles --clean` with `pod-logs.conf`'s line at a seconds-long
  age on a test tree: the older file goes after an append and a read, with its emptied directories, a newer file
  stays and a `.gz` and a `.tmp` go; and it runs `check-pod-logs` against a fake `systemctl`, which passes fresh logs,
  files that vanish before their stat and a missing `/var/log/pods`, passes a clean the timer started before a
  reboot, and names a clean that never ran, last started 26 hours ago or failed, a failed listing, a `.gz` and a `.tmp`.
  It also runs `tests/disk/`: the shipped line at a seconds-long age deletes an old Codex session with its emptied
  directories and keeps a newer one and a Claude session of the older one's age, and `mise run disk` against a fake
  `df` warns at 85 % and not at 84 %, and the Trash unit's gtrash, run as the unit's `mise.toml` entry names it on a
  scratch Trash, deletes an entry trashed 31 days ago with its `.trashinfo` and keeps a directory trashed yesterday with
  2020 files and an entry without a `.trashinfo` of any age, passing on a missing and an empty Trash. The part `postgres` of `cluster` first runs Docuum with the service's own flags
  (read from `mise.toml`, only threshold and minimum age the cell's, every image the runner holds kept) against the
  runner's Docker with small imported images: the least recently used unprotected one goes, and a `:previous` tag, a
  `-base:` tag, an image a container uses and the newer one stay.
  `cluster` reconciles `clusters/pc` in k3d, with `host/k3s/config.yaml` mounted alone and read-only at
  `/etc/rancher/k3s/config.yaml` on its one server, in both modes through an overlay whose one base is the PC's own
  `clusters/pc/flux-system`. The overlay adds only the root's `spec.patches` (the committed self-Kustomization dropped,
  each PC-only source swapped for one the job serves; a new PC-only source joins that list and, since `PC_ONLY_SOURCE` in `scripts/verify_image_release.sh` holds one source, that script too; a source
  that script does not map fails the images render; `tunnel` given its own
  `spec.patches`, which only scale the Deployment `cloudflared` to 0, as k3d holds no tunnel token; `nvidia` given its
  own, which only give the device plugin's DaemonSet a node selector no k3d node carries, as k3d holds no card) and the
  `flux-system` source's ref, in the object applied and in Flux's build: a pull request's ref on a pull request, `main` at the
  run's own commit on a push, so a landing during the run moves nothing. It first fails when the committed root, `tunnel` or `nvidia` carries
  `spec.patches`, which the overlay would replace. The job proves decryption with an age key and a dummy Secret it generates and never prints.
  Its `platform-secrets` source also serves the Secrets the manifests under `apps/` name, hopin's, skat's and songmaker's files as dummies
  and each app's pull Secret from the job's own token, whose `packages: read` reads the apps' private packages; none is
  printed, each namespace whose layer includes `infrastructure/postgres` its Secret `postgres`, a generated password,
  and each key a container of a layer in `SECRET_KEY_LAYERS` reads from a Secret, a generated dummy (Alertmanager's
  smarthost, username and recipient in the forms its init container accepts, on a name that never resolves); each
  namespace whose layer includes the backup component its Secret `restic`, and the Secret `rest-users` holds their
  passwords.
  It also proves that `secrets:github-host-keys` passes flux's real export of a throwaway deploy key unchanged and
  refuses host keys GitHub does not list for `github.com`, and that `secrets:new-key` refuses a key directory not at
  700, a drill file and a regular file in the key path, and accepts a symlinked 700 key directory. `tests/secrets/`
  runs `bootstrap:secrets` against a fake kubectl: a handled Ready=False request that turns Ready within the minute
  prints no key block.
  Before the cluster starts, it regenerates `gotk-components.yaml`, `mise.lock`, the renders and the imprint, and fails when git
  status over them and `infrastructure/` is not empty or git ignores one of those files. Before the reconcile the
  kubelet's configz holds the `container-log-max-files` of `host/k3s/config.yaml`; after a writer pod's log directory
  is deleted on the node, its file is back within 30 seconds and `kubectl logs` shows newer lines; and through two
  rotations a busy writer's directory never holds more files than that or a `.gz` or `.tmp`. After the reconcile it
  reads Traefik from the cluster: its Service is ClusterIP with the one port `web`, whose trusted senders hold the nodes' pod
  CIDRs; a client Pod in namespace `cloudflared` gets 404 for an unrouted host and 400 for `/a%2Fb` on a host a
  throwaway Ingress routes, and one in another namespace gets no answer; and no Service of type NodePort or LoadBalancer
  and no Pod on a host port or the host network exists in the cluster. The route of hopin's Ingress gets that client Pod
  200 for hopin's readiness path with hopin's host, and 429 for one sign-in start more than hopin's budget from one
  forwarded address but not for the next from another; that Pod gets no answer from Traefik's probe port, it and one in
  another namespace none from hopin's Service, and every Traefik pod's address lies in a CIDR of hopin's
  `HOPIN_TRUSTED_PROXIES`. A Kustomization that never becomes Ready fails the job naming its reason, with each unready
  pod's waiting state and last log lines. Every app's Deployment, applied by its own Kustomization after its Secrets, is
  Available with one Ready pod and `Recreate` at a full app ref in a Namespace that enforces `restricted` (the step
  prints the kubelet's pull report and the runner's free disk); a client Pod in `hopin` gets 200 from speech-runtime's
  `/health` and one in another namespace gets no answer; and every running container of a Deployment outside kube-system
  and flux-system, Traefik's included, carries that Deployment's digest, a Deployment scaled to 0 aside. Every
  Kustomization but the root and `admission` whose inventory holds a workload kind or a HelmRelease depends on
  `admission` and created its workloads after `admission`'s objects, the root's workloads are the Deployments of
  `gotk-components.yaml`, and `namespaces` holds only Namespaces Flux never prunes: the job fails naming one without
  the prune annotation. It then probes the image policies by server-side dry-run on generated objects and live ones;
  every image a step runs in the cluster is a listed vendor ref at a digest. Last, it runs Pods built from
  `cloudflared`'s template, its Secret volumes dropped and its arguments replaced: Pod Security `restricted` admits
  them, `cloudflared tunnel ingress validate` passes on the committed config, an unrouted host gets `http_status:404`,
  and for every line that names a host, the rule cloudflared matches on the line's literal path (if it names one) is
  that line and points at the Service `traefik` of namespace `traefik` at its `web` port, where a client Pod in
  namespace `cloudflared`, sending the line's `httpHostHeader` if it sets one, gets Traefik's 404, or an answer of the
  route for a host an Ingress routes; on a host a line restricts by path, `/` gets `http_status:404`. k3d does not
  prove the edge connection, the token mount or `/ready`. The step "P7a cells" then asserts the one default class
  retains, each Postgres is Ready as its image's postgres user on a bound claim of it with the prune annotation at
  `<namespace>/<claim>`, and `pg_isready` passes as the namespace's user; shows that each Postgres namespace's Kustomization,
  named like it, holds the base's objects of the namespace, that no other Kustomization holds one but platform-secrets'
  Secrets, and that it depends on `admission`, `platform-secrets` and `storage`; deletes the Kustomization `litellm`, whose
  inventory goes while the claim, its volume and the Namespace stay, and the root re-creates it with the row written
  before; points the Kustomization `litellm` at `tests/postgres/writers`, the Postgres base with a Deployment and a
  Job that Flux applies, stops and restores, in place of LiteLLM, its front and its egress, and empties the database
  to what a fresh claim holds; drives `db:load-dump` and both interrupts of `tests/postgres/interrupt_load.sh` on two
  synthetic dumps it makes, one of data and one whose table of contents is most of the file, an INT that reaches the
  loader after its restore committed and a failed load beside a materialized view, which each leave it suspended, and
  a held foreign session, which costs one wait; empties the database again and gives the layer its own path back,
  which must turn Ready;
  and shows that a busybox Pod with Keycloak's labels reaches its Postgres but neither the Service `kubernetes` nor
  github.com, while one without them reaches all three. k3d does not prove the egress to hal's Docker bridges or to
  hopin, whose own policy already refuses both Pods.
  The step "songmaker's stores" asserts that Postgres and Redis of namespace `songmaker` are Ready as the image's own
  non-root user, that a Pod there reaches both and one in a throwaway namespace neither, and that a key written to
  Redis is gone once its pod is deleted and Ready again.
  The step "songmaker's web", in the part `postgres`, asserts that the Deployment `web` is Available with one Ready pod
  at a full app ref under the candidate's revision and prints the kubelet's pull report and the runner's free disk; that
  `migrate` ended 0 and `alembic_version` equals the image's head on a Postgres of the major version of the base's
  image; that a Pod in the namespace gets 200 from `/health` with the public host and an error for an unknown host
  while a Pod in another namespace gets no answer; that the pod runs as a non-root user on a read-only root and writes to
  the audio claim and `/tmp`; and that the claim is Bound on the Retain class with prune disabled.
  The step "songmaker's workers", in the part `postgres`, asserts that the Deployments `music-worker` and `scoring-worker`
  are Available with one Ready pod at a full app ref under the candidate's revision and ask for no GPU, and prints the
  kubelet's pull report and the runner's free disk; and that a Pod with the scoring worker's labels reaches the
  namespace's Postgres and Redis and neither the Service `kubernetes` nor github.com, while one without them reaches all
  four.
  The nvidia step asserts that the Kustomization `nvidia` is Ready at the candidate with its DaemonSet wanting
  0 pods, that the RuntimeClass `nvidia` has the handler `nvidia`, that Namespace `nvidia` has no Pod Security label and
  holds only that DaemonSet, and that a Pod with the class, uid 1000 and `nvidia.com/gpu: 1` passes server-side dry-run
  in a throwaway Namespace enforcing `restricted` while one at uid 0 does not. k3d does not prove the card, the runtime
  handler or the plugin's start.
  The step "P7b cells" then waits for config-cli's Job on the empty database and asserts that Keycloak's
  `KC_PROXY_TRUSTED_ADDRESSES` equals the `trustedIPs` of Traefik's `web`, discovery names Keycloak's `KC_HOSTNAME`
  as the realm's issuer, every group `realm.yaml` declares exists and `/services/agent-service/api` does not, and
  hopin's login page answers 200; that a second run of the Job completes at its first attempt and leaves the partial
  exports of both realms and their declared service accounts with their roles and groups equal; that a Pod in
  `cloudflared` gets through Traefik 200 for discovery and a `/resources/<version>/` asset, 404 for
  `/resources/master/…`, `/admin/` and `/realms/master/`, 302 from `/` to the account page, 404 for `/` on another
  host and 400 for an encoded slash; that a Pod in Keycloak's namespace reaches it and one in `hopin` gets no answer;
  that a Pod in Keycloak's namespace without its labels gets an answer from the Service `kubernetes` and from a
  throwaway target in `hopin` with hopin's labels and port, which a throwaway policy admits Keycloak's namespace to
  and which never turns ready, while Keycloak's container reaches its Postgres but neither that Service nor github.com
  nor the target nor hopin's Service, a probe that cannot run or ends otherwise failing the step, and both throwaway
  objects are gone on every exit; and that a password grant is
  refused while `TERMS_AND_CONDITIONS` is pending and yields a token of the public issuer once cleared, while
  through `admin-cli` and master's own flow a master administrator with TOTP gets 200 and a token with the current
  code, which the job computes from the secret it imported, and 400 and no token without it, and one without TOTP gets
  401 and no token.
  The step "P2 cells" then drives `tests/keycloak/agent_client_tokens_and_groups.sh` for `agent-mozart`: `/agent-adders`
  is empty and `/agent-owners` holds the service account alone; `keycloak:agent-owner` refuses an unknown username, a
  service account's name also in upper case, another owner, a client with a service account the file does not declare though Keycloak holds it
  (its account unchanged) and the other clients,
  takes a person whose username starts like a service account's, and sets the owner and groups once, a second run
  changing nothing, the groups' complete member lists then equal to what is expected; the client's standard, implicit
  and direct-access flows are off and a password grant through it is refused; a token with `scope=mcp-hopin` carries
  the file's groups exactly, its exact scope, one audience, no refresh token, 300 seconds, `at+jwt`, and its claims, and
  one without the scope no audience and exactly the default scopes that go into a token; its own token is refused at the account and admin API, and a person gets 400
  for `agent_owner` while `firstName` alone gets 204 and the metadata hides it; a person's token carries both groups;
  and a disabled client or service account gets 401, a state a config-cli re-run keeps together with every service
  account's groups, one extra group the console gave the agent's, `agent_owner` and both groups' members.
  `tests/keycloak/agent_owner_names_what_a_failed_write_left.sh` runs `keycloak:agent-owner` against a fake kubectl: a
  name no person carries, a service account's name in any case and a name only another user's email carries are
  refused with `nothing changed`, and a membership write that fails, after the owner's write or alone, prints what was
  written and no `nothing changed`.
  The step "P7c cells" first fails when LiteLLM's `hostAliases` and agent-egress's `HostSNI` names differ, or the
  front's or agent-egress's image differs from Traefik's `values.yaml`. It makes a person budget and a key for the
  first model, whose metadata allows a client's `mock_response`, with the master key through a port-forward to
  LiteLLM and checks that both carry those values, then
  from client Pods: in `hopin`, the front's three routes without a key get LiteLLM's 401, a GET on its two POST paths,
  `POST /v1/models` and `/key/generate` with the master key the front's own 404, a query string 400 on a GET and a
  POST, a mocked completion with the key its `mock_response` answer and a real one a 5xx; a Pod in another namespace
  or in `litellm` gets no answer from the front, and one in `hopin` or `litellm` none from LiteLLM, while each gets
  one from the API server; of its Postgres, agent-egress, the Service `kubernetes` and the first provider host, each
  name resolved, a Pod with LiteLLM's labels reaches only the first two, one with agent-egress's or the front's labels
  none, and one without labels all but agent-egress; through agent-egress a third SNI's handshake ends in the gateway
  without a dial, while the provider's ends after the gateway logged its failed dial of a resolved provider address;
  and LiteLLM's start, read from its Deployment and run with fake values in a client Pod's busybox sh,
  refuses each key and the password empty, ending in a newline, with a space or a non-ASCII byte, and the password
  outside the URL-safe alphabet, naming only the variable, while a good set reaches the exec at core limit 0. k3d
  does not prove a provider call through an open egress.
  The step "P7d cells" (`tests/backup/`) first asserts that the rest server has a ready endpoint, then shows, for each
  namespace including the backup component, that the restore test (after a `restic init` that is retried up to 30 times,
  only on a refused connection, with the refusals counted in the log)
  fails on its repository without a snapshot, and for the first namespace on an empty first key table; the master key
  makes LiteLLM's one key through a port-forward first, so its first key table holds the row the restore test needs and
  stays; a Backup yields
  one snapshot holding the custom-format dump alone, by a Job pod at a listed digest that Pod Security `restricted`
  admits; neither the Job's log nor a Snapshot object holds the repository's credentials; the restore test passes on
  the snapshot; without
  credentials the server answers 401 everywhere, a namespace's credentials reach only its own repository, and a pod in a
  namespace without one gets no answer; deleting the Kustomization `backup` keeps the claim, its repositories list again
  after the root re-creates it; and `backup:fetch` writes the latest dump at 0600 and refuses an existing file.
  The step "P9b cells" plants a backdated and a fresh row in each of the five tables through the Postgres pod and runs a
  Job made from the CronJob: it prints one deletion in each count and leaves the fresh rows and the idle customers
  with a budget or with spend, a second run prints zeros, and the first log holds no planted value; its Pod ran in a
  Namespace enforcing `restricted` with its Postgres's image.
  The part `postgres` also runs `tests/prometheus/alertmanager_mails_by_a_finished_file_and_answers_only_its_readers.sh`,
  which prints names, counts and verdicts, never a Secret value, the finished file or Alertmanager's status API: the
  StatefulSet is Ready as a non-root user on a Bound Retain claim with prune disabled, Prometheus lists one active
  Alertmanager, `amtool` accepts the finished file and routes an alert of each rule to the receiver, an init container
  built from the StatefulSet's refuses an empty smarthost, one that is not one host and one numeric port, an empty or
  malformed username, an empty recipient and an empty password, naming only the key, a synthetic alert posted from a
  Pod in `prometheus` is listed as active and makes sends that fail at the unresolvable smarthost and stay within one
  per flush of the time since it was posted (Alertmanager's counter of flushes, which retries do not raise and a firing
  rule of the cluster would raise too), and the same alert with an end resolves, a Pod in `prometheus` and one in
  `gatus` get 200 for `/-/ready` and one in a third namespace no answer, a Pod with Alertmanager's labels reaches
  neither the Service `kubernetes`, github.com nor a throwaway listener on port 587 in the pod network (each tried
  again for up to 60 seconds until closed, and then closed on three more tries, since a new Pod is judged only once
  kube-router has its rules) where one without them reaches all three, and a Pending Pod of flux-system with the port `http-prom` is a dropped target
  of `flux-controllers` with no `up` series. k3d proves neither a delivery nor the resolved mail, which Alertmanager
  attempts only after a firing mail succeeded; the PC's synthetic alert proves one firing and one resolved mail.
  The step "P9c cells", in the part `postgres`, suspends the Kustomizations `litellm` and `platform-secrets`, so that no reconcile undoes its write to the Secret `hopin`, and resumes both on every exit, removing
  its keys, person budget and Secret key: `mise run litellm:keys --plan` lists the differences between the table and two
  keys made with the master key, exits 2 and changes no row; the run sets the numbers, a second run prints 0 changes and a
  raised budget changes that field alone and keeps `budget_reset_at`; the person budget takes the table's number; a row
  without a key is named and ends 1 after the other rows were made equal, with the models and routes LiteLLM and the
  front's rules name; `litellm:key hopin` makes the row from a generated value in the Secret `hopin`, a client Pod in
  `hopin`, which reads the header line from a mounted Secret through `curl --header @file`, gets 200 from the front's `GET /v1/models` with it, a second run prints `unchanged`, and a changed
  value, one without `sk-`, a missing key and an app outside the table are refused and change no row; no output holds a
  value, the master key or the value's sha256. The job `checks` runs `tests/litellm/failed_write_names_what_is_done.sh`
  against a fake kubectl and curl: a write that fails midway stops the rest, names what was made, the one that failed,
  also when its answer was lost, and what was not made, and prints no reply body; a budget-only change sends no period;
  a table without a number for the person budget or a row's limits, an absent revision, one that changes while the table
  is read and a value with a newline are refused before any write; and the value reaches curl's stdin and no argument
  or output, a run under `bash -x` included.
  The step "Assert that a Pod whose init container removes its link holds lo alone, fails closed and leaves nothing behind
  on the node", in the part `backup`, runs `tests/no_network/pod_loses_its_link_before_the_worker_starts.sh` in Namespaces
  without a Pod Security label that it creates and deletes: its own and one fresh for each mode of the lives. `tests/no_network/pod.sh` renders the shape
  a worker Pod takes: the init container `remove-link` (the busybox of `PROBE_IMAGE`, uid 0, only `NET_ADMIN`, read-only
  root, no token or volume), which runs `remove_link.sh`, the one program, before a non-root worker at `restricted`'s
  fields. The program ends 0 with `lo` alone or once it deleted `eth0` and read `lo` alone, and non-zero on a failed
  read, another link or a failed delete, and it reads the links as plain assignments, since busybox sh ignores `set -e`
  inside a command substitution; `remove_link_branches.sh` runs it in the init container's own shell, the busybox of
  `PROBE_IMAGE` in a throwaway `docker run` without network, against a fake `ip` function for each branch (a read that
  fails, one that prints `lo` and then fails, an empty one, a failed delete among them), first in the cell. The cell proves that the worker's `ip -o link`, `ip -o addr` and routes of both families hold `lo` alone
  with 127.0.0.1/8 and ::1/128, an inspection that fails failing the cell; that it reaches neither the API's ClusterIP,
  cluster DNS, the node's address, the node's `cni0` fe80 address (scope `lo`, the only one a Pod has) nor 1.1.1.1 while a listener
  on 127.0.0.1 answers; that the same Pod without the init container holds `eth0` and a default route and reaches the
  API, DNS and the node; an exec probe, a log line, an `emptyDir` and a ConfigMap; the program run by two init containers; a
  worker that never starts without `NET_ADMIN` or beside a second link; a worker restarted in its sandbox with `lo`
  alone, and a sandbox of the Pod's own, found by its pod-name label and removed on the node through the node's `crictl stopp` and `rmp`, that is recreated with the init
  container run again; and, over twelve lives (normal, force-deleted, deleted while an init container runs, crashed),
  that the lease files of the one directory under `/var/lib/cni/networks` the cell reads from the node, the node's veth
  links, the Namespace's sandboxes and the CNI rules of `iptables-save` (read from a listing that holds kube-proxy's
  `KUBE-SERVICES`) equal their state before, each life having taken
  a new lease while it lived, with the same lives without the init container first as the control.
  `mise exec -- tests/no_network/pod_on_the_pc_holds_only_lo.sh` runs on the PC through k3s's own kubeconfig, without
  sudo: a Pod of the shape in a throwaway Namespace without a Pod Security label holds `lo` alone and reaches neither
  the API's Service, cluster DNS nor the node, a default Pod beside it holds `eth0` and reaches them, and every
  throwaway object is gone on every exit; it prints names and counts and changes nothing on the host.
- `clusters/pc/flux-system/`: Flux's own components and its sync to this repository. `gotk-components.yaml` is
  generated by `mise run flux:export` for the components `FLUX_COMPONENTS` in `mise.toml` lists, which hold no Helm reconciler
  (every chart is rendered into Git); it is not edited by hand, and `cluster` fails when a regeneration differs.
  The root Kustomization `flux-system` health-checks only its controller Deployments and its own GitRepository, so a
  failing layer reports itself; a regeneration that adds, renames or removes a controller changes those
  `healthChecks` with it, and `cluster` fails when they differ from the root's inventory.
- `clusters/pc/infrastructure.yaml`: one Flux Kustomization per directory under `infrastructure/`, each with
  `wait: true` and a `timeout`, except `postgres/`, the base `keycloak`, `litellm` and `apps/skat` include (its subdirectory `backup/` is a component `keycloak`, `litellm` and `apps/skat` include). `namespaces`, then
  `platform-secrets` (in `clusters/pc/secrets.yaml`), then `tunnel` apply in that order through `dependsOn`;
  `admission` depends on `namespaces`, every layer that runs a workload, `tunnel` included, on `admission`, and
  `keycloak` and `litellm` also on `platform-secrets`, `storage` and `k8up`, `backup` on `platform-secrets` and `storage`,
  `prometheus` on `platform-secrets` and `storage`, and `loki` on `storage`. No layer depends on `nvidia`.
- `clusters/pc/apps.yaml`: one Kustomization per directory under `apps/`, named like it and like the app's namespace, over
  `./apps/<app>`, with `wait: true` and a `timeout`, depending on `platform-secrets` and `admission`, and `skat` and `songmaker` also
  on `storage`, and `skat` also on `k8up`.
- `apps/skat/`: skat's Postgres from the base `infrastructure/postgres`, in namespace `skat` with `key-tables`
  `alembic_version tables chairs receipts` (the restore test fails on an empty first table, and `alembic_version`, which
  `skat migrate` writes, is the one a migrated database always fills), backed up like keycloak's and litellm's through
  the component `infrastructure/postgres/backup`, whose repository is `skat` on the rest server; the Namespace is in
  `infrastructure/namespaces/`, not here.
  skat's Deployment and Service: one pod with `Recreate`, its image the full app ref of a release that changes only in
  a pull request, pulled through the Secret `ghcr-pull` and started from the files of the Secret `skat` and the
  password file of the namespace's Secret `postgres`, all from `platform-secrets`; its URL names no password. An init
  container of the same image runs `skat migrate` before `skat serve`. It has no route, NetworkPolicy or tunnel line yet.
- `apps/songmaker/`: songmaker's stores, web and workers, no route or login yet: its Postgres from the base
  `infrastructure/postgres`, in namespace `songmaker` with `key-tables` `songs generations`, and `redis.yaml`, the
  queue: one StatefulSet pod at the image's redis user (uid 999, as `restricted` refuses the entrypoint's drop to it), a
  read-only root, persistence off and `/data` an `emptyDir`, so a restart empties it, a Service on 6379 and a
  NetworkPolicy that admits only the namespace's own pods. `web.yaml` is the Deployment `web`, one pod with `Recreate`,
  its image the full app ref of a release that changes only in a pull request, pulled through the Secret `ghcr-pull`;
  songmaker reads `/run/secrets` as its fixed directory, so that is one `projected` volume of the Secret `songmaker`
  and the key `password` of the Secret `postgres` as `postgres_password`. The web refuses to start without its OIDC
  settings, which it asks Keycloak for only at a sign-in, so they stand with a placeholder `oidc_client_secret`
  until the route sets Keycloak's value. The image's own start runs through `uv`; the container runs the installed
  `songmaker` directly instead. The init container `migrate` runs `alembic upgrade head` with `DATABASE_URL` and the password
  file alone. The kubelet's probe sends `Host: localhost`, which `ALLOWED_HOSTS` lists beside the public host; the
  startup probe allows 10 minutes. `/health` answers 200 while the app is degraded, so readiness proves that the process
  runs and not that its stores are healthy; that is songmaker's to change. No `AGENT__*` setting and no LiteLLM key is set,
  so the web never calls the gateway. `audio.yaml` is the claim `audiofiles` at `/app/data/audio`, Retain class and the
  prune annotation, without a k8up annotation; its size is nominal, as local-path enforces none. The web's Service
  on 8080 admits only the namespace's own pods, and its egress is open.
  `music-worker.yaml` and `scoring-worker.yaml` are the Deployments `music-worker` and `scoring-worker`, each one pod
  with `Recreate`, an image of the web's release with its own digest, started like the web but from a projected volume
  of only the files their settings read, which refuse any other: `session_secret` and `songmaker_internal_token` of the
  Secret `songmaker` and the Postgres password. Neither has a port or asks for the GPU. Each is ready by an exec probe of
  arq's health key in Redis, with a startup window of 10 minutes. The music worker writes the audio claim and a
  memory-backed `/tmp`, and its egress is open. The scoring worker reads the audio claim, runs with `HF_HUB_OFFLINE=1`
  and its image's baked models, and its NetworkPolicy admits nobody and lets it send only to cluster DNS and the
  namespace's Postgres and Redis. A Ready scoring pod does not prove that a read-only root lets it read the model cache
  or that it needs no write access to the audio claim; the first real scoring job does. The Namespace is in
  `infrastructure/namespaces/`, not here.
- `apps/hopin/`: hopin's Deployment and Service, one pod with `Recreate`, its image the full app ref of a release
  that changes only in a pull request, pulled through the Secret `ghcr-pull` and started from the
  Secret `hopin`'s files under `/run/secrets`, both from `platform-secrets`. Its Ingress routes `hopin.hallucinai.de`
  through Traefik's `web`; its NetworkPolicy admits only namespace `traefik` to hopin's port, so hopin trusts the
  forwarded addresses of the pod network in `HOPIN_TRUSTED_PROXIES` only behind that policy.
- `apps/speech-runtime/`: speech-runtime's Deployment, Service, caller table (a ConfigMap) and NetworkPolicy, which
  admits port 8080 only from the namespaces `hopin`, `presentator` and `gatus`. One pod runs on the CPU with a read-only root
  and a memory-backed `/tmp`, its image the full app ref of a release that changes only in a pull request, together
  with the caller table's keys the image knows, and pulled through the Secret `ghcr-pull` from
  `platform-secrets`. It has no Secret of its own and no route; it is ready when both models are.
- `infrastructure/namespaces/`: the Namespaces that receive Secrets from `platform-secrets`, each carrying
  `kustomize.toolkit.fluxcd.io/prune: disabled`, so neither a prune nor a revert deletes one with its Secrets.
  A Namespace removed from Git stays in the cluster; it leaves only after its Secrets left `platform-secrets`, by a
  deletion on the PC.
- `infrastructure/nvidia/`: the node's one card as `nvidia.com/gpu: 1`: the Namespace `nvidia`, the RuntimeClass `nvidia`
  with handler `nvidia` and NVIDIA's device plugin as a DaemonSet with that class, from NVIDIA's static manifest with
  the Namespace and class added, its image the vendor `nvidia-device-plugin` at a digest. The Namespace has
  no Pod Security label, as the plugin mounts the hostPath `/var/lib/kubelet/device-plugins`; nothing else runs in it,
  and the plugin drops every capability. There is no time-slicing or sharing configuration, since the card belongs to
  songmaker's music. `host/k3s/config.yaml` keeps `runtimes` disabled: k3s adds containerd's `nvidia` runtime only when
  it starts with the NVIDIA container toolkit present, and if the plugin's Pod events name a missing runtime handler the
  operator runs `sudo systemctl restart k3s` once, which does not touch Docker. `mise exec --
  tests/nvidia/restricted_pod_lists_the_card.sh` runs on the PC through k3s's own kubeconfig, without sudo: it fails
  unless the node offers `nvidia.com/gpu` 1 and a Pod in a throwaway Namespace enforcing `restricted`, at uid 1000 with the
  class and the limit, lists exactly one card; it prints counts and names, and every throwaway object is gone on every
  exit. A Pod naming the class without the limit might reach the card; the first workload that requests it decides on
  an admission rule.
- `infrastructure/storage/`: local-path-provisioner from upstream's manifest, vendored verbatim under a header naming
  its URL and sha256, and patched to one default class with `reclaimPolicy: Retain` and the path
  `/opt/local-path-provisioner/<namespace>/<claim>`, and to the provisioner and its busybox helper at digests; admission
  alone judges the helper's image, which no rendered Pod template holds. k3s's `local-storage` stays disabled.
  `local-path-storage` carries no Pod Security label, as the helper mounts a hostPath. A volume outlives its claim, but
  `k3s-uninstall.sh` deletes the volume objects: restic is the only restore path.
- `infrastructure/postgres/`: one Postgres per including namespace, a StatefulSet of 1 at uid 70 with a read-only root,
  database and user the namespace's name, its password the Secret `postgres` from `platform-secrets` (only
  `A-Z a-z 0-9 - _`, as LiteLLM takes it unescaped in a URL), its claim on the Retain class carrying the prune
  annotation, so neither a prune nor the StatefulSet's deletion takes it; a Service on 5432 that only its own namespace
  reaches; and the ConfigMap `postgres` with `check-key-tables.sh`, the one key-table check, `table-digests.sh`, the one
  digest of a table's sorted rows, which `db:load-dump --compare` and B4's check run inside the container, and the
  including layer's `key-tables`. `infrastructure/keycloak/`, `infrastructure/litellm/`, `apps/skat/` and `apps/songmaker/` include it;
  keycloak's NetworkPolicy `keycloak-egress` lets Keycloak's pods send only to cluster DNS and their Postgres.
- `infrastructure/postgres/backup/`: the component a Postgres layer includes to be backed up; `infrastructure/keycloak/`,
  `infrastructure/litellm/` and `apps/skat/` do. Its Schedule runs a weekly backup (Sunday 03:00, prune keeping
  4 weekly and 3 monthly, a monthly `check`) of the Postgres pod's `pg_dump --format=custom` into `backup-repository`,
  the URL the including layer sets in the ConfigMap `postgres`; a PodConfig gives k8up's Job pods the fields `restricted`
  requires; and the CronJob `restore-test` restores the latest snapshot into a throwaway server each month and fails
  without a snapshot or on an empty first key table. The Secret `restic` from `platform-secrets` holds the namespace's
  `username`, `password` and `repository-password`.
- `infrastructure/k8up/`: the k8up operator in `k8up-system`, `rendered.yaml` and `crds.yaml` generated by
  `mise run charts:render`, not edited by hand; `cluster` fails when a regeneration differs. `skipSnapshotSync` keeps
  k8up from writing Snapshot objects, which would record the REST repository URL with its password, and
  `skipWithoutAnnotation` makes a backup hold only what a Pod's `k8up.io/backupcommand` streams;
  a claim without k8up's backup annotation is skipped.
- `infrastructure/backup/`: the platform's one `rest-server` with `--private-repos`, in namespace `backup`: one user and
  repository per namespace, its htpasswd built by an initContainer from the Secret `rest-users` (one file per user,
  from `platform-secrets`); the user equals the namespace, since `--private-repos` admits a user only to the path of its
  own name and the repository's path is the namespace; its claim retained and never pruned. Its NetworkPolicy admits only
  the namespaces that hold a repository; a new one joins that list together with its component and `rest-users` entry. The server builds its users once, at its
  start, and a changed `rest-users` rolls nothing, so a new entry takes effect after `kubectl -n backup rollout restart
  deployment/rest-server`.
- `infrastructure/keycloak/`: Keycloak, one pod with `Recreate`, on its Postgres, its routes Traefik's file provider and
  its admin console only `keycloak:admin`; its NetworkPolicy `keycloak-ingress` admits only namespace `traefik` and
  its own. `realm.yaml` and `master.yaml` are hal's realms and the Job `config-cli` applies them with every managed
  type `no-delete`, so a person, a membership and an object only Keycloak holds stay; Flux recreates the Job when its
  template or a realm file changes, and a run that changes master's front end converges by retry. On an empty
  database Keycloak creates config-cli's client from `KC_BOOTSTRAP_ADMIN_CLIENT_ID`; a restored one keeps its own.
  `KC_HOSTNAME_ADMIN` in `keycloak.yaml` is the one owner of the admin front end, which `kustomization.yaml` copies
  to the Job. The Secret `keycloak` from `platform-secrets` holds config-cli's secret, each app client's and the agent
  client's (`client-agent-mozart`). The realm file holds the user profile (Keycloak's default with `agent_owner`,
  readable and writable only by an administrator) and the agent objects: the groups `/agents`, `/agent-adders` and
  `/agent-owners`, the scope `agent-identity`, the client `agent-mozart` and its service account's groups; who owns or
  adds an agent is console data set by `keycloak:agent-owner`. The realm sets theme `hallucinai`, which Keycloak replaces with its own until an image carries it.
- `infrastructure/litellm/`: LiteLLM, its front `litellm-front` and its egress `agent-egress`, hal's three
  configurations as ConfigMaps whose names carry their content's hash, so a change rolls the pod that reads it at
  start. LiteLLM, one pod with `Recreate` at uid 1000 with a read-only root, reads its master and provider keys from
  the Secret `litellm` and builds `DATABASE_URL` from the Secret `postgres`, both from `platform-secrets`, and does
  not start unless each key and the password is one non-empty printable line and the password URL-safe; it starts
  with core dumps off, admits only the front and sends only to cluster DNS, its Postgres and agent-egress, which its
  `hostAliases` name for the provider hosts at the fixed ClusterIP of agent-egress's Service, in k3s's default
  service CIDR. The front, a Traefik on port 4000, admits only the namespaces `hopin`, `presentator`, `songmaker` and `gatus`
  and passes only `POST /v1/chat/completions`, `POST /v1/images/generations` and `GET /v1/models` without a query
  string. agent-egress, a Traefik on 443 that admits only LiteLLM, passes TLS
  only for the SNIs of `egress-allowed.yml` and sends only to cluster DNS, so nothing the copy of hal's data holds
  leaves the cluster. The CronJob `litellm-expire` runs at 04:00 with `Forbid`, `backoffLimit` 0 and deletes in one statement,
  `expire.sql` (a ConfigMap), the daily person, tool and label rows dated more than 90 days before the database's UTC
  day, the tool rows last used before the moment 90 days before now, or created before it when never used, and the customer rows without a budget, without spend and without a
  daily row inside the period; the period is no setting, as the privacy text states it. Its `psql` is the image of the
  layer's Postgres, which a replacement copies, and it prints the five counts by name, never a row; a first `select 1`,
  tried up to 30 times a second apart inside the Pod since a fresh Pod can be refused until the NetworkPolicy controller admits
  its address, shows psql's stderr, so a failed connection names itself in the log, while the statement's stderr is discarded because
  psql quotes row values. `mise exec -- tests/litellm/key_list_count_equals_key_table_rows.sh <namespace>`
  reads the master key from the cluster's Secret: through the PC's k3s and a port-forward it prints the keys LiteLLM's `/key/list` counts and the
  key table's rows, those of the dashboard's UI session (which `/key/list` omits) and the rest, then `equal` or `DIFFERS`
  for the count against the rest; each step runs under a deadline and names itself when it fails.
  `keys.yaml` is the table of the person budget and each app's budget and parallel limit; the ConfigMap `litellm-keys`
  carries it, without a hash suffix, as no pod reads it. `mise run litellm:keys [--plan]` makes the person budget (the id
  of `max_end_user_budget_id`) and each row's key equal to it, sending only the fields that differ, so a pure budget
  change keeps the period's reset; it prints the revision Flux applied to the table it read, which it refuses when absent or changed during the read, one
  line per field with old and new, and a count; it refuses a table whose person budget or a row's budget or parallel
  limit is no number, naming the row; a row without a key is named with `run litellm:key <app>` and ends 1 after the
  rest; a failed write stops the rest and names what was made, the failed write, whose outcome is unknown when its
  answer was lost, and what was not made; `--plan` writes nothing and exits 0 with no change, 2 with changes, 1 on a
  failure. `mise run litellm:key <app>` registers key `litellm_key` of Secret `<app>` in namespace `<app>` (one printable
  line without a trailing newline, `sk-` and at least 16 characters) as the row's key, prints `unchanged` when the stored hash equals the value's,
  and refuses another value under the alias, changing nothing; a key's new value goes to `platform-secrets` first. Both
  run through `scripts/litellm_keys.sh` with a port-forward and the master key: a value and the master key travel from
  kubectl's stdout through shell variables to curl's stdin, never in an argument, a file or a child's environment, and are
  never printed; the reply of `/key/generate` goes nowhere; a failure names the step and the status, never a body. The
  rpm and tpm limits are not in the table and stay as they are.
- `infrastructure/legal/`: the legal sections and the imprint at `hallucinai.de/impressum`, nginx's unprivileged image (a vendor entry) in a
  Namespace that enforces Pod Security `restricted`, one pod with `Recreate` and a read-only root. `built/impressum.html`
  is `mise run legal:build`'s output from `frame/impressum.html`, hal's frame byte for byte, which holds no template
  field. `built/datenschutz.html` and `built/nutzungsbedingungen.html` are the other two pages, not mounted.
  `sections/<unit>/<page>.html` are hal's sections at the pinned commit, word for word: a changed sentence is the
  operator's. `stand.toml` holds one table per section path with its `date` (the Stand it prints, `D. Monat YYYY`, a
  page's the latest of its own sections) and the file's `sha256`, so an edited section keeps no old Stand; nothing of
  them is served yet. `app-texts/<key>/<page>.html` are the apps' own files byte for byte (hopin, presentator and
  songmaker; skat joins with its go-live) and `app-texts.toml` holds per app and page their `date` and `sha256` and, for an app with no
  image under `apps/<key>`, its release `tag`; an app with an image has its release from that image, so a `tag` beside
  one is refused. A bump of an app's image whose release changes its legal text carries the refreshed copy in the same pull request. `default.conf` serves only
  `/impressum` with hal's headers; both reach nginx as ConfigMaps whose names carry their hash. The Ingress routes that
  host and path through Traefik's `web`, so Traefik answers every other path with its 404, and its NetworkPolicy admits
  only namespace `traefik`. No tunnel line names the host, so hal keeps the public address. The page's stylesheet and
  fonts are not served: its references to them stay. `cluster` reads from a client Pod in `cloudflared` the page's
  checksum against the committed file, its Content-Security-Policy against `default.conf`, and 404 without nginx's
  headers for `/` and other paths, and a Pod in another namespace gets no answer from the Service.
- `infrastructure/admission/`: the vendor list and the ValidatingAdmissionPolicy `app-and-vendor-images`, whose
  binding reads the list as its parameter and denies without it. Outside kube-system and flux-system, on every create
  and every change of a Pod spec, each image of a Pod or workload kind is a listed repository with an optional tag at
  a sha256 digest or a full app ref, and in `admission` a vendor ref only. The policy `system-namespace-images`, without
  a parameter so a missing list never stops Flux, admits in flux-system only Flux's controller repositories by tag, the
  one tag-only exception, and refuses in kube-system every Pod or workload a `system:serviceaccount:flux-system:` user
  writes, so k3s's own parts there stay unjudged. Its controller list follows `FLUX_COMPONENTS`: `cluster` fails when it
  differs from the images of `gotk-components.yaml`.
- `infrastructure/cloudflared/`: the platform's own tunnel `platform`. The ConfigMap holds its lines, one per host to
  Traefik's Service and a final `http_status:404`; the Deployment `cloudflared` reads the tunnel and its credential
  only from the token file of the Secret `tunnel-token`, which `platform-secrets` applies, so no tunnel id, credential
  or Cloudflare API token is in this tree. Its image moves in a pull request started from the Dependency Dashboard that
  `renovate` keeps. cloudflared
  reads its lines once, at start, so the Deployment's template carries `checksum/config`, the sha256 of the ConfigMap's
  `config.yaml`; a changed line changes the template and rolls the pod, and `cluster` fails with the right hash when
  the two differ.
- `infrastructure/traefik/`: Traefik, the cluster's ingress for Kubernetes Ingress objects, in a Namespace that
  enforces Pod Security `restricted`. `values.yaml` is its hand-written source; `rendered.yaml` is generated by
  `mise run charts:render`, not edited by hand, and `cluster` fails when a regeneration differs. A chart or image bump
  changes the task's chart version and digest, `image.digest` and `versionOverride` together and regenerates, in a pull
  request started from the Dependency Dashboard that `renovate` keeps, and the `images:` entry of
  `infrastructure/litellm/kustomization.yaml`, the image of the Deployments `litellm-front` and `agent-egress`, with
  them. Its NetworkPolicy admits only pods of namespaces `cloudflared` and `gatus`, and only to the `web` port; every
  other sender and port, Traefik's own `traefik` and `metrics` included, is denied,
  while the node's probes pass. `web` trusts the forwarded headers of 10.42.0.0/16, the pod CIDR k3s uses because
  `host/k3s/config.yaml` sets no `cluster-cidr` (`cluster` checks it against the nodes' pod CIDRs), and carries hal's
  entrypoint hardening: alias headers deleted, paths sanitized, and every encoded path character refused with 400 by
  each route, so an unrouted host still gets 404. Its file provider holds hal's routers `auth` and `auth-root`
  verbatim: on `auth.hallucinai.de` only the realm `hallucinai`, its localization and the resources under Keycloak's
  five-character version reach Keycloak, `/` redirects to the account page, and every other path is 404.
- `infrastructure/loki/`: Loki in monolithic mode, one pod with replication factor 1 and the filesystem store, in a
  Namespace that enforces Pod Security `restricted`; gateway, canary, caches and minio are off. `values.yaml` is its
  hand-written source; `rendered.yaml` is generated by `mise run charts:render`, not edited by hand, and `cluster` fails
  when a regeneration differs. A chart or image bump changes the task's chart version and digest and `loki.image.tag` and
  `loki.image.digest` together and regenerates, in a pull request started from the Dependency Dashboard that `renovate`
  keeps. `limits_config.retention_period` of 28 days
  with the compactor's retention on is the one rule for Loki's copy of every line, which the privacy texts promise gone
  before 30 days; the compactor runs at start, so a PC that was off deletes shortly after its next start. The claim
  is on the Retain class and carries the prune annotation. Its NetworkPolicy admits only the namespaces `alloy`, `grafana`
  and `gatus`, and only to port 3100. In k3d a client Pod in a throwaway namespace `alloy` pushes a line and reads it
  back by LogQL; the configuration at `/config` has the retention on at most 28 days with a `delete_request_store`; a
  Pod in another namespace gets no answer; the claim is Bound on a Retain volume with prune disabled; the throwaway
  namespaces are gone on every exit.
- `infrastructure/alloy/`: Alloy, one pod with the image `docker.io/grafana/alloy` at a digest, in a Namespace that
  enforces Pod Security `restricted`; a plain manifest, since the chart's ClusterRole grants `secrets`, `configmaps` and
  `nodes` and no value narrows it. `config.alloy` is `discovery.kubernetes` into `loki.source.kubernetes`, which reads
  every pod's log through the API server, into `loki.process`, into `loki.write` to Loki's Service, each stream
  labelled namespace, pod and container: `loki.process` drops every line older than one hour, since a replaced pod
  re-reads what the kubelet holds and Loki deletes a chunk by its newest line, and drops the labels `job` and
  `instance`. The ConfigMap generated from it carries its content's hash in its name, so a change rolls the pod. Its
  ClusterRole grants only `get`, `list` and `watch` on `pods` and `get` on `pods/log`; its NetworkPolicy admits
  nobody to its port; its egress is open. The image moves in a pull request started from the Dependency Dashboard that
  `renovate` keeps. In k3d a Pod in namespace `hopin`
  logs a nonce that a LogQL query returns within 60 seconds with exactly those labels (Loki adds `service_name` itself);
  the Namespace enforces `restricted` and no Alloy pod mounts a host path; the render and the cluster each hold one
  ClusterRole of Alloy's with exactly those rules and no other binding of its ServiceAccount; a Pod in a throwaway
  namespace gets no answer from its port; the throwaway objects are gone on every exit.
- `infrastructure/prometheus/`: Prometheus with kube-state-metrics and Alertmanager in a Namespace that enforces Pod
  Security `restricted`, which stands in `infrastructure/namespaces/` since a Namespace never moves between
  Kustomizations; node-exporter and the pushgateway are off. `values.yaml` is its hand-written source; `rendered.yaml`
  is generated by `mise run charts:render`, not edited by hand, and `cluster` fails when a regeneration differs. A
  chart or image bump changes the task's chart version and digest and each image's tag and digest in `values.yaml`
  together and regenerates, in a pull request started from the Dependency Dashboard that `renovate` keeps. It scrapes the
  kubelet and cAdvisor at each node's port 10250, verified against the
  ServiceAccount's CA, which signs the kubelet's serving certificate in k3s, with the chart's `get` on `nodes/metrics`
  and never `nodes/proxy`, whose `get` reaches the kubelet's exec; and kube-state-metrics, Flux's controllers on
  `http-prom` and itself; kube-state-metrics' `customResourceState` makes `gotk_resource_info` for every Kustomization. Retention
  is 30 days and 7GB on one 8Gi claim of the Retain class with the prune annotation. `rules.yaml` holds the rules
  `TargetDown`, `KustomizationNotReady`, `DeploymentUnavailable`, `PodRestarting` and `DiskLow`, read from `/etc/rules`;
  `DiskLow` reads cAdvisor's `container_fs_*` at `id="/"` for the devices under `/dev` only, without loop devices
  and `/dev/shm`: a snap's read-only squashfs is always full, and what is not under `/dev` is memory-backed or an
  overlay of the same disk. The job `flux-controllers` keeps only Pods in phase Running, since a finished Pod keeps a target that
  reads down, and a static job `alertmanager` scrapes Alertmanager, so `TargetDown` covers it.
  Alertmanager, the chart's subchart and a vendor image at a digest in `image.tag`, mails one alert per mail through
  `email_configs`: one receiver `mail`, every label a grouping label, `send_resolved`, plain text, and a repeat
  interval and a `data.retention` of a year, so an alert that fires for a whole year is mailed again and none sooner. The route stands in `values.yaml`
  as a template; the Secret `alertmanager` of `platform-secrets` (keys `smarthost` as `host:port`, `username`, also the
  sender, `to` and `password`) holds the only address and provider, which an init container reads through
  `secretKeyRef` and writes, finished, into a memory-backed `emptyDir` that only Alertmanager's user reads; it refuses
  an empty or malformed value naming only its key, and the layer waits for `platform-secrets`. Its claim of 100Mi is on
  the Retain class with the prune annotation, so a restart keeps the notification log. Its NetworkPolicy `alertmanager`
  admits only the namespaces `prometheus` and `gatus` to port 9093 and sends only to cluster DNS and TCP 465 and 587
  outside the pod and service networks. A failed or lost send shows only in Alertmanager's counters and log, which
  names the smarthost and no username, recipient or password; a resolved alert is mailed only after its firing mail
  was. A changed Secret does not roll the pod, so a rotated password is read only after the next restart, and a
  SIGKILL shortly after a firing mail can mail it once more, which a SIGTERM restart did not. The NetworkPolicy admits only the namespaces `grafana`, `gatus` and its own to port 9090, and only its
  own namespace to kube-state-metrics' 8080. `cluster` runs `promtool check rules` and `promtool test rules` from the
  rendered Prometheus image on `tests/prometheus/rules_test.yml`, which proves each rule's duration, firing and
  resolving; and in k3d its ServiceAccount may get `nodes/metrics` and not `nodes/proxy`, every target is up,
  `gotk_resource_info` exists for every Kustomization, `DiskLow`'s
  expression without its threshold has a series, a Deployment at a dead image ref and a Kustomization at a missing
  path make `DeploymentUnavailable` and `KustomizationNotReady` pending, a Pod in namespace `grafana`
  gets 200 and one in another namespace no answer, the claim is Bound on a Retain volume with prune disabled, and the
  throwaway objects are gone on every exit.
- `infrastructure/gatus/`: Gatus, the status page, in a Namespace that enforces Pod Security `restricted`: one pod with
  `Recreate`, storage `memory` (a restart forgets the history; nothing is backed up) and metrics off. Its configuration
  is a generated ConfigMap whose name carries its content's hash, so a change rolls the pod. Every 60 seconds it asks
  hopin's `/health` and Keycloak's discovery of the realm `hallucinai` through Traefik's `web` with each app's Host
  header, speech-runtime's `/health`, skat's `/health`, Loki's `/ready`, Prometheus's `/-/ready`, Alertmanager's `/-/ready` and Grafana's `/api/health` directly at each
  Service, and LiteLLM's front for `GET /v1/models` without a key, which must answer 401 since Gatus holds no key. The
  NetworkPolicies of Traefik, speech-runtime, Loki, Prometheus, Alertmanager, Grafana and the front admit the namespace `gatus` on the port
  its request uses; hopin and Keycloak stay closed to it. Its own NetworkPolicy admits no sender: `mise run gatus:open` forwards `127.0.0.1` to its
  Service at a free port and prints the address, the only way to the page. A Gatus pod is a sender Traefik's `web` trusts forwarded
  headers from; it sends only the requests of its configuration. In k3d, through the address `mise run gatus:open` prints, every endpoint of the
  configuration is healthy, speech-runtime at scale 0 turns unhealthy and, restored and Ready, healthy again, and a Pod
  in another namespace gets no answer from Gatus.
- `infrastructure/grafana/`: Grafana for Loki and Prometheus, in the Namespace `grafana` the layer owns, which enforces
  Pod Security `restricted`: one pod, its image `docker.io/grafana/grafana` at a digest, and no claim, Secret, Role or
  hook. `values.yaml` is its hand-written source; `rendered.yaml` is generated by `mise run charts:render`, not edited by
  hand, and `cluster` fails when a regeneration differs. A chart or image bump changes the task's chart version and digest
  and `image.tag`, which holds the digest, together and regenerates, in a pull request started from the Dependency Dashboard
  that `renovate` keeps. Its data directory is an `emptyDir`, so a restart forgets what a person built in the page; the
  data sources Loki (no tenant header) and Prometheus are provisioned from `values.yaml` and no dashboard exists.
  The page has no login: anonymous access at the role Editor, the lowest that runs Explore, the login form and the initial admin off, since only
  `mise run grafana:open` opens it, which forwards `127.0.0.1` to the Service; so whoever can start that forward reads
  every line Loki holds. Update checks, analytics, the preinstall of plugins from grafana.com and Grafana's own alerting are off, so
  Alertmanager stays the one alert channel. Its NetworkPolicy admits only the namespace `gatus` to port 3000 and lets it send only to cluster DNS,
  Loki's 3100 and Prometheus's 9090. In k3d, through the address `mise run grafana:open` prints, `/api/health` answers
  200, both data sources report OK and answer a PromQL `up` and a LogQL query over Loki's namespace without any
  credential, which may explore and may not write a data source, and a delete request posted through its proxy to Loki
  is refused by Grafana with its own 403 (Loki's delete API stays on, so a later Grafana that forwards the POST turns the cell red). Gaps of the page's reach, accepted since the forward's port is random, on loopback and open only while the forward runs:
  Prometheus keeps its lifecycle endpoints, which its reloader needs, so the page can still make it quit or reload, a restart; a GET on Loki's `/ingester/shutdown` through the page stops new lines being stored until the pod is restarted, and no stored line is lost; the pod holds no claim and only `emptyDir`, ConfigMap and projected volumes; the layer renders no Role,
  ClusterRole or hook; a Pod in `gatus` gets 200 for `/api/health` and one in another namespace no answer; a Pod in
  Grafana's namespace reaches Loki and Prometheus and neither the Service `kubernetes` nor github.com.
- `clusters/pc/secrets.yaml`: the reference to the private repository Flux fetches secrets from on the PC; platform holds no secret.
- `host/k3s/config.yaml`: the k3s server configuration the PC and k3d share; `cluster` proves its keys from the
  cluster, except `write-kubeconfig-group` and `write-kubeconfig-mode`: k3d's image has no `docker` group, so the PC's
  host step proves those two on the PC.
- `host/disk/`: the tmpfiles line the daily user clean reads, copied to `~/.config/user-tmpfiles.d/disk.conf` by the
  `[dotfiles]` entry of `mise.toml`; the units are declared there, as mise writes systemd user units from the table.
- `mise.toml`: the tools, the k3s version and its installer's sha256, the PC's bootstrap parts (the k3s config file,
  the pod-log parts with `pod-logs-clean.timer` as a running, enabled service, which each unit file notifies,
  the inotify limits file with `systemd-sysctl` as a running service it notifies,
  and the ufw rule `k3s-cni`, with `k3s-pods` and `k3s-services` declared absent, which deletes them from a host whose mise
  state holds them) and the tasks. `mise.lock` is generated by `mise lock`, not edited by hand, and `cluster`
  fails when a regeneration differs.
- `src/opentofu/github/`: the security and merge settings of the managed fleet repositories and, in the child module
  `organization/`, the organisation's three rulesets (`main: PR only`, `quality / verdict required`, `release tags are
  immutable`, each with `prevent_destroy`, no bypass actor and enforcement `active`) and the schema of the property
  `quality_gate`, every resource also `destroy = false`; `organization.tf` holds the module call and the `import` blocks
  by id. The ruleset `quality / verdict required` reaches a repository only through `quality_gate=true`, requires the
  check `quality / verdict` pinned to GitHub Actions (`integration_id` 15368) and is quality's contract; the property's
  values are quality's merge command's and never declared, and the schema's `role` stays as set on GitHub. Two limits of
  provider 6.13.0: it cannot carry `require_extra_approval_for_unattributed_changes` (true on
  `main: PR only`, which takes effect only at a non-zero approval count), so the count stays 0 and a test holds it
  there, and a later update of that ruleset sends the field not at all, with GitHub's answer unknown; and it returns no
  default for a `true_false` property, so the default `false` is undeclared, a later update of the schema sends an empty
  one, with GitHub's answer unknown, and drift detection does not see it. `tofu test` cannot plan an import, so
  `tests/organization_rulesets.tftest.hcl` plans the module and judges its resources. `.terraform.lock.hcl` is
  generated by `tofu providers lock -platform=linux_amd64`; the job `opentofu` runs `mise run github:test`. The state
  lives at `${XDG_STATE_HOME:-~/.local/state}/platform/opentofu/github.tfstate` and the working files (lock, provider,
  kept plan `last.tfplan`) under `${XDG_CACHE_HOME:-~/.cache}/platform/opentofu/github/`, both outside the checkout.
  An imported object's state carries no `skip_destroy` until an apply writes it, so removing a block can plan a delete;
  the command refuses any such plan, which closes it for every object of the root.
- `src/legal/`: the Python project of the legal validator, standard library only, with `uv.lock` and its own tests; there
  is no root `pyproject.toml`, which would make `tests/` a judged tree. `src/legal/src/legal/section.py` is hal's
  `legal_section.py`; `check.py` is the program of `legal:check`; `pages.py` is hal's assembler of the three pages
  (`legal_pages.py` without its fingerprints, plans and records) and `build.py` the program of `legal:build`. `checks` runs `legal:test`, uploads the report
  as artifact `coverage`, which the `quality` job passes as `coverage-artifact`, and runs
  `tests/legal/legal_check_names_file_and_line_and_quotes_no_text.sh`, which reads hopin's public repository at the tag of
  the image in `apps/hopin/hopin.yaml` and fails naming the step when that fetch fails, and
  `tests/legal/app_texts_equal_their_release.sh`, which fetches each listed app's public repository at its release tag
  and fails naming the step when that fails, or when a copy's bytes, its sha256 or its date (the commit date of the file at the tag)
  differ from the list's, a page exists on one side only or a `tag` stands beside an image, and
  `tests/legal/sections_equal_hals_at_commit.sh`, which fetches hal's public repository at the commit its variable
  `hal_commit` names and fails naming the step when that fetch fails or `diff -r` finds `infrastructure/legal/sections`
  unlike hal's `legal/sections`; the pin moves when hal changes `legal/sections` before it leaves.
- `.github/workflows/renovate.yml`: the job `renovate`, daily and on dispatch, runs Renovate's image at a digest by one
  `docker run`, with the job's own token (`contents: read`, `pull-requests: read`, `issues: write`: it can write no
  branch) and `.github/renovate.json5`. The configuration holds custom regex managers over the pin forms under
  `infrastructure/`, `mise.toml`, `scripts/bootstrap_pc.sh` and the workflow's own image, and the `mise` manager for
  `mise.lock`'s tools; with `dependencyDashboardApproval` no branch or pull request is attempted, and the Dependency
  Dashboard issue is the list of pins with a newer release. A bump is a lane started from that list, with a release at
  least 7 days old unless it fixes a vulnerability; Keycloak and LiteLLM upgrades migrate data, which `cluster` does not
  prove on empty databases, so such a lane proves itself on a restored copy. A chart's line in `charts:render` is
  `<chart>:<version>@sha256:…`. `scripts/check_renovate_report.sh <report>` runs after the job and fails when the report
  holds no dependency or lacks a pair of file and digest under `infrastructure/` (`rendered.yaml` excepted), a chart
  line of `mise.toml`, `K3S_VERSION` or the workflow's own image; `tests/renovate/` drives it in `checks`. Its gaps:
  `MISE_VERSION` and `mise.lock`'s tools are watched without the check naming them, the digests in `ci.yml`'s `env`
  stand under no manager, and `--no-hooks` in a chart's render drops a bump's new hook silently, so the lane that bumps
  such a chart reads its hooks. A chart's image is watched only when its `values.yaml` states `repository` (with `registry`
  where the chart takes one), `tag` and `digest` (or the chart's `sha`) in that order, as `infrastructure/prometheus/`
  does, so a new chart states what its defaults would give. k8up's chart and CRD file, fetched from GitHub's release URL, are watched by their version in `mise.toml`'s `k8up_chart` and `k8up_crds` lines, whose sha256 a bump replaces by hand, and its image by `repository` beside a `tag` that holds `<v>@sha256:…`. Renovate logs `Unexpected downgrade detected: skipping` for
  `opentofu = "1.13"` and `yq = "4"` in `mise.toml`: `mise.lock` holds the exact patch of a prefix pin, which Renovate
  sees as newer than the prefix it would write, so a patch release inside the prefix is not listed; that is accepted,
  since the exact patch moves only when a lane refreshes `mise.lock`. Opening pull requests is not built.
- `.github/workflows/code-scanning.yml`: CodeQL through quality's `codeql.yml`.
- `quality/config.toml`: the gate's mandatory jobs; a root entry outside quality's base list is declared here.
- `sonar-project.properties`: the SonarCloud project.

## Owners

- A GitHub setting `src/opentofu/github` holds changes only through that root and the command, never by hand.
- `infrastructure/admission/image-vendors.yaml` is the one vendor list, which `images` and the admission layer read;
  platform's head owns it. An entry changes only when a vendor is added or removed, with its first or last ref, in a
  pull request; its review checks the vendor's page and that the repository is no app of ours.
- The tunnel's lines, the ConfigMap in `infrastructure/cloudflared/cloudflared.yaml`, change only in a pull request.
- quality owns the gate, its workflows and its docs; the jobs and pins here follow its README and `docs/`.
- overnightworks/platform#1 holds the plan.
