# Runbook: plan the Cloudflare zone

Symptom: the Cloudflare root's lookups and imports must be read on the live zone, or the token's rights measured.
Impact: nothing; the root declares the zone's records, three rulesets and two settings and writes nothing to Cloudflare
with the read-only token.

## Check

1. The operator, in his terminal: `mise run cloudflare:token-absent`, after the plan below. It prints `0` and exits 0.

## Fix

1. The operator creates a read-only API token in Cloudflare's dashboard for the zone `hallucinai.de`, each of Zone,
   DNS, Zone Settings, Single Redirect, Transform Rules, Zone WAF, Account Rulesets and Cloudflare Tunnel set to Read,
   and stores it with `mise run cloudflare:token`. It reads the token from stdin without echo and prints only the path
   of its file.
2. The operator: `scripts/apply_opentofu.sh cloudflare`. Exit 0: no change; 2: the imports are planned, which the
   plan lists; 1: a failure, a 403 included, which shows a right the token lacks. A plan that changes a ruleset or
   removes one of its rules is a stop, since a deny rule must never be absent: keep the plan, tell platform's head
   which ruleset and rule, and apply nothing.
3. The operator: `mise run cloudflare:token-absent` (the Check).

Rollback: delete the token's file, and the token in the dashboard; the root holds nothing else.

## Escalate

A count above 0 or an exit 1 that names no missing right: stop, keep the files, and tell platform's head the count and
the file kind, never the token or any value from the files.
