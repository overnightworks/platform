# Cloudflare zone

Reader: whoever changes `src/opentofu/cloudflare`.

## What `src/opentofu/cloudflare` holds

`src/opentofu/cloudflare/`: the Cloudflare provider at one pinned version, the local backend, two lookups (the zone
`hallucinai.de` and the tunnel `platform` in that zone's account, found by name) and what the zone holds for the hosts.

- **Records.** One proxied CNAME to the tunnel `platform` for each hostname of the tunnel's lines and for the
  redirected names, the apex and `www`. A name outside the zone `hallucinai.de` fails the plan. Each record waits for
  the deny and the redirect ruleset, so no name answers before its protection exists. The tunnel's lines are the one
  list of public hosts: the plain file `infrastructure/cloudflared/config.yaml`, which the root reads and from which
  `infrastructure/cloudflared/` builds the ConfigMap `cloudflared`. A hostname added to that file adds a record
  and needs its entry in `zone.yaml`, which the plan fails without; there is no second list of hosts.
- **Adoption.** Each name is looked up in the zone first. A name with a single CNAME is imported and never created
  twice; a name with two CNAMEs or with an A or AAAA record fails the plan, since only a single CNAME is adopted and
  a record is never converted. The adopted ids are the output `record_ids_to_import`.
- **Rulesets.** The zone's three entry points, as hal's OpenTofu declared them and with its expressions word for word.
  - `public deny`, phase `http_request_firewall_custom`: one block rule per denied path, covering every host that lists
    it. The path is decoded and matched case-insensitively with `wildcard`, each `/` of the path as `/*`, so extra or
    encoded slashes and a longer tail are refused too, and the host matches with or without a port.
  - `client address`, phase `http_request_late_transform`: sets `Forwarded` to the address Cloudflare saw, one rule
    per address family, which Keycloak reads.
  - `apex redirect`, phase `http_request_dynamic_redirect`: the apex and `www` answer 302 to `auth.hallucinai.de`
    over https and drop path and query, except the apex's legal pages (`/impressum`, `/datenschutz`,
    `/nutzungsbedingungen`, `/favicon.ico`) and its `/_rechtliches/` files, which the tunnel serves.
- **Where a host's facts live.** In `src/opentofu/cloudflare/zone.yaml`, keyed by hostname, which the root reads with
  `yamldecode` and the edge probe reads with `yq`, so the two cannot differ: `denied_paths`, the paths the public may
  never reach, and `health_path`, a path that answers 200 at the edge. Every hostname of the tunnel's lines has an
  entry, an empty `denied_paths` for a host that denies nothing, and the plan fails for a tunnel host without one and
  for a key that is no tunnel host. A new host therefore never gets no deny rule by omission. The same file holds the
  `redirect`: the redirected names, their target and the pages and the files prefix the apex serves, with `not_found`
  naming the pages among them that the origin deliberately answers 404; each name is a record name, so the zone check
  covers it.
- **Adoption of rulesets.** The zone's rulesets are looked up, and the one of kind `zone` in each of the three phases
  is imported with the id `zones/<zone id>/<ruleset id>`, never created beside it. A phase without one is created. Two
  in one phase fail the plan. The import keeps none of the zone's own rules, so a plan that shows a rule removed or a
  ruleset changed is a stop until the rule is written into the root or removed on purpose. The imported ids are the
  output `ruleset_ids_to_import`.
- **Settings.** HSTS (the `security_header` setting) with subdomains and preload, and Network Error Logging off. They
  are the resources of the module `settings/`, both always imported, because `tofu test` cannot plan a resource an
  import block names.

Outside the root stay Always Use HTTPS, the SSL mode and the MX and TXT records; the root neither reads nor changes
them.

A plan with the read-only token shows the imports and writes nothing to Cloudflare; the first apply writes the one change
of `www`'s record (below) and needs a token with Edit on DNS. A removed host is a `removed` block with
`destroy = false`, since the command refuses a delete.

## The first write: the adoption

The root declares what the zone already holds, so its first plan imports every object and writes at most one thing, the
`content` of `www`'s record, onto the platform's tunnel. `scripts/apply_opentofu.sh cloudflare` runs
`scripts/cloudflare_adoption_check.sh` on the kept plan after the plan and before any apply, a plan-only run included.
While the plan imports any object, a half-finished adoption included, it passes only without a create or a delete,
with every imported ruleset and setting at no-op, at most one update, the `content` of the record whose name starts with
`www.`, and with every declared object that the state does not hold yet among the imports (an object the state holds
is at no-op without an import and passes). A create, a delete, a forget, a replacement, a second update, an update of
another record, ruleset or setting, a change of another attribute of `www` and a declared object without an import all
stop it. A plan that cannot be read, an empty one included, fails the run. The output lists the counts and each address
with its action, never a value.

The order:

1. `mise run cloudflare:edge-probe`: the baseline; every line starts with `ok`.
2. `scripts/apply_opentofu.sh cloudflare`: plan only; exit 2 and the guard's list.
3. `scripts/apply_opentofu.sh cloudflare --apply`, at a clean `origin/main`.
4. `scripts/apply_opentofu.sh cloudflare`: exit 0.
5. `mise run cloudflare:edge-probe` again: its output equals step 1's line for line.

What each stop means, and what to do: nothing is applied and nothing is changed by hand until platform's head has read it.

- `<address> create: is not an import` (or delete, forget, replace): the zone does not hold what the root declares, or
  holds more; the live zone differs from the declaration, so a write there could open a path or take a host down.
- `<address> update: is an import that is not at no-op`: the live object differs from its declaration. For a ruleset the
  plan shows the rule that would go; a deny rule must never be absent, so the rule is written into the root or removed
  on purpose, in a pull request, before another plan.
- `second update` or `changes <attributes>`: more than the one allowed change of `www`.
- `is declared and the plan holds no import for it`: a lookup found no object to adopt, or the plan is partial; each instance of a record counts, so one
  host without its import stops the plan though the others have theirs.
- `is imported and declared nowhere`: the plan imports an address that the configuration does not plan.
- `the plan carries no configuration or no planned values`: the file is not a plan of this root.
- A `MISS` line of the probe in step 1 or 5 names the host, the path and the form that failed. A miss in step 1 is the
  edge as it was before the write; a difference between the two outputs is the write's effect and is undone by
  restoring `www`'s record to the content that step 2's plan printed as its earlier value.
- `the plan is empty or holds no list of resource changes` or `the plan holds no resource`: the plan could not be
  read; nothing was judged.
- An apply that fails after it wrote leaves a state that holds some objects and a plan that imports the rest: the
  adoption rules go on applying to it, so a create or an update beside the imports stops it. Run nothing further until
  the plan has been read by hand.

## Later plans

A plan without any import is a later plan: the adoption rules do not apply and the command behaves as it does for any plan: a delete or a
replacement is refused. An update of a ruleset (the deny, the transform or the redirect) is also refused, and the refusal names
`--allow-ruleset-update`, the one flag the operator or platform's head passes for a reviewed change, in a plan-only run
and in an apply alike. The flag allows no delete and loosens nothing in the adoption.

## The edge probe

`mise run cloudflare:edge-probe` runs `scripts/cloudflare_edge_probe.sh`, which sends no credential and requests the
public names from outside. It reads the hosts from the tunnel's lines and the paths from `zone.yaml`, and prints one line
per check, ending non-zero on any `MISS`:

- every denied path of a host answers 403 with Cloudflare's ray header, also in another case, with an encoded slash
  and with a doubled slash;
- the apex and `www` answer 302 to the redirect target;
- every page of `redirect.serve.pages` on the apex answers 200, and so does every host's `health_path`, except the pages
  of `redirect.serve.not_found`, which answer the origin's 404 and are not redirected;
- the HSTS header of each health response stands once.

The lines hold no time or id, so two runs against the same edge are equal. `cloudflare:test` runs the probe against a
fake edge on loopback that answers from the same two files and checks each miss.

## Adding and removing a host

To add a host, add its line to `infrastructure/cloudflared/config.yaml` and its entry to `zone.yaml` (its
`denied_paths`, empty if none, and its `health_path`); the plan fails without the entry. The plan then shows the record
as a create, or as an import when the zone already holds a single CNAME for the name, and the record waits for the deny
and the redirect ruleset. Run the probe before and after the apply: the new host's lines are the only difference.

To remove a host, delete its line and its entry and declare the record as a `removed` block with `destroy = false`;
the plan then forgets the record and the command's refusal of a delete stays in force. The record stays in the zone
until it is deleted in the dashboard.

## Who runs it

Only the operator, in his terminal: `scripts/apply_opentofu.sh cloudflare`, the command that also plans the GitHub
settings, with the guarantees of [GH-3 to GH-6](github-settings.md). Its state, kept plan, data directory and lock
live outside the checkout under `platform/opentofu/` and are separate from the GitHub root's. CI has no token and no
network to Cloudflare; `mise run cloudflare:test` checks the root's format, lock and validity, its lookups, records,
rulesets, import maps and settings under a mocked provider, the token's path with a fake tofu, the plan guard against
synthetic plans and the edge probe against a fake edge. The mocks cannot run an import: which names a plan adopts is read
from the import maps, and the plan with the read-only token is where the imports run.
`--apply` also refuses an uncommitted change to the host file, which the root reads, and to the guard's script.

## The token

The token is the read-only API token in the file `mise run cloudflare:token` writes, at 0600 in a 0700 directory. The
command checks that the file exists, is readable and holds a value, naming only its path, and gives tofu only that path
as `-var=api_token_file=…`; the provider reads the value itself. The command keeps the caller's environment from tofu,
and no argument, environment variable or trace of a run holds the value.

`mise run cloudflare:token-absent` counts the lines that hold the token file's value in the kept plan (read
decompressed), every file of the root's data directory and the state if one exists, prints only the count and fails
unless it is 0. It fails naming the path when the token file, the kept plan or the data directory is missing, since a
count over nothing proves nothing. CI cannot show it, since its tofu is a fake; it is run after each real plan.

## Remaining risk

Nothing watches the zone between plans: a record, a ruleset or a setting changed in the dashboard shows only at the
next plan.

The tunnel lookup carries the deprecated `connections`, whose `origin_ip` is the public address of the host running
cloudflared. It lands in the state and the kept plan, which are not encrypted and which only the operator's 0600
permissions guard.
