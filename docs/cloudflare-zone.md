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
  and needs its entry in `denied_paths_by_host`, which the plan fails without; there is no second list of hosts.
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
- **Where a host's deny paths live.** In the local `denied_paths_by_host` of `rulesets.tf`, keyed by hostname. Every
  hostname of the tunnel's lines has an entry, an empty list for a host that denies nothing, and the plan fails for a
  tunnel host without one and for a key that is no tunnel host. A new host therefore never gets no deny rule by
  omission. The redirected names are the local `redirect`; each is a record name, so the zone check covers it.
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

The token is read-only, so a plan shows the imports and an apply writes nothing to Cloudflare. A removed host is a
`removed` block with `destroy = false`, since the command refuses a delete.

## Who runs it

Only the operator, in his terminal: `scripts/apply_opentofu.sh cloudflare`, the command that also plans the GitHub
settings, with the guarantees of [GH-3 to GH-6](github-settings.md). Its state, kept plan, data directory and lock
live outside the checkout under `platform/opentofu/` and are separate from the GitHub root's. CI has no token and no
network to Cloudflare; `mise run cloudflare:test` checks the root's format, lock and validity, its lookups, records,
rulesets, import maps and settings under a mocked provider, and the token's path with a fake tofu. The mocks cannot run
an import: which names a plan adopts is read from the import maps, and the plan with the read-only token is where the
imports run.
`--apply` also refuses an uncommitted change to the host file, which the root reads.

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
