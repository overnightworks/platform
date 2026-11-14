# Operations

This reference holds ruled sentences.

Reader: the operator, and a lane that touches an alert, a check, a page or the PC's disk.

## Expiring Secrets

`mise run check:secrets-expiry` runs on the PC through k3s's own kubeconfig, without sudo, and reads only metadata: it
names, by namespace, name and date, every Secret whose annotation `platform.hallucinai.de/expires-on: YYYY-MM-DD` lies
within 30 days or in the past, and each whose value is no such date, and fails on any or when the listing fails; it
passes with no annotated Secret. (OPS-1)

## The status page (`infrastructure/gatus/`)

`mise run gatus:open` forwards `127.0.0.1` at a free local port kubectl chooses to the port of Gatus's Service and
prints the address of the status page once kubectl listens, none when the forward fails, which exits non-zero; the page
has no other way in. (OPS-2)

Its own NetworkPolicy admits no sender: `mise run gatus:open` forwards `127.0.0.1` to its Service at a free port and
prints the address, the only way to the page. (OPS-3)

## Grafana

`infrastructure/grafana/`: Grafana for Loki and Prometheus, in the Namespace `grafana` the layer owns, which enforces
Pod Security `restricted`: one pod, its image `docker.io/grafana/grafana` at a digest, and no claim, Secret, Role or
hook. (OPS-4)

The page has no login: anonymous access at the role Editor, the lowest that runs Explore, the login form and the initial
admin off, since only `mise run grafana:open` opens it, which forwards `127.0.0.1` to the Service; so whoever can start
that forward reads every line Loki holds. (OPS-5)

Update checks, analytics, the preinstall of plugins from grafana.com and Grafana's own alerting are off, so Alertmanager
stays the one alert channel. (OPS-6)

## Prometheus's scrape jobs (`infrastructure/prometheus/`)

The job `flux-controllers` keeps only Pods in phase Running, since a finished Pod keeps a target that reads down, and a
static job `alertmanager` scrapes Alertmanager, so `TargetDown` covers it. The job `songmaker` scrapes the web's `/metrics`
with the bearer token of the Secret `songmaker-monitoring`, which holds the value of the key `songmaker_monitoring_token` of
the Secret `songmaker`; the mount is optional, so a missing `songmaker-monitoring` shows as `TargetDown`, and `/metrics`
answers 503 while `songmaker` lacks the key. Prometheus re-reads the token file on every scrape, but the web reads its
settings once, so a rotated token is set in both Secrets and the web restarted. The job carries the labels of the web's
Deployment, so a dead web mails `DeploymentUnavailable` and `TargetDown` only for a Ready web that refuses the scrape. Its
alerts are `NoOnlineAceStepWorker`, silent while the Deployment `acestep-worker` stands at 0 replicas or is not Ready,
`SongmakerJobFailure` and `SongmakerBackgroundLoopUnhealthy`. (OPS-7)

The card has one user at a time because the PC holds one: `mise run gpu:use speech` stops `acestep-worker`, runs the
Deployment `speech-runtime-gpu` and waits until it is Ready, which takes minutes while it loads its models, then
stops the small `speech-runtime`; `mise run gpu:use songs` runs the small `speech-runtime` and waits until it is Ready,
stops `speech-runtime-gpu` and waits until its pod is gone, then runs `acestep-worker` and waits until it is Ready.
The Service `speech-runtime` reaches whichever speech Deployment is Ready, so its callers' URL stays, yet the GPU
image offers other voices and a different hearing model than the small one, so a caller that names a voice follows the
switch. Git names no replica count for these three Deployments, so Flux keeps the choice.

## The PC's disk and its bounds (`host/disk/` and the user units of `mise.toml`)

`mise run disk` runs without sudo and prints what fills the disk of the home directory by size and name (named
directories of `$HOME`, the rest of `$HOME`, and what lies outside it, which is Docker's `/var/lib/docker` and the
system, since only root reads that), then Docker's own count when the daemon answers within 2 minutes, else one line
saying it does not answer in time; from 85 % use it first prints a `WARNING` line on stderr, and it still exits 0.
(OPS-8)

Docuum keeps `docker system df`'s Images line, which counts a shared layer once, at 100 GB, deleting images least
recently used first, never one younger than a day, one a container uses, one tagged `previous`, a `-base` image or one
of the vendor repositories its `--keep` flags name; its state is `~/.local/share/docuum/state.yml`, and an image it has
never seen counts as last used at its creation. (OPS-9)

The tmpfiles line deletes a Codex session 30 days after the newest of its timestamps. (OPS-10)

`gtrash prune --day 30`, restricted to `~/.local/share/Trash`, deletes daily each Trash entry whose `.trashinfo`
deletion date is older than 30 days, with that file, and leaves an entry without a `.trashinfo`, one whose `.trashinfo`
it cannot read and the Trash of other mounts; the unit creates the home Trash first, since gtrash fails on a missing
one. (OPS-11)

Claude's sessions, Docker's volumes and its build cache (hal's) are never cleaned here. (OPS-12)

## AI budgets (`scripts/litellm_keys.sh`)

`keys.yaml` is the table of the person budget and each app's budget, parallel limit and optional `prompt_caching`; the
ConfigMap `litellm-keys` carries it, without a hash suffix, as no pod reads it. A row's `prompt_caching` (a boolean, true
when absent) is the key's `enable_prompt_caching`: LiteLLM marks the system text and the last message of the key's calls
to Claude for the provider's prompt cache, and `false` leaves them unmarked. LiteLLM keeps the field in the key's
metadata, where `litellm:keys` reads it back, and records the cache reads and writes of each call in its spend log row,
so a key whose cache costs more than it saves is switched off here. (OPS-13)

`mise run litellm:cache-probe <key file>` is the operator's live proof of that marking: it sends two identical streamed
rounds, whose long system text is new to each run, with the app key read from the file to the smallest text model under
one test person, prints each round's usage counts and the cache writes and reads LiteLLM's spend log holds for the key
since the run began, and exits 1 unless round 1 wrote the cache, round 2 read it and the log counts that read. It writes
the test person's customer row and two spend log rows; `mise run litellm:cache-probe --remove` deletes the row.

`mise run litellm:keys [--plan]` makes the person budget (the id of `max_end_user_budget_id`) and each row's key equal
to it, sending only the fields that differ, so a pure budget change keeps the period's reset; it prints the revision
Flux applied to the table it read, which it refuses when absent or changed during the read, one line per field with old
and new, and a count; it refuses a table whose person budget or a row's budget or parallel limit is no number, or a row's
`prompt_caching` no boolean, naming the row; a row without a key is named with `run litellm:key <app>` and ends 1 after
the rest; a failed write stops the rest
and names what was made, the failed write, whose outcome is unknown when its answer was lost, and what was not made;
`--plan` writes nothing and exits 0 with no change, 2 with changes, 1 on a failure. (OPS-14)

`mise run litellm:admin <username>` is the unlimited AI budget of one admin, through the same script: it reads the
person as `keycloak:agent-owner` does (`scripts/keycloak_kcadm.sh`, which both tasks source, and whose kcadm diagnostics
this command discards, since they can quote a URL with the person's id), the realm's issuer from the public discovery
document and the group `/services/litellm/admin`, and LiteLLM's budget `litellm-admin` and customer row, all before the
first write; it then writes and reads back, in this order, the budget (no limit, `1mo`, created or corrected), the
membership and the customer row, which is `/customer/new` under agent-runtime's `person_fingerprint` of issuer and
person id or `/customer/update` of `budget_id` alone, so spend and other fields stay. (OPS-15)

`mise run litellm:key <app> [--replace]` registers the value of the key `litellm_key` of the Secret `<app>` as the key of
the table's row `<app>`, with the row's budget and limits, read back; it prints `<app> made`, or `<app> unchanged` when
the alias already holds that value. Another value under the alias is refused, changing nothing, and the refusal names
`--replace`. With `--replace` the one key under the alias is deleted by its hash, which no other alias shares, and the
Secret's value is registered; it prints `<app> replaced`. LiteLLM binds spend to a key, so the replaced key's spend does
not carry over and the app's period starts anew. The alias holds no key between the two writes: a failure there says that
the alias holds no key (or may hold none or the new one, when an answer was lost), names the delete, and the same command
completes it. (OPS-16)
