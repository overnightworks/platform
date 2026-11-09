# platform

## Commands

- Change a tool with `mise lock` after editing
  `mise.toml`, never by hand.
- helm runs only here, never on
  the PC.
- The PC calls it only through
  `bootstrap:secrets`, since a bare run talks to `~/.kube/config`.
- `mise run secrets:new-key` is the operator's: it creates the age key once in the file sops reads, `SOPS_AGE_KEY_FILE`
  if set and non-empty, else `${XDG_CONFIG_HOME:-~/.config}/sops/age/keys.txt` (mode 600 in a directory at 700), and
  prints only its recipient. The PC's key lives in that file, and
  its one copy in the operator's password manager.
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
  saying it does not answer in time; from 85 % use it first prints a `WARNING` line on stderr, and it still exits 0.
- `mise run db:load-dump [--compare] <namespace> <file>` is the platform's restore command:
  it loads a custom-format dump into the namespace's Postgres with Flux's Kustomization of that name suspended, its
  Deployments at 0 and its Flux Jobs deleted, waiting for the deletion of the Pods a ReplicaSet owns except those in phase
  `Failed` or `Succeeded` none of whose containers or init containers reports `running` (an evicted Pod stays and holds
  no session; a Pod marked `Failed` from outside can still run, and one with no readable phase is waited for), in one `pg_restore` transaction whose messages go to `<file>.load.log`
  at 0600, verifies each table `key-tables` names (all tables and their sorted rows' sha256 with `--compare`) and only
  then resumes Flux and waits for the namespace to converge. After a hard kill, `mise run db:load-dump --resume <namespace>` resumes once no other session and no
  `pg_restore` process holds the database, stops at once when the Kustomization does not exist, and verifies nothing.
  It prints names, counts and outcomes, never a row, since a dump holds keys and hashes.
- `mise run gatus:open` forwards `127.0.0.1` at a free local port kubectl chooses to the port of Gatus's Service and prints
  the address of the status page once kubectl listens, none when the forward fails, which exits non-zero; the page has no
  other way in.
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
  count its "added" line prints. It prints names, counts, key ids and `equal` or `DIFFERS`, never a row or a message of `pg_restore` or `psql`.
- `mise run bootstrap:k3s` installs k3s at `K3S_VERSION` on the PC from k3s's `install.sh` at that tag, only after its
  pinned sha256 matched, with k3s's own containerd and no `kubectl`, `crictl` or `ctr` link. `mise run bootstrap:flux` applies Flux from `clusters/pc/flux-system` through k3s's own kubeconfig and waits
  for its controllers. `mise run bootstrap:secrets` is the operator's, since it reads the age key file: through k3s's
  own kubeconfig it creates `sops-age` from that file and the deploy-key Secret `platform-secrets`, each only when
  missing, and passes the deploy key only once GitHub's meta API lists every host key it holds, a check an existing
  one passes on every run. It then requests a reconcile of the source `platform-secrets`, and only when that is not
  Ready within a minute prints the public key to add once, read-only, in GitHub's web form, requesting a reconcile
  every 30 seconds for up to 15 minutes; then it waits for the Kustomization. Its lines name each object as `<Kind>
  <name>`; the `secrets:` tasks it calls print only their refusals, under their own prefix. A refusal reads `<task>:
  <condition>; <the way back>`, except the host-key filter's `; nothing passed on`, after which `bootstrap:secrets`
  names the way back.

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

- the `cluster` job, the `bootstrap` job, the `opentofu` job, the `images` job and the
  `quality` job that calls quality's `gate.yml`.
  The cells of `cluster` and `bootstrap` live as scripts under `tests/<area>/`, named after what they prove, which the
  steps call; `ci.yml` holds the job structure, the setup and the calls.
  The setup through the reconcile's
  assertion runs in all three, and a new cell joins the part with more room.
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
  overnightworks/platform#49 lists the gaps. a new PC-only source joins that list and, since `PC_ONLY_SOURCE` in `scripts/verify_image_release.sh` holds one source, that script too; a source
  that script does not map fails the images render; Every app's Deployment, applied by its own Kustomization after its Secrets, is
  Available with one Ready pod and `Recreate` at a full app ref in a Namespace that enforces `restricted` (the step
  prints the kubelet's pull report and the runner's free disk); k3d does not
  prove the edge connection, the token mount or `/ready`. k3d does not prove the card, the runtime
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
  k3d proves neither a delivery nor the resolved mail, which Alertmanager
  attempts only after a firing mail succeeded; the PC's synthetic alert proves one firing and one resolved mail.
  `tests/no_network/pod.sh` renders the shape
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
- `gotk-components.yaml` is
  generated by `mise run flux:export` for the components `FLUX_COMPONENTS` in `mise.toml` lists, which hold no Helm reconciler
  (every chart is rendered into Git); it is not edited by hand, and `cluster` fails when a regeneration differs.
  The root Kustomization `flux-system` health-checks only its controller Deployments and its own GitRepository, so a
  failing layer reports itself; a regeneration that adds, renames or removes a controller changes those
  `healthChecks` with it, and `cluster` fails when they differ from the root's inventory.
- `namespaces`, then
  `platform-secrets` (in `clusters/pc/secrets.yaml`), then `tunnel` apply in that order through `dependsOn`;
  `admission` depends on `namespaces`, every layer that runs a workload, `tunnel` included, on `admission`, and
  `keycloak` and `litellm` also on `platform-secrets`, `storage` and `k8up`, `backup` on `platform-secrets` and `storage`,
  `prometheus` on `platform-secrets` and `storage`, and `loki` on `storage`. No layer depends on `nvidia`.
- `apps/skat/`: skat's Postgres from the base `infrastructure/postgres`, in namespace `skat` with `key-tables`
  `alembic_version tables chairs receipts` (the restore test fails on an empty first table, and `alembic_version`, which
  `skat migrate` writes, is the one a migrated database always fills), backed up like keycloak's and litellm's through
  the component `infrastructure/postgres/backup`, whose repository is `skat` on the rest server; the Namespace is in
  `infrastructure/namespaces/`, not here.
  skat's Deployment and Service: one pod with `Recreate`, its image the full app ref of a release that changes only in
  a pull request, pulled through the Secret `ghcr-pull` and started from the files of the Secret `skat` and the
  password file of the namespace's Secret `postgres`, all from `platform-secrets`; its URL names no password. Its Ingress routes `skat.hallucinai.de`
  through Traefik's `web`; its NetworkPolicy admits only namespace `traefik` to its port, so skat trusts the forwarded
  addresses of the pod network in `SKAT_TRUSTED_PROXIES` only behind that policy, and `cloudflared` carries its line.
- `apps/songmaker/`: songmaker's stores, web and workers, no route or login yet: its Postgres from the base
  `infrastructure/postgres`, in namespace `songmaker` with `key-tables` `alembic_version songs generations`, backed up through the component `infrastructure/postgres/backup`
  with the repository `songmaker` on the rest server, and `redis.yaml`, the
  queue: one StatefulSet pod at the image's redis user (uid 999, as `restricted` refuses the entrypoint's drop to it), a
  read-only root, persistence off and `/data` an `emptyDir`, so a restart empties it, a Service on 6379 and a
  NetworkPolicy that admits only the namespace's own pods. `web.yaml` is the Deployment `web`, one pod with `Recreate`,
  its image the full app ref of a release that changes only in a pull request, pulled through the Secret `ghcr-pull`;
  songmaker reads `/run/secrets` as its fixed directory, so that is one `projected` volume of the Secret `songmaker`
  and the key `password` of the Secret `postgres` as `postgres_password`. The web refuses to start without its OIDC
  settings, which it asks Keycloak for only at a sign-in, so they stand with a placeholder `oidc_client_secret`
  until the route sets Keycloak's value. `/health` answers 200 while the app is degraded, so readiness proves that the process
  runs and not that its stores are healthy; that is songmaker's to change. The web's Service
  on 8080 admits only the namespace's own pods, and its egress is open.
  The scoring worker reads the audio claim, runs with `HF_HUB_OFFLINE=1`
  and its image's baked models, and its NetworkPolicy admits nobody and lets it send only to cluster DNS and the
  namespace's Postgres and Redis. A Ready scoring pod does not prove that a read-only root lets it read the model cache
  or that it needs no write access to the audio claim; the first real scoring job does.
- `apps/hopin/`: hopin's Deployment and Service, one pod with `Recreate`, its image the full app ref of a release
  that changes only in a pull request, pulled through the Secret `ghcr-pull` and started from the
  Secret `hopin`'s files under `/run/secrets`, both from `platform-secrets`. Its Ingress routes `hopin.hallucinai.de`
  through Traefik's `web`; its NetworkPolicy admits only namespace `traefik` to hopin's port, so hopin trusts the
  forwarded addresses of the pod network in `HOPIN_TRUSTED_PROXIES` only behind that policy.
- `apps/speech-runtime/`: speech-runtime's Deployment, Service, caller table (a ConfigMap) and NetworkPolicy, which
  admits port 8080 only from the namespaces `hopin`, `presentator` and `gatus`. One pod runs on the CPU with a read-only root
  and a memory-backed `/tmp`, its image the full app ref of a release that changes only in a pull request, together
  with the caller table's keys the image knows, and pulled through the Secret `ghcr-pull` from
  `platform-secrets`.
- `infrastructure/namespaces/`: the Namespaces that receive Secrets from `platform-secrets`, each carrying
  `kustomize.toolkit.fluxcd.io/prune: disabled`, so neither a prune nor a revert deletes one with its Secrets.
  A Namespace removed from Git stays in the cluster; it leaves only after its Secrets left `platform-secrets`, by a
  deletion on the PC.
- The Namespace has
  no Pod Security label, as the plugin mounts the hostPath `/var/lib/kubelet/device-plugins`; nothing else runs in it,
  and the plugin drops every capability. There is no time-slicing or sharing configuration, since the card belongs to
  songmaker's music. `host/k3s/config.yaml` keeps `runtimes` disabled: k3s adds containerd's `nvidia` runtime only when
  it starts with the NVIDIA container toolkit present, and if the plugin's Pod events name a missing runtime handler the
  operator runs `sudo systemctl restart k3s` once, which does not touch Docker. A Pod naming the class without the limit might reach the card; the first workload that requests it decides on
  an admission rule.
- `infrastructure/storage/`: local-path-provisioner from upstream's manifest, vendored verbatim under a header naming
  its URL and sha256, and patched to one default class with `reclaimPolicy: Retain` and the path
  `/opt/local-path-provisioner/<namespace>/<claim>`, and to the provisioner and its busybox helper at digests; admission
  alone judges the helper's image, which no rendered Pod template holds.
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
- Its Schedule runs a weekly backup (Sunday 03:00, prune keeping
  4 weekly and 3 monthly, a monthly `check`) of `pg_dump --format=custom` into `backup-repository`,
  the URL the including layer sets in the ConfigMap `postgres`; a PodConfig gives k8up's Job pods the fields `restricted`
  requires; and the CronJob `restore-test` restores the latest snapshot into a throwaway server each month, on the 1st at
  05:00 UTC, bounded to an hour, and fails without a snapshot or on an empty first key table.
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
  template or a realm file changes, and a run that changes master's front end converges by retry. The realm file declares Keycloak's built-in client scopes `profile` and `email`
  with all 16 mappers as Keycloak 26.8.1 ships them, since config-cli removes a mapper of a declared scope that the file
  omits, and with `access.token.claim` and `introspection.token.claim` off on each: no access token carries a person's name or
  e-mail address, which no app reads there and the speech service has no use for, while ID token and userinfo keep them.
  A Keycloak bump compares the declared `profile` and `email` scopes with the new
  version's own, since config-cli otherwise overwrites them with the old copy. The realm file holds the user profile (Keycloak's default with `agent_owner`,
  readable and writable only by an administrator) and the agent objects: the groups `/agents`, `/agent-adders` and
  `/agent-owners`, the scope `agent-identity`, the client `agent-mozart` and its service account's groups; who owns or
  adds an agent is console data set by `keycloak:agent-owner`.
- LiteLLM, one pod with `Recreate` at uid 1000 with a read-only root, reads its master and provider keys from
  the Secret `litellm` and builds `DATABASE_URL` from the Secret `postgres`, both from `platform-secrets`, and does
  not start unless each key and the password is one non-empty printable line and the password URL-safe; it starts
  with core dumps off, admits only the front and sends only to cluster DNS, its Postgres and agent-egress, which its
  `hostAliases` name for the provider hosts at the fixed ClusterIP of agent-egress's Service, in k3s's default
  service CIDR. The front, a Traefik on port 4000, admits only the namespaces `hopin`, `presentator`, `songmaker` and `gatus`
  and passes only `POST /v1/chat/completions`, `POST /v1/images/generations` and `GET /v1/models` without a query
  string. agent-egress, a Traefik on 443 that admits only LiteLLM, passes TLS
  only for the SNIs of `egress-allowed.yml` and sends only to cluster DNS, so nothing the copy of hal's data holds
  leaves the cluster. The CronJob `litellm-expire` runs at 04:00 UTC with `Forbid`, `backoffLimit` 0 and deletes in one statement,
  `expire.sql` (a ConfigMap), the daily person, tool and label rows dated more than 90 days before the database's UTC
  day, the tool rows last used before the moment 90 days before now, or created before it when never used, and the customer rows without a budget, without spend and without a
  daily row inside the period; the period is no setting, as the privacy text states it.
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
  never printed; the reply of `/key/generate` goes nowhere; a failure names the step and the status, never a body.
  `mise run litellm:admin <username>` is the unlimited AI budget of one admin, through the same script: it reads the person
  as `keycloak:agent-owner` does (`scripts/keycloak_kcadm.sh`, which both tasks source, and whose kcadm diagnostics this
  command discards, since they can quote a URL with the person's id), the realm's issuer from the public discovery
  document and the group `/services/litellm/admin`, and LiteLLM's budget `litellm-admin` and customer row, all before
  the first write; it then writes and reads back, in this order, the budget (no limit, `1mo`, created or corrected), the membership and the
  customer row, which is `/customer/new` under agent-runtime's `person_fingerprint` of issuer and person id or
  `/customer/update` of `budget_id` alone, so spend and other fields stay. Removing an admin is
  not built.
- `sections/<unit>/<page>.html` are hal's sections at the pinned commit, word for word: a changed sentence is the
  operator's. A bump of an app's image whose release changes its legal text carries the refreshed copy in the same pull request. The Ingress routes the host `hallucinai.de`
  through Traefik's `web` for `/impressum`, `/datenschutz`, `/nutzungsbedingungen` and `/favicon.ico` (each `Exact`) and
  the prefix `/_rechtliches/`, the five paths hal's catalog leaves to the origin, so Traefik answers every other path with
  its 404, and its NetworkPolicy admits only namespace `traefik`.
- Outside kube-system and flux-system, on every create
  and every change of a Pod spec, each image of a Pod or workload kind is a listed repository with an optional tag at
  a sha256 digest or a full app ref, and in `admission` a vendor ref only. The policy `system-namespace-images`, without
  a parameter so a missing list never stops Flux, admits in flux-system only Flux's controller repositories by tag, the
  one tag-only exception, and refuses in kube-system every Pod or workload a `system:serviceaccount:flux-system:` user
  writes, so k3s's own parts there stay unjudged.
- `infrastructure/cloudflared/`: the platform's own tunnel `platform`. The ConfigMap holds its lines, one per host to
  Traefik's Service and a final `http_status:404`; the Deployment `cloudflared` reads the tunnel and its credential
  only from the token file of the Secret `tunnel-token`, which `platform-secrets` applies, so no tunnel id, credential
  or Cloudflare API token is in this tree. Its image moves in a pull request started from the Dependency Dashboard that
  `renovate` keeps. cloudflared
  reads its lines once, at start, so the Deployment's template carries `checksum/config`, the sha256 of the ConfigMap's
  `config.yaml`; a changed line changes the template and rolls the pod, and `cluster` fails with the right hash when
  the two differ.
- `values.yaml` is its hand-written source; `rendered.yaml` is generated by
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
- `values.yaml` is its
  hand-written source; `rendered.yaml` is generated by `mise run charts:render`, not edited by hand, and `cluster` fails
  when a regeneration differs. A chart or image bump changes the task's chart version and digest and `loki.image.tag` and
  `loki.image.digest` together and regenerates, in a pull request started from the Dependency Dashboard that `renovate`
  keeps. `limits_config.retention_period` of 28 days
  with the compactor's retention on is the one rule for Loki's copy of every line, which the privacy texts promise gone
  before 30 days; the compactor runs at start, so a PC that was off deletes shortly after its next start. Its NetworkPolicy admits only the namespaces `alloy`, `grafana`
  and `gatus`, and only to port 3100.
- `infrastructure/alloy/`: Alloy, one pod with the image `docker.io/grafana/alloy` at a digest, in a Namespace that
  enforces Pod Security `restricted`; a plain manifest, since the chart's ClusterRole grants `secrets`, `configmaps` and
  `nodes` and no value narrows it. `config.alloy` is `discovery.kubernetes` into `loki.source.kubernetes`, which reads
  every pod's log through the API server, into `loki.process`, into `loki.write` to Loki's Service, each stream
  labelled namespace, pod and container: `loki.process` drops every line older than one hour, since a replaced pod
  re-reads what the kubelet holds and Loki deletes a chunk by its newest line, and drops the labels `job` and
  `instance`. Its
  ClusterRole grants only `get`, `list` and `watch` on `pods` and `get` on `pods/log`; its NetworkPolicy admits
  nobody to its port; its egress is open. The image moves in a pull request started from the Dependency Dashboard that
  `renovate` keeps.
- `infrastructure/prometheus/`: Prometheus with kube-state-metrics and Alertmanager in a Namespace that enforces Pod
  Security `restricted`, which stands in `infrastructure/namespaces/` since a Namespace never moves between
  Kustomizations; node-exporter and the pushgateway are off. `values.yaml` is its hand-written source; `rendered.yaml`
  is generated by `mise run charts:render`, not edited by hand, and `cluster` fails when a regeneration differs. A
  chart or image bump changes the task's chart version and digest and each image's tag and digest in `values.yaml`
  together and regenerates, in a pull request started from the Dependency Dashboard that `renovate` keeps. It scrapes the
  kubelet and cAdvisor at each node's port 10250, verified against the
  ServiceAccount's CA, which signs the kubelet's serving certificate in k3s, with the chart's `get` on `nodes/metrics`
  and never `nodes/proxy`, whose `get` reaches the kubelet's exec; and kube-state-metrics, Flux's controllers on
  `http-prom` and itself; kube-state-metrics' `customResourceState` makes `gotk_resource_info` for every Kustomization and, from each k8up Schedule's `creationTimestamp`, `k8up_schedule_created`
  with its `namespace` and `name` (the chart's role gets `list` and `watch` on `schedules` of `k8up.io`, and still lists no Secret). Retention
  is 30 days and 7GB on one 8Gi claim of the Retain class with the prune annotation. It does not see
  a suspended CronJob, which has no next time, k8up's Schedules, which are no CronJobs, or a Job that starts and fails;
  the hour is the grace for the controller's catch-up after a boot, and no CronJob sets `startingDeadlineSeconds`, since a
  skipped monthly run would then alert for most of a month. Both CronJobs set `timeZone: UTC`: kube-state-metrics reads a
  schedule without a zone in its own zone and the controller in the host's, which differ on the PC, and the cell fails when
  any CronJob reports the zone `local`;
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
  an empty or malformed value naming only its key, and the layer waits for `platform-secrets`. Its NetworkPolicy `alertmanager`
  admits only the namespaces `prometheus` and `gatus` to port 9093 and sends only to cluster DNS and TCP 465 and 587
  outside the pod and service networks. A failed or lost send shows only in Alertmanager's counters and log, which
  names the smarthost and no username, recipient or password; a resolved alert is mailed only after its firing mail
  was. A changed Secret does not roll the pod, so a rotated password is read only after the next restart, and a
  SIGKILL shortly after a firing mail can mail it once more, which a SIGTERM restart did not. The NetworkPolicy admits only the namespaces `grafana`, `gatus` and its own to port 9090, and only its
  own namespace to kube-state-metrics' 8080.
- The
  NetworkPolicies of Traefik, speech-runtime, Loki, Prometheus, Alertmanager, Grafana and the front admit the namespace `gatus` on the port
  its request uses; hopin, skat and Keycloak stay closed to it. Its own NetworkPolicy admits no sender: `mise run gatus:open` forwards `127.0.0.1` to its
  Service at a free port and prints the address, the only way to the page. A Gatus pod is a sender Traefik's `web` trusts forwarded
  headers from; it sends only the requests of its configuration.
- `infrastructure/grafana/`: Grafana for Loki and Prometheus, in the Namespace `grafana` the layer owns, which enforces
  Pod Security `restricted`: one pod, its image `docker.io/grafana/grafana` at a digest, and no claim, Secret, Role or
  hook. `values.yaml` is its hand-written source; `rendered.yaml` is generated by `mise run charts:render`, not edited by
  hand, and `cluster` fails when a regeneration differs. A chart or image bump changes the task's chart version and digest
  and `image.tag`, which holds the digest, together and regenerates, in a pull request started from the Dependency Dashboard
  that `renovate` keeps.
  The page has no login: anonymous access at the role Editor, the lowest that runs Explore, the login form and the initial admin off, since only
  `mise run grafana:open` opens it, which forwards `127.0.0.1` to the Service; so whoever can start that forward reads
  every line Loki holds. Update checks, analytics, the preinstall of plugins from grafana.com and Grafana's own alerting are off, so
  Alertmanager stays the one alert channel. Its NetworkPolicy admits only the namespace `gatus` to port 3000 and lets it send only to cluster DNS,
  Loki's 3100 and Prometheus's 9090. Gaps of the page's reach, accepted since the forward's port is random, on loopback and open only while the forward runs:
  Prometheus keeps its lifecycle endpoints, which its reloader needs, so the page can still make it quit or reload, a restart; a GET on Loki's `/ingester/shutdown` through the page stops new lines being stored until the pod is restarted, and no stored line is lost; the pod holds no claim and only `emptyDir`, ConfigMap and projected volumes; the layer renders no Role,
  ClusterRole or hook; a Pod in `gatus` gets 200 for `/api/health` and one in another namespace no answer; a Pod in
  Grafana's namespace reaches Loki and Prometheus and neither the Service `kubernetes` nor github.com.
- `clusters/pc/secrets.yaml`: the reference to the private repository Flux fetches secrets from on the PC; platform holds no secret.
- `mise.lock` is generated by `mise lock`, not edited by hand, and `cluster`
  fails when a regeneration differs.
- Two limits of
  provider 6.13.0: it cannot carry `require_extra_approval_for_unattributed_changes` (true on
  `main: PR only`, which takes effect only at a non-zero approval count), so the count stays 0 and a test holds it
  there, and a later update of that ruleset sends the field not at all, with GitHub's answer unknown; and it returns no
  default for a `true_false` property, so the default `false` is undeclared, a later update of the schema sends an empty
  one, with GitHub's answer unknown, and drift detection does not see it. `.terraform.lock.hcl` is
  generated by `tofu providers lock -platform=linux_amd64`; the job `opentofu` runs `mise run github:test`.
- `src/legal/`: the Python project of the legal validator, standard library only, with `uv.lock` and its own tests; there
  is no root `pyproject.toml`, which would make `tests/` a judged tree.
- `.github/workflows/renovate.yml`: the job `renovate`, daily and on dispatch, runs Renovate's image at a digest by one
  `docker run`, with the job's own token (`contents: read`, `pull-requests: read`, `issues: write`: it can write no
  branch) and `.github/renovate.json5`. A bump is a lane started from that list, with a release at
  least 7 days old unless it fixes a vulnerability; Keycloak and LiteLLM upgrades migrate data, which `cluster` does not
  prove on empty databases, so such a lane proves itself on a restored copy. A chart's line in `charts:render` is
  `<chart>:<version>@sha256:…`. Its gaps:
  `MISE_VERSION` and `mise.lock`'s tools are watched without the check naming them, the digests in `ci.yml`'s `env`
  stand under no manager, and `--no-hooks` in a chart's render drops a bump's new hook silently, so the lane that bumps
  such a chart reads its hooks. A chart's image is watched only when its `values.yaml` states `repository` (with `registry`
  where the chart takes one), `tag` and `digest` (or the chart's `sha`) in that order, as `infrastructure/prometheus/`
  does, so a new chart states what its defaults would give. k8up's chart and CRD file, fetched from GitHub's release URL, are watched by their version in `mise.toml`'s `k8up_chart` and `k8up_crds` lines, whose sha256 a bump replaces by hand, and its image by `repository` beside a `tag` that holds `<v>@sha256:…`. Renovate logs `Unexpected downgrade detected: skipping` for
  `opentofu = "1.13"` and `yq = "4"` in `mise.toml`: `mise.lock` holds the exact patch of a prefix pin, which Renovate
  sees as newer than the prefix it would write, so a patch release inside the prefix is not listed; that is accepted,
  since the exact patch moves only when a lane refreshes `mise.lock`. Opening pull requests is not built.

## Owners

- A GitHub setting `src/opentofu/github` holds changes only through that root and the command, never by hand.
- `infrastructure/admission/image-vendors.yaml` is the one vendor list, which `images` and the admission layer read;
  platform's head owns it. An entry changes only when a vendor is added or removed, with its first or last ref, in a
  pull request; its review checks the vendor's page and that the repository is no app of ours.
- The tunnel's lines, the ConfigMap in `infrastructure/cloudflared/cloudflared.yaml`, change only in a pull request.
- quality owns the gate, its workflows and its docs; the jobs and pins here follow its README and `docs/`.

## Documents

- `docs/github-settings.md`: read when changing what `src/opentofu/github` declares or how a change reaches GitHub.
