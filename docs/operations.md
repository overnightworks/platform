# Operations

This reference holds ruled sentences.

Reader: the operator, and a lane that touches a Secret's expiry, an alert, a check, a page, Grafana, a scrape job, the
PC's disk, the AI budgets or the live check.

## Expiring Secrets

`mise run check:secrets-expiry` runs on the PC through k3s's own kubeconfig, without sudo, and reads only metadata: it
names, by namespace, name and date, every Secret whose annotation `platform.hallucinai.de/expires-on: YYYY-MM-DD` lies
within 30 days or in the past, and each whose value is no such date, and fails on any or when the listing fails; it
passes with no annotated Secret. (OPS-1)

## The status page (`infrastructure/gatus/`)

`mise run gatus:open` forwards `127.0.0.1` at a free local port kubectl chooses to the port of Gatus's Service and
prints the address of the status page once kubectl listens, none when the forward fails, which exits non-zero; the page
has no other way in. (OPS-2)

Its own NetworkPolicies admit one sender, Prometheus' server, to its port for the scrape of `/metrics`: any other pod gets no
answer, and `mise run gatus:open` forwards `127.0.0.1` to its Service at a free port and prints the address, the only way
for a person to the page. (OPS-3)

Prometheus scrapes Gatus' results, and `AiGatewayProbeFailing` mails once when the `litellm` endpoint, the AI gateway's
front, fails its probe for 10 minutes, and again when it resolves. The probe is healthy only on the front's 401 for a call
without a key, so a front or LiteLLM that answers 5xx, times out or refuses the connection fails it; a provider's refusal of
one model reaches the caller as that call's answer and fails nothing here. A Gatus that stops answering is `TargetDown`'s.
(OPS-17)

The `tunnel` endpoint asks `cloudflared`'s `/ready` through its Service and is red while the platform is offline
(`docs/runbooks/take-the-platform-offline.md`) and on a real loss of the edge. No alert rule reads it, so an offline the
operator started mails nothing; the red endpoint is the reminder.

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
stops the small `speech-runtime`; `mise run gpu:use songs` runs the small `speech-runtime` at two pods and waits until both are Ready,
stops `speech-runtime-gpu` and waits until its pod is gone, then runs `acestep-worker` and waits until it is Ready.
The Service `speech-runtime` reaches whichever speech Deployment is Ready, so its callers' URL stays, yet the GPU
image offers other voices and a different hearing model than the small one, so a caller that names a voice follows the
switch. The two small pods let a rollout or a drain leave one serving; the GPU image runs at one, since the card is one.
Git names no replica count for these three Deployments, so Flux keeps the choice, and a Deployment applied afresh runs
one small pod until the first `gpu:use songs` or the first GPU release.

A speech GPU release keeps speech answering while speech holds the card. `speech-runtime-gpu` rolls with `Recreate`, since
the one card admits no second pod, so a roll would leave the Service without a Ready pod for the pull and the start
(37 minutes and up to 10 more). The layer `speech-runtime-bridge` holds the Job `bridge`, which `speech-runtime` waits for:
with the GPU image at one pod and not yet at the release's image, it raises the small image from none to one pod and waits
until it is Ready, so the old GPU pod stops only after that. The Job `settle` of `speech-runtime` waits until the new GPU
pod is Ready and lowers the small image to none again, the count `gpu:use speech` leaves. Both Jobs carry the release's GPU
ref, so a new release re-runs them, and their scales name the count they expect, so a count that `gpu:use` set meanwhile
is kept: with the GPU image at none (songmaker holds the card, or it is free) they change nothing, and the next
`gpu:use speech` pulls the new image inside its own wait. A first apply leaves the counts at Kubernetes' default; the
first GPU release or the first `gpu:use` sets them, the release by lowering the small image once the GPU pod is Ready.
While a roll runs, the small image answers a retryable 503 to a caller that names a voice only the GPU image offers and
live hearing sessions close and reconnect. The head lands no GPU release inside a `gpu:use` window: `gpu:use speech`
scales the small image to none without a precondition, which would stop the bridge before the roll.

A `bridge` that fails (a small pod that does not turn Ready within 11 minutes, or a count that moved under three scales)
leaves `speech-runtime-bridge` not Ready and `speech-runtime` applying nothing, so the old GPU pod keeps serving and the
small image stays raised; it mails `KustomizationNotReady` after 15 minutes. Read the Job's log and the small pod's events,
fix the cause, then delete the Job `bridge`, which Flux creates again at its next reconcile; or revert the release. Until
then no change of `speech-runtime` applies. A `settle` whose wait passes its deadline (3300 seconds) leaves
`speech-runtime` not Ready with the small pod still serving, and mails `KustomizationNotReady` and `DeploymentUnavailable`
for the GPU image: read the GPU pod's events (disk, card, pull); once it is Ready, delete the Job `settle`, whose run
lowers the small image, or run `gpu:use songs`, after which a run changes nothing. A `settle` whose `kubectl wait` is
refused (Forbidden, or an API server it cannot reach) fails at once and leaves the small image up: read the Job's log,
fix the cause, then delete the Job `settle`. A `settle` that finds the Job `bridge`
gone fails: wait until Flux created `bridge` again, then delete `settle`. A `settle` that finds a newer release pending in
the Job `bridge`, or a count that `gpu:use` set, ends at once and leaves the small image to the newer release's `settle`
or to `gpu:use`. Before the first GPU release, read on the node the free space of the image filesystem, which must hold the
new GPU image (about 12.6 GB) beside the old, and the allocatable memory less requests, which must hold the small pod's
2 GiB; otherwise the release waits.

`mise run gpu:use free` frees the card for a measurement window and gives it back by itself. It runs only while speech
holds the card (`acestep-worker` at 0, `speech-runtime-gpu` at 1) and refuses otherwise without a scale call. It
arms the user timer `gpu-use-return` for 60 minutes (a still armed one is stopped first, and an arm that fails refuses
before any scale), runs the small `speech-runtime` at two pods until both are Ready and stops `speech-runtime-gpu`,
leaving `acestep-worker` at 0. When the timer fires it runs the script's `return`, which runs `speech` only while
`acestep-worker` and `speech-runtime-gpu` both stand at 0, so it never takes the card from songmaker and never
restarts a voice already restored; otherwise it says that nothing returned. `mise run gpu:use speech` ends the window
at once. The timer fires within a minute after its time; its journal is `journalctl --user -u gpu-use-return`, a
failed return shows in `systemctl --user --failed`, and a reboot or a killed user manager loses the timer, after which the voice
stays small until `gpu:use speech`. The timer runs the script at the path it was armed from, so run `free` from the main checkout.

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

`mise run litellm:cache-probe <key file>` is the operator's live proof of that marking: it sends three streamed
rounds, whose long system text is new to each run and each of which adds one user message to the round before, with the
app key read from the file to the smallest text model under one test person, prints each round's usage counts and the
cache writes and reads LiteLLM's spend log holds for the key since the run began, and exits 1 unless round 1 wrote the
cache, each later round read at least what the round before cached and the log counts those reads. It writes the test
person's customer row and three spend log rows; `mise run litellm:cache-probe --remove` deletes the row.

Besides `text/sonnet`, `text/haiku` and `text/opus`, LiteLLM names `text/sonnet-medium`, `text/sonnet-low`,
`text/haiku-medium` and `text/haiku-low`: each is its family's model with Anthropic's effort set by `output_config` in
`litellm-config.yaml`, so an app tries one by its name alone; `text/sonnet-fast` and `text/haiku-fast` are sonnet and
haiku at effort low with thinking off. A request that names `reasoning_effort` gets LiteLLM's adaptive thinking at that
effort instead. A key lists the names it may use. `mise run litellm:measure <key file> [<requests per name>]` is the
operator's measurement, since it spends money: it sends synthetic streamed requests to the eight sonnet and haiku names
in turn and prints each name's median time to the first content chunk and its median and total cost, from the stream's
usage and the prices of `/model/info`; `mise run litellm:measure --remove` deletes its test person's row.

`mise run litellm:gateway-probe` is the operator's probe of what LiteLLM passes through to Anthropic, which a LiteLLM
bump lane runs again on the new version, since a bump changes it. It makes a key of its own with the master key (every
text name, a budget of 5 USD, prompt caching on, an alias new to each run) and sends synthetic requests under one test
person on the chat route and on `/v1/messages`, on `text/sonnet-medium` and `text/haiku-fast`: mid-conversation tool
changes, deferred tools and tool references, a tool result that mixes a text part with a tool reference (question 18, for
agents#1104 and agents#1089, on the chat route: the next reply must call the loaded tool with the run's token and use the
parameter only its definition names, or the billed prompt tokens must rise against the same result without the
reference), compaction and its replay, the `max_tokens: 0` keep-alive, the write split
by cache lifetime and a 1-hour mark, the time to the first token at 50k, 200k and 800k cached tokens, and the prices of
`/model/info`. It prints one line per question, route and model with the answer and the usage fields and statuses that
show it, never a reply body, and ends with the run's cost from the spend log. A second key with a budget of a millionth
of a dollar shows the budget on both routes. Both keys are deleted on every exit, a failure included. The run takes about
half an hour and spends at most the key's 5 USD, mostly on the 800k-token points, which come last since the budget can end
them: LiteLLM lets the call that crosses a budget run in full, so each 800k call is sent only when the spend log's cost so
far plus the call's worst case fits: the prefix counts as the size the point's last call showed plus 1000 tokens, and a
call without one as the most input tokens `/model/info` names for the model; the tokens the route's last call showed
cached count at the cache read price only when that call started less than 240 seconds before (the cache lives 5 minutes
from its last use), all others at the dearer of the input and cache write price, and the output at its 16 tokens. Else the
point answers "not run: the key's budget"; its cost is the sum of the spend log's successful rows, and the run ends 1 when the log lacks one. It writes the keys
until they are deleted, the test person's row and one spend log row per call; `mise run litellm:gateway-probe --remove`
deletes the row and any key a killed run left, on every page of the key list. `mise run litellm:gateway-probe --question 18`
runs that question alone, for a bump or a change of the agents' loading shape: the key and a plain request on its route,
then its four requests (a result with the reference and a control, on each model), a few cents; the key is deleted on
every exit as in a full run, and a number that does not run alone ends 1 before any key is made.
`mise run litellm:gateway-probe --question 4 --model <name> [--model <name> ...]` asks the deferred-tool question (questions 4
to 6 and 8, one flow) on the chat route for each named model, for a model an app uses that the full run does not ask; the
caller names the models, the probe reads no app's configuration, a name that is no text model `/v1/models` lists ends 1
before any key is made, as does a `--model` on any question other than 4, and without `--model` it asks the pair of the
full run. It sends seven requests per model, after one small calibration request per model on `/v1/messages`.

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

## The live check (`scripts/live_check.sh`)

`mise run live:check <app>` checks that a person can sign in to the app on the live stack, through one test person that
`infrastructure/keycloak/realm.yaml` declares disabled, in `/apps/hopin`, `/apps/presentator`, `/apps/skat` and
`/apps/songmaker` only and with no credential, and that no other part of the platform uses. The apps are hopin, skat,
presentator and songmaker, the table in `scripts/live_check_apps.sh`. The command runs on the operator's PC, never from CI,
since CI holds no route and no kubeconfig to the PC's API server; CI proves it against a fake `kubectl` and a fake
`curl` (`tests/keycloak/live_check_leaves_the_person_disabled_on_every_exit.sh`) and the realm entry and Keycloak's form
step on k3d. Each app's own routes are proven only by a live run.

The command keeps the test password from cooperative agents only; the boundary that stops a non-cooperative one is the
operator's account on the PC: every agent inside it already administers Keycloak, so the password adds no reach it
lacks, and the password never leaves it. (OPS-18)

One run at a time: a second is refused before it reads or writes anything, as is a missing or unknown app, which prints
the usage and the table's app names. A run refuses, with no write, a person whose live groups differ from the file's
(for example after `keycloak:agent-owner` added it to `/agent-owners`, or before config-cli applied a landing), naming
the remedy: wait for the apply, or remove the membership the file does not declare. Otherwise it clears the person's
failed sign-ins, enables it with no required action in one write (config-cli's first create adds the realm's default action,
which this write clears), sets a random hex password through kcadm on stdin and signs in without a browser through the
app's start route, Keycloak's form (the password on curl's stdin, a URL that carries a code in a curl option file), the
callback and the account route, which must answer 200. The password lives in the command's memory only: no file,
argument, environment or output holds it, and no output holds a cookie, a code or a page. (OPS-19)

On every exit it can trap (success, error, TERM, INT) one EXIT trap signs out at every app whose cookie jar exists (the
app's own sign-out route with its `Origin`, read back by its account route answering 401; skat too, through its own
`POST /logout`), ends the person's Keycloak sessions, deletes every
password credential, disables the person, reads each back, deletes the cookie jar and removes kcadm's sign-in file
last; each step runs whatever an earlier one did, and signs kcadm in again when its file is gone. A step that fails
makes the run exit 1 and names what may remain. An exit it cannot trap (SIGKILL, the cap's kill, power loss) leaves the
person enabled with a credential, its sessions and the 0600 cookie jar `cookies-<app>` in `$XDG_RUNTIME_DIR/live-check`,
which the next run, for any app, finds first and cleans the same way, signing out at that app with the codes of the
result line carrying its name (`skat-sign-out=… skat-account-after=…`), and kcadm's sign-in file in Keycloak's container, which no later run learns and
which stays until Keycloak's pod restarts, all inside that boundary; the password died with the process. The run exits 0
when green, 1 when red and 3 when skipped, which is the app's Deployment not being Available, after the cleanup and with
no other write. A run whose lock another run holds reads and writes nothing, prints the result `refused` and exits 4; a red
result line ends with `step=<step>` while the sign-in was under way (`start`, `login-page`, `sign-in-form`, `callback`,
`account`, or `sign-out` once it passed), and the names that may remain survive a failed first cleanup. (OPS-20)

A realm apply during a run disables the person, so that run is red and a rerun is green. A rollout of the app during a
run may end its session, so that run is red too, while presentator's session lives in its
Postgres and survives its two `RollingUpdate` pods; a run that starts while the Deployment is not Available is skipped,
and one that starts after a rollout finished is not. A sign-out that fails, or a lost jar (power loss, a reboot, a cleared
runtime directory) when Keycloak's back-channel finds no pod either (skat and songmaker roll out by `Recreate`), leaves
the person's session row in that app until its own session lifetime; the person has no credential by then. The test
person's account row in each app's database is that app's own data and stays. (OPS-21)

`mise run live:report sign-in [<app>]` (`scripts/live_check_report.sh`) is the way a result reaches anyone, for every
app of the command's table when none is named. It takes `$XDG_RUNTIME_DIR/live-check/report.lock`, waiting up to 60
minutes, and exits 4 with `refused: another live:report is running; nothing ran` when it is still held. For each app it
runs `mise run live:check <app>`; exit 4 of the command is its lock being held, which the report polls for up to 30
minutes per app and never pushes red (an app whose lock is held that long is reported `skipped reason=command-busy`,
with nothing pushed or opened, and the report exits 4 after the other apps), and a red or skipped run is repeated once
after 10 minutes. A final green is pushed as `success=true`; a final red as `success=false` with the codes and the names
that may remain as its error, followed by one item `live:check <app> red after a rerun` at `overnightworks/<app>`,
unless an item of that exact title is open. The item holds the date, the result line, the failing step, whether the step
is the app's (`start`, `callback`, `account`, `sign-out`) or the cause sits at platform (`login-page`, `sign-in-form`, a
refusal of Keycloak or the stack, or a name that may remain other than the person's session at the app itself), and the
command to reproduce; the app's head closes it after a green. An app skipped twice gets no push and no item. While the
Kustomization `tunnel` is suspended, which `mise run offline` does, the report checks before each attempt, push and item
and then prints `<app> skipped reason=offline`; a suspend it cannot read counts as online and says so. The push goes
through a loopback forward to the Service `gatus` (the one `gatus:open` uses), three tries over two minutes, with the
token of the Secret `gatus-push` on curl's stdin only; the item is opened with the operator's `gh` login on the PC and
does not depend on the push. A failed push or item prints its name and, for gh, its exit code, never the body, and makes
the report exit 1. (OPS-22)

Each app of the table has a Gatus row of the group `live-check`, named `<app> sign-in`, which takes a push with the token
(a wrong token answers 401, an unknown row 404) and shows its first result after its first push. `LiveCheckRed` fires for a
row whose last result in 30 days is red for 5 minutes, which a restart of Gatus does not end; the next green push resolves
it. Its alerts, and those of `LiveCheckMissed`, take the route that groups by alertname, so reds that arrive together give
one mail listing each row and a red that joins them, or a row that turns green, gives one more at the next group interval;
the mail's text lists the rows still red under `firing:` and those that turned green under `resolved:`, one per line, as it
does for every other alert. (OPS-23)
