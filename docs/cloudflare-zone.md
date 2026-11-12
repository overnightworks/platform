# Cloudflare zone

Reader: whoever changes `src/opentofu/cloudflare`.

## What `src/opentofu/cloudflare` holds

`src/opentofu/cloudflare/`: the Cloudflare provider at one pinned version, the local backend, two lookups (the zone
`hallucinai.de` and the tunnel `platform` in that zone's account, found by name) and what the zone holds for the hosts.

- **Records.** One proxied CNAME to the tunnel `platform` for each hostname of the tunnel's lines and for the
  redirect-only name `www`. The tunnel's lines are the one list of public hosts: the plain file
  `infrastructure/cloudflared/config.yaml`, which the root reads and from which `infrastructure/cloudflared/` builds
  the ConfigMap `cloudflared`. A hostname added to that file adds a record; there is no second list.
- **Adoption.** Each name is looked up in the zone first. A name with a single CNAME is imported and never created
  twice; a name with two CNAMEs or with an A or AAAA record fails the plan, since only a single CNAME is adopted and
  a record is never converted. The adopted ids are the output `record_ids_to_import`.
- **Settings.** HSTS (the `security_header` setting) with subdomains and preload, and Network Error Logging off. They
  are the resources of the module `settings/`, both always imported, because `tofu test` cannot plan a resource an
  import block names.

The token is read-only, so a plan shows the imports and an apply writes nothing to Cloudflare. A removed host is a
`removed` block with `destroy = false`, since the command refuses a delete.

## Who runs it

Only the operator, in his terminal: `scripts/apply_opentofu.sh cloudflare`, the command that also plans the GitHub
settings, with the guarantees of [GH-3 to GH-6](github-settings.md). Its state, kept plan, data directory and lock
live outside the checkout under `platform/opentofu/` and are separate from the GitHub root's. CI has no token and no
network to Cloudflare; `mise run cloudflare:test` checks the root's format, lock and validity, its lookups, records,
import map and settings under a mocked provider, and the token's path with a fake tofu. The mocks cannot run an import:
which names a plan adopts is read from the import map, and the plan with the read-only token is where the imports run.
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

The tunnel lookup carries the deprecated `connections`, whose `origin_ip` is the public address of the host running
cloudflared. It lands in the state and the kept plan, which are not encrypted and which only the operator's 0600
permissions guard.
