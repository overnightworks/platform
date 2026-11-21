# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # the sourcing script sets ok_calls, probe_key_hashes, probe_person, main_alias, model and spend_rows and reads budget_note.
# Sourced by scripts/litellm_gateway_probe.sh: the money of the probe, which is the prices /model/info names, the cost of
# the run so far from the spend log and the guard that sends a large call only when its worst case fits the key's budget.
# The caller sets ok_calls (the calls answered 200), probe_key_hashes (the hashes of its keys), probe_person, main_alias and
# model, and has litellm_keys.sh's json, ask, fail and await_spend_log.
# The key's budget in USD. LiteLLM checks it before a call and lets the call that crosses it run in full.
probe_budget=5
# The point from which a call asks the budget first; the most output tokens a guarded call may ask for; the tokens by which
# the same text may count more on the route that did not measure it (the routes send the same text and differ in the
# framing of a few tokens); the seconds after which a call's cache is no more counted as there, since the cache lives
# 5 minutes from its last use, which is no earlier than the start of the call that showed it.
guarded_tokens=800000 large_max_tokens=16 route_framing_tokens=1000 cache_fresh_seconds=240
# What the guard reads of a model in /model/info: its prices and the most input tokens it takes.
guard_names=(max_input_tokens input_cost_per_token cache_creation_input_token_cost cache_read_input_token_cost output_cost_per_token)
declare -A model_prices=()
budget_note=""

# model_price <model> <price name>: the dearest price in the last /model/info reply under the name, with or without the
# step above a size ("<name>_above_<n>k_tokens"); 0 when there is none.
model_price() {
  NAME="$1" STEM="$2" json '[.data[] | select(.model_name == strenv(NAME)) | .model_info | to_entries | .[] |
    select(.key | test("^" + strenv(STEM) + "(_above_[0-9]+k_tokens)?$")) | .value] | sort | .[-1] // 0'
}
# load_prices <model>: sets the input limit and the input, cache write, cache read and output price of the model from the last
# /model/info reply.
load_prices() {
  local name
  for name in "${guard_names[@]}"; do model_prices["$1|$name"]="$(model_price "$1" "$name")"; done
}

# count_probe_rows: sets row_count and row_sum to the number and the cost of the successful spend log rows of the probe
# keys, which the hashes of the keys select in the shell; returns 0 once there are as many as calls answered 200.
count_probe_rows() {
  local row_key row_status spend spends=""
  row_count=0
  while read -r _ row_key _ row_status spend _; do
    [ -n "$row_key" ] || continue
    [ -n "${probe_key_hashes[$row_key]-}" ] && [ "$row_status" = success ] || continue
    row_count=$((row_count + 1))
    spends+=" $spend"
  done < <(printf '%s\n' "$spend_rows")
  # shellcheck disable=SC2086 # the costs are numbers
  row_sum="$(printf '%s\n' 0 $spends | awk '{ sum += $1 } END { printf "%.6f", sum }')"
  [ "$row_count" -ge "$ok_calls" ]
}
# total_cost: prints the run's cost from the successful spend log rows of both probe keys, waiting for as many rows as
# calls answered 200; fails when they never came, since the total would be incomplete.
total_cost() {
  local row_count row_sum key_spend
  await_spend_log "$probe_person" count_probe_rows || true
  ask "reading the probe key" "/key/list?key_alias=$main_alias&return_full_object=true&size=100"
  key_spend="$(json '.keys[0].spend')"
  echo "litellm:gateway-probe: total cost $row_sum USD from $row_count spend log rows of the probe keys ($ok_calls calls answered 200); the main key's own spend counter reads $key_spend USD"
  [ "$row_count" -ge "$ok_calls" ] || fail "the spend log holds only $row_count successful rows of the probe keys for $ok_calls calls answered 200 after two minutes, so the total cost is incomplete"
}

# spent_so_far: sets spent_total to the cost of the successful spend log rows of the probe keys once the log holds as many
# as calls answered 200; returns 1 when it never did, so the cost is not known.
spent_so_far() {
  local row_count row_sum
  await_spend_log "$probe_person" count_probe_rows || return 1
  spent_total=$row_sum
}
# within_budget <point tokens> <measured size> <cached> <cached at>: whether a call stays within probe_budget on top of the cost
# so far; sets budget_note. Its prefix counts as the measured size of the point's earlier call (0 when there is none) plus
# route_framing_tokens, else as the most input tokens the model takes, which no request it answers exceeds, and at least the point's own size, since a
# map that names less is no limit of what is sent. Of it, <cached>
# tokens count at the model's cache read price when the call that showed them cached started less than cache_fresh_seconds
# before now (SECONDS of <cached at>); all others at the dearer of its input and cache write price, as a call that finds no
# cache pays. The output is counted at large_max_tokens. Only a point from guarded_tokens asks. An unknown price or limit or
# an incomplete spend log is no room.
within_budget() {
  local measured="$2" cached="$3" cached_at="$4" size name worst
  [ "$1" -ge "$guarded_tokens" ] || return 0
  for name in "${guard_names[@]}"; do
    [ "${model_prices["$model|$name"]-0}" != 0 ] || {
      budget_note="/model/info names no $name for $model"
      return 1
    }
  done
  if ! spent_so_far; then
    budget_note="the spend log never held the rows of the calls answered 200"
    return 1
  fi
  size="${model_prices["$model|max_input_tokens"]}"
  [ "$size" -ge "$1" ] || size=$1
  [ "$measured" -le 0 ] || size=$((measured + route_framing_tokens))
  [ $((SECONDS - cached_at)) -lt "$cache_fresh_seconds" ] || cached=0
  [ "$cached" -le "$size" ] || cached=$size
  worst="$(awk -v size="$size" -v cached="$cached" -v tokens="$large_max_tokens" \
    -v input="${model_prices["$model|input_cost_per_token"]}" -v write="${model_prices["$model|cache_creation_input_token_cost"]}" \
    -v read="${model_prices["$model|cache_read_input_token_cost"]}" -v output="${model_prices["$model|output_cost_per_token"]}" \
    'BEGIN { printf "%.4f", cached * read + (size - cached) * (input > write ? input : write) + tokens * output }')"
  budget_note="the probe keys spent $spent_total USD, this call costs at worst $worst USD ($size tokens, $cached counted as cached), the key's budget is $probe_budget USD"
  awk -v spent="$spent_total" -v worst="$worst" -v budget="$probe_budget" 'BEGIN { exit !(spent + worst < budget) }'
}
