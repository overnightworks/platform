# Runbook: plan the Cloudflare zone

Symptom: the Cloudflare root's lookups must be read on the live zone, or the token's rights must be measured.
Impact: nothing; the root declares no resource and writes nothing to Cloudflare.

## Check

1. The operator, in his terminal: `mise run cloudflare:token-absent`, after the plan below. It prints `0` and exits 0.

## Fix

1. The operator creates a read-only API token in Cloudflare's dashboard for the zone `hallucinai.de`, each of Zone,
   DNS, Zone Settings, Single Redirect, Transform Rules, Zone WAF, Account Rulesets and Cloudflare Tunnel set to Read,
   and stores it with `mise run cloudflare:token`. It reads the token from stdin without echo and prints only the path
   of its file.
2. The operator: `scripts/apply_opentofu.sh cloudflare`. Exit 0: both lookups were read; 1: a failure, a 403
   included, which shows a right the token lacks.
3. The operator: `mise run cloudflare:token-absent` (the Check).

Rollback: delete the token's file, and the token in the dashboard; the root holds nothing else.

## Escalate

A count above 0 or an exit 1 that names no missing right: stop, keep the files, and tell platform's head the count and
the file kind, never the token or any value from the files.
