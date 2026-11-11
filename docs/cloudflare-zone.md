# Cloudflare zone

Reader: whoever changes `src/opentofu/cloudflare`.

## What `src/opentofu/cloudflare` holds

`src/opentofu/cloudflare/`: the Cloudflare provider at one pinned version, the local backend, and two lookups, the zone
`hallucinai.de` and the tunnel `platform` in that zone's account, found by name. It declares no resource, so a plan
changes nothing and an apply writes nothing to Cloudflare; both only read, to measure what the token may see.

## Who runs it

Only the operator, in his terminal: `scripts/apply_opentofu.sh cloudflare`, the command that also plans the GitHub
settings, with the guarantees of [GH-3 to GH-6](github-settings.md). Its state, kept plan, data directory and lock
live outside the checkout under `platform/opentofu/` and are separate from the GitHub root's. CI has no token and no
network to Cloudflare; `mise run cloudflare:test` checks the root's format, lock and validity, its lookups under a
mocked provider, and the token's path with a fake tofu.

## The token

The token is the read-only API token in the file `mise run cloudflare:token` writes, at 0600 in a 0700 directory. The
command checks that the file exists, is readable and is not empty, naming only its path, and gives tofu only that path
as `-var=api_token_file=…`; the provider reads the value itself. The command keeps the caller's environment from tofu,
and no argument, environment variable or trace of a run holds the value.

`mise run cloudflare:token-absent` counts the lines that hold the token file's value in the kept plan (read
decompressed), every file of the root's data directory and the state, prints only the count and fails unless it is 0.
CI cannot show it, since its tofu is a fake; it is run after each real plan.

## Remaining risk

The tunnel lookup carries the deprecated `connections`, whose `origin_ip` is the public address of the host running
cloudflared. It lands in the state and the kept plan, which are not encrypted and which only the operator's 0600
permissions guard.
