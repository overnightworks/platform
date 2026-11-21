#!/usr/bin/env bash
# The money guard of `scripts/litellm_gateway_probe.sh` (scripts/litellm_probe_budget.sh) sends an 800k call only when the
# cost so far plus its worst case stays within the key's budget: the cache of an earlier call counts only while the call
# that showed it started less than the cache lives ago, and a call whose size no call of the point measured counts as the
# most input tokens the model takes, so that neither a stale cache nor an underestimated prefix lets a call pass that
# the budget cannot pay for. The caller's ports are replaced here: await_spend_log by a log of one successful row of a
# fixed cost, and json by the prices /model/info names.
# Usage: tests/litellm/gateway_probe_guard_prices_what_it_cannot_know_at_its_worst.sh
set -euo pipefail
# litellm_keys.sh, which the probe sources before the guard, sets it.
export LC_ALL=C

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
# shellcheck source=../../scripts/litellm_probe_budget.sh
source "$repository_root/scripts/litellm_probe_budget.sh"

model=text/sonnet-medium
declare -A listed_prices=([max_input_tokens]=1000000 [input_cost_per_token]=0.000002
  [cache_creation_input_token_cost]=0.0000025 [cache_read_input_token_cost]=0.0000001 [output_cost_per_token]=0.00001)
# json: the reply of /model/info for the price asked in model_price.
json() { echo "${listed_prices[$STEM]}"; }
# await_spend_log <person> <command>...: the log holds the one successful row of a probe key, which costs $spent.
declare -A probe_key_hashes=([probe-key-hash]=1)
ok_calls=1 probe_person=probe-person
await_spend_log() {
  shift
  spend_rows="request probe-key-hash start success $spent"
  "$@"
}
load_prices "$model"

# admits <spent> <measured size> <cached> <seconds since the cached call started>: whether the guard admits the call.
admits() {
  spent=$1
  within_budget 800000 "$2" "$3" $((SECONDS - $4))
}
# Written 1.6 USD at 800k tokens against a budget of 5 USD.
admits 4.0 800000 800000 10 || fail "a cache that a call showed 10 seconds ago was priced as a miss: $budget_note"
if admits 4.0 800000 800000 400; then
  fail "a cache that a call showed 400 seconds ago was priced as a read: $budget_note"
fi
echo "a cache is counted as read only while the call that showed it is recent"

admits 2.9 800000 0 0 || fail "a call of a measured size was priced above it: $budget_note"
if admits 2.9 0 0 0; then
  fail "a call of no measured size was priced below the most input tokens of the model: $budget_note"
fi
echo "a call of no measured size is priced at the most input tokens of the model"
