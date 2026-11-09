# Runbook: apply the GitHub settings

Symptom: a change to `src/opentofu/github` landed on `main`, or a fleet repository's settings drifted from it.
Impact: the security and merge settings of the managed repositories and the organisation's rulesets.

## Check

1. An agent, with the operator's own gh login: `scripts/apply_github_settings.sh`, on any commit. Exit 0: no change;
   2: the changes it lists; 1: a failure, a plan that deletes or replaces an object included.

## Fix

1. An agent, in a clean checkout at `origin/main`: `scripts/apply_github_settings.sh --apply`. It applies the plan
   of that same run.
2. An agent: `scripts/apply_github_settings.sh`. It exits 0.

Rollback: a pull request that undoes the change, then steps 1 and 2. A removal or a rename, which is a forget and an
import, follows [the GitHub settings reference](../github-settings.md), since a plan that deletes is refused.

## Escalate

Exit 1 naming addresses, or a change no landed commit explains: stop and ask the operator.
