# Commands

This reference holds ruled sentences.

It is for the operator who runs a task of this repository or a proof on the PC, and for the agent who changes one:
what each does, refuses and prints. Each sentence ends with its ID, and a test that proves the sentence cites the ID
in one comment line that starts with `# Proves docs/commands.md`.

## `scripts/bootstrap_pc.sh --only tools`

`scripts/bootstrap_pc.sh --only tools` installs the mise its header pins, checks its sha256 and installs the tools
`mise.lock` holds; a tool without a lock entry is an error (TOOLS-1). A fresh machine first needs `git`, `curl` and
`sha256sum` (on Ubuntu, `apt-get install ca-certificates curl git`); the script names the first one missing and
installs nothing (TOOLS-2).

## `flux:export`

`mise run flux:export` regenerates `clusters/pc/flux-system/gotk-components.yaml` from the locked flux2 (FLUX-1).

## `charts:render`

`mise run charts:render` regenerates each `infrastructure/<component>/rendered.yaml` with the locked helm from the
chart the task pins (traefik and loki by digest, k8up by the sha256 of its tgz), the `values.yaml` beside it and
`K3S_VERSION`, without CRDs and tests, and `infrastructure/k8up/crds.yaml` from k8up's release asset at its pinned
sha256 (CHARTS-1). It writes nothing for a chart that cannot be fetched or rendered, whose pin does not match or whose
render holds a helm hook, which it names; each output is replaced alone, so such a failure can follow an earlier
chart's written render (k8up's chart is rendered with `--no-hooks`: its one hook is a cleanup Job for Helm upgrades)
(CHARTS-2).

## `secrets:age-secret`

`mise run secrets:age-secret <key file>` creates the Secret `sops-age` in flux-system, the age key Flux decrypts
`platform-secrets` with, from the given file; it has no default path (AGE-1).

## `secrets:new-key`

`mise run secrets:new-key` creates the age key once in the file sops reads, `SOPS_AGE_KEY_FILE` if set and non-empty,
else `${XDG_CONFIG_HOME:-~/.config}/sops/age/keys.txt` (mode 600 in a directory at 700), and prints only its recipient
(NEWKEY-1). It refuses, changing nothing, an existing key file, an existing directory (or a link's target) at another
mode, a key directory a file blocks and a `<key file>.drill` (NEWKEY-2). The PC's key lives in that file, and its one
copy in the operator's password manager (NEWKEY-3).

## `scripts/apply_github_settings.sh`

`scripts/apply_github_settings.sh` plans the GitHub settings `src/opentofu/github` declares, with the operator's own
gh login, on any commit and without writing state (exit 0 no change, 2 changes, 1 failure) (GHSET-1). `--apply`
applies that run's own plan, only from a clean `origin/main` (GHSET-2). A plan with a `delete` action, a replacement
included, fails with exit 1 on both runs, names each address and applies nothing; a `removed` block with
`lifecycle { destroy = false }` plans a forget (GHSET-3).

## `github:test`

`mise run github:test` checks that root: format, init against the committed lock, validate, the mocked tests and
`tests/github/plan_with_a_delete_is_refused.sh`, which drives the script against a fake tofu and gh (GHTEST-1).

## `check:pod-logs`

`mise run check:pod-logs` runs through sudo: it runs the installed `check-pod-logs`, which names every pod log file
past its bound and a daily clean that has not run within 25 hours or failed, by file names and times only, and fails
on any; it passes with no pod logs yet while `/var/log/pods` does not exist, and fails when it cannot list the
directory (PODLOGS-1). It reads the clean's last start (the later of the service's and the timer's last trigger, which
a reboot keeps) and result, whoever started it, so a failed or never-run clean keeps failing the check until
`sudo systemctl start pod-logs-clean.service` has run, then `mise run check:pod-logs` (PODLOGS-2). `check-pod-logs`
never reads Loki's copy of the lines, whose bound `infrastructure/loki/` sets; the `cluster` cell on Loki's running
configuration is the only check of it (PODLOGS-3).

## `check:secrets-expiry`

`mise run check:secrets-expiry` runs on the PC through k3s's own kubeconfig, without sudo, and reads only metadata: it
names, by namespace, name and date, every Secret whose annotation `platform.hallucinai.de/expires-on: YYYY-MM-DD` lies
within 30 days or in the past, and each whose value is no such date, and fails on any or when the listing fails; it
passes with no annotated Secret (EXPIRY-1).

## `backup:fetch`

`mise run backup:fetch <namespace> <file>` writes the latest dump of the namespace's k8up repository to a new file at
0600, through a Pod built from the restore test's init container, the file it refuses to overwrite;
`db:load-dump <namespace> <file>` then restores it (FETCH-1). It prints only names and sizes, since a dump holds keys
and hashes (FETCH-2).

## `disk`

`mise run disk` runs without sudo and prints what fills the disk of the home directory by size and name (named
directories of `$HOME`, the rest of `$HOME`, and what lies outside it, which is Docker's `/var/lib/docker` and the
system, since only root reads that), then Docker's own count when the daemon answers within 2 minutes, else one line
saying it does not answer in time; from 85 % use it first prints a `WARNING` line on stderr, and it still exits 0
(DISK-1). A directory du cannot read marks its row incomplete and prints the remainders as `?`, never as a number
(DISK-2).

## `db:load-dump`

`mise run db:load-dump [--compare] <namespace> <file>` is the platform's restore command: it loads a custom-format
dump into the namespace's Postgres with Flux's Kustomization of that name suspended, its Deployments at 0 and its Flux
Jobs deleted, waiting for the deletion of the Pods a ReplicaSet owns except those in phase `Failed` or `Succeeded`
none of whose containers or init containers reports `running` (an evicted Pod stays and holds no session; a Pod marked
`Failed` from outside can still run, and one with no readable phase is waited for), in one `pg_restore` transaction
whose messages go to `<file>.load.log` at 0600, verifies each table `key-tables` names (all tables and their sorted
rows' sha256 with `--compare`) and only then resumes Flux and waits for the namespace to converge (LOAD-1). It refuses
a suspended Kustomization (LOAD-2). Another session that holds the database before the load, a database it cannot read
then, or an INT before the load costs at most one wait of 2 minutes and one line, loads nothing and resumes (LOAD-3).
A restore that fails or is interrupted reports the data unchanged and resumes once no session and no `pg_restore`
process remains in the database's Postgres, it holds no materialized view or extension table, whose rows `pg_dump`
does not write, and the sha256 of its whole `pg_dump` equals the one taken before the load (LOAD-4). Otherwise, a TERM
during that check included, it reports the outcome unknown and, like a differing load or one that ends before the
comparison did, stays suspended with its writers at 0, naming `--resume` (LOAD-5). After a hard kill,
`mise run db:load-dump --resume <namespace>` resumes once no other session and no `pg_restore` process holds the
database, stops at once when the Kustomization does not exist, and verifies nothing (LOAD-6). It prints names, counts
and outcomes, never a row, since a dump holds keys and hashes (LOAD-7).

## `legal:check`

`mise run legal:check <key> <dir>` checks an app's `<dir>/legal/datenschutz.html` and, if present,
`<dir>/legal/nutzungsbedingungen.html` with the section validator of `src/legal/` (grammar and format in
`docs/legal-sections.md`): it prints `legal:check: <key> valid: <pages>` and exits 0, or prints
`legal: <file>: line N: <rule>`, never the text, and exits non-zero (LCHECK-1). It refuses a link or directory in
place of a file, a missing `datenschutz.html` and a `<dir>` that is none; a relative `<dir>` is read from this
checkout; it writes nothing (LCHECK-2). The `zone` is the host of the Ingress in `infrastructure/legal/legal.yaml`
(LCHECK-3).

## `legal:test`

`mise run legal:test` runs the project's tests with branch coverage at 100 % and writes `src/legal/coverage.xml`
(LTEST-1).

## `legal:build`

`mise run legal:build` reads, from this checkout's root, the frame of `infrastructure/legal/frame/`, the sections of
`infrastructure/legal/sections/` and their `stand.toml`, the app texts of `infrastructure/legal/app-texts/` and their
list `app-texts.toml`, builds the three pages with `src/legal/src/legal/pages.py`, which checks their ids and links,
and writes all three to `infrastructure/legal/built/`; it needs no network, prints `legal:build: wrote <file>` per
page and exits 0, or prints `legal: <file> is missing; the frame is required` (or the failed check's line, which names
a directory under `sections/` that is neither `allgemein` nor one of `keycloak`, `litellm` or `speech-runtime`, a
section with no `stand.toml` entry, an entry without a file or a section whose sha256 differs from its entry, printing
the file's, and the same for an app text and `app-texts.toml`, an app with no `datenschutz` and an app key that is
`allgemein` or a service's) and exits non-zero, writing nothing (LBUILD-1). It reads the `zone` as `legal:check` does
(LBUILD-2). All three run through `uv` (locked in `mise.toml`), which fetches Python 3.14 on first use and keeps its
environment under `~/.cache/platform/legal` (LBUILD-3).

## `keycloak:admin`

`mise run keycloak:admin` forwards `127.0.0.1` at the port of Keycloak's `KC_HOSTNAME_ADMIN` to Keycloak's Service and
prints the console's address, to open in a private window, since a browser keeps cookies per host and hal's console
answers on another port of `localhost` (KCADMIN-1).

## `gatus:open`

`mise run gatus:open` forwards `127.0.0.1` at a free local port kubectl chooses to the port of Gatus's Service and
prints the address of the status page once kubectl listens, none when the forward fails, which exits non-zero; the
page has no other way in (GATUS-1).

## `grafana:open`

`mise run grafana:open` does the same for Grafana's Service, through the one hidden task `page:forward` that
`gatus:open` shares (GRAFANA-1).

## `keycloak:agent-owner`

`mise run keycloak:agent-owner [--adder] <client> <username>` runs through kcadm in Keycloak's container, signed in as
config-cli, it sets the service account's `agent_owner` of a service-account client of `realm.yaml` with
`agent-identity` among its default scopes to that one person's id, keeping the account's other attributes, and adds
the person to `/agent-owners`, with `--adder` also to `/agent-adders` (OWNER-1). It refuses another client, a username
that no person carries, which Keycloak's user search finds without service accounts and matches by the lowercase
username, so a service account's name in any case is refused with the rest, and an `agent_owner` naming someone else;
before its first write a refusal ends in `nothing changed`, after one it names what was written or may have been and
says that running it again completes it (OWNER-2). It reads everything back, prints names and member counts and prints
`nothing changed` on a second run (OWNER-3).

## `keycloak:move-group`

`mise run keycloak:move-group [--delete-old] <file>` is for the rename of the AI group: it creates the new file at
0600 (and refuses one that exists), dumps `keycloak` into it with the messages of `pg_dump` and `pg_restore --list` in
`<file>.dump.log` at 0600, whose path and line count it prints, deletes only its own file after a failed dump, adds
every member of `/services/agent-service/api` to `/services/litellm` through kcadm in Keycloak's container, signed in
as config-cli, verifies the old members are a subset and prints the two groups' member counts; only `--delete-old`
deletes the old group (MOVE-1). `db:load-dump keycloak <file>` rolls it back (MOVE-2).

## `bootstrap:k3s`

`mise run bootstrap:k3s` installs k3s at `K3S_VERSION` on the PC from k3s's `install.sh` at that tag, only after its
pinned sha256 matched, with k3s's own containerd and no `kubectl`, `crictl` or `ctr` link (BK3S-1). With that version
installed, it restarts `k3s.service` when `/etc/rancher/k3s/config.yaml` changed after k3s's last start and else
changes nothing; it stops when that file is missing or differs from `host/k3s/config.yaml` (BK3S-2). Then it waits for
the node (BK3S-3).

## `bootstrap:flux`

`mise run bootstrap:flux` applies Flux from `clusters/pc/flux-system` through k3s's own kubeconfig and waits for its
controllers (BFLUX-1).

## `bootstrap:secrets`

`mise run bootstrap:secrets` reads the age key file: through k3s's own kubeconfig it creates `sops-age` from that file
and the deploy-key Secret `platform-secrets`, each only when missing, and passes the deploy key only once GitHub's
meta API lists every host key it holds, a check an existing one passes on every run (BSEC-1). It then requests a
reconcile of the source `platform-secrets`, and only when that is not Ready within a minute prints the public key to
add once, read-only, in GitHub's web form, requesting a reconcile every 30 seconds for up to 15 minutes; then it waits
for the Kustomization (BSEC-2). Its lines name each object as `<Kind> <name>`; the `secrets:` tasks it calls print
only their refusals, under their own prefix (BSEC-3). A refusal reads `<task>: <condition>; <the way back>`, except
the host-key filter's `; nothing passed on`, after which `bootstrap:secrets` names the way back (BSEC-4).

## `bootstrap`

`mise run bootstrap` runs the three in order, as a full `mise bootstrap` does after its declarative parts (BOOT-1).

## `litellm:keys`

`keys.yaml` is the table of the person budget and each app's budget and parallel limit; the ConfigMap `litellm-keys`
carries it, without a hash suffix, as no pod reads it (KEYS-1). `mise run litellm:keys [--plan]` makes the person
budget (the id of `max_end_user_budget_id`) and each row's key equal to it, sending only the fields that differ, so a
pure budget change keeps the period's reset; it prints the revision Flux applied to the table it read, which it
refuses when absent or changed during the read, one line per field with old and new, and a count; it refuses a table
whose person budget or a row's budget or parallel limit is no number, naming the row; a row without a key is named
with `run litellm:key <app>` and ends 1 after the rest; a failed write stops the rest and names what was made, the
failed write, whose outcome is unknown when its answer was lost, and what was not made; `--plan` writes nothing and
exits 0 with no change, 2 with changes, 1 on a failure (KEYS-2). The rpm and tpm limits are not in the table and stay
as they are (KEYS-3).

## `litellm:key`

`mise run litellm:key <app>` registers key `litellm_key` of Secret `<app>` in namespace `<app>` (one printable line
without a trailing newline, `sk-` and at least 16 characters) as the row's key, prints `unchanged` when the stored
hash equals the value's, and refuses another value under the alias, changing nothing; a key's new value goes to
`platform-secrets` first (KEY-1). Both run through `scripts/litellm_keys.sh` with a port-forward and the master key: a
value and the master key travel from kubectl's stdout through shell variables to curl's stdin, never in an argument, a
file or a child's environment, and are never printed; the reply of `/key/generate` goes nowhere; a failure names the
step and the status, never a body (KEY-2).

## `litellm:admin`

`mise run litellm:admin <username>` is the unlimited AI budget of one admin, through the same script: it reads the
person as `keycloak:agent-owner` does (`scripts/keycloak_kcadm.sh`, which both tasks source, and whose kcadm
diagnostics this command discards, since they can quote a URL with the person's id), the realm's issuer from the
public discovery document and the group `/services/litellm/admin`, and LiteLLM's budget `litellm-admin` and customer
row, all before the first write; it then writes and reads back, in this order, the budget (no limit, `1mo`, created or
corrected), the membership and the customer row, which is `/customer/new` under agent-runtime's `person_fingerprint`
of issuer and person id or `/customer/update` of `budget_id` alone, so spend and other fields stay (ADMIN-1). A second
run prints `<username> unchanged`, and a finished run prints what it wrote (ADMIN-2). A missing argument, a name no
person carries and a service account's name end in `nothing changed`; a failure, a lost answer, a failed read-back or
a signal after a write names what was written or may have been and says that running it again completes it; nothing is
rolled back and no output holds an id, the fingerprint or a key (ADMIN-3). Removing an admin is not built (ADMIN-4).

## Proofs on the PC

`mise exec -- tests/keycloak/restored_copy_keeps_its_keys_and_people.sh <dump>` runs on the PC after
`db:load-dump keycloak <dump>` converged, through k3s's own kubeconfig, without sudo or a fetched secret: it fails
unless config-cli's Job completed within its `backoffLimit`, no client or user carries Keycloak's
`is_temporary_admin`, the realm's key ids equal those of the public issuer, and the rows of `user_entity`,
`credential`, `user_group_membership` and `user_attribute` equal the dump's by count and the sha256 of their sorted
lines, except the rows of the service accounts that clients declared in `realm.yaml` gained since the dump, whose
count its "added" line prints (PCKC-1). It prints names, counts, key ids and `equal` or `DIFFERS`, never a row or a
message of `pg_restore` or `psql` (PCKC-2). Each database step runs under a statement and lock timeout and a 2-minute
local deadline; pg_dump and pg_restore also run under the container's own 100-second timeout, so no database session
outlives the check (PCKC-3). Either deadline's end fails it naming the step and which deadline (PCKC-4).

`mise exec -- tests/no_network/pod_on_the_pc_holds_only_lo.sh` runs on the PC through k3s's own kubeconfig, without
sudo: a Pod of the shape in a throwaway Namespace without a Pod Security label holds `lo` alone and reaches neither
the API's Service, cluster DNS nor the node, a default Pod beside it holds `eth0` and reaches them, and every
throwaway object is gone on every exit; it prints names and counts and changes nothing on the host (PCNET-1).

`mise exec -- tests/nvidia/restricted_pod_lists_the_card.sh` runs on the PC through k3s's own kubeconfig, without
sudo: it fails unless the node offers `nvidia.com/gpu` 1 and a Pod in a throwaway Namespace enforcing `restricted`, at
uid 1000 with the class and the limit, lists exactly one card; it prints counts and names, and every throwaway object
is gone on every exit (PCGPU-1).

`mise exec -- tests/litellm/key_list_count_equals_key_table_rows.sh <namespace>` reads the master key from the
cluster's Secret: through the PC's k3s and a port-forward it prints the keys LiteLLM's `/key/list` counts and the key
table's rows, those of the dashboard's UI session (which `/key/list` omits) and the rest, then `equal` or `DIFFERS`
for the count against the rest; each step runs under a deadline and names itself when it fails (PCKEYS-1).
