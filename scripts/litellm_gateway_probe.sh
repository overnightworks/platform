#!/usr/bin/env bash
# The command behind `mise run litellm:gateway-probe`: answers on the live gateway the 17 questions of platform#799 that
# serve personas' plan (inline tools, deferred tools, compaction, the keep-alive, the cache lifetime and the prices), on
# LiteLLM's chat route and on /v1/messages, each on text/sonnet-medium and text/haiku-fast unless a question names one.
#   scripts/litellm_gateway_probe.sh           makes a key of its own with the master key (every text name, a budget of
#                                              5 USD, prompt caching on, an alias new to the run), sends synthetic
#                                              requests under one test person, each prompt new to the run so that the first
#                                              request writes the cache, prints one line per question, route and model
#                                              (number and tags, where, the answer, the usage fields and statuses that show
#                                              it, never a reply body) and the run's cost from the spend log; exits 1 when the
#                                              key cannot be made, a plain request is refused or a key cannot be removed
#   scripts/litellm_gateway_probe.sh --remove  deletes the test person's customer row and any probe key a killed run left
# Both probe keys are deleted on every exit, a failure included; only SIGKILL leaves one, which --remove clears. The second
# key has a budget of one millionth of a dollar and shows the budget on both routes. The run deletes the test person's row
# first, so the person's own budget never carries an earlier run's spend. The 800k-token points of question 10 come last,
# after the cache reads of question 17, since the main key's budget can end them: LiteLLM checks the budget before a call and
# lets the call that crosses it run in full, so each 800k call is sent only when the spend log's cost of the run so far plus
# the call's worst case (its tokens at the dearest cache price of its kind in /model/info) stays within the 5 USD, and else
# answers "not run: the key's budget". The run takes about half an hour, as the 1-hour cache write of question 17 is read
# only after ten minutes, and spends at most the key's 5 USD, mostly on the 800k points. It writes the key rows until they
# are deleted, the test person's row and one spend log row per call. The run's cost is the sum of the successful spend log
# rows of both keys; it exits 1 when the log never holds as many as calls answered 200.
# Where a question has no request shape LiteLLM can carry on a route, the line gives the status the nearest shape got.
# Values travel as litellm_keys.sh says, from kubectl's stdout or a shell variable to curl's stdin, never into an argument,
# a URL or an output; a failure names the step and the HTTP status, never a body. A request body holds only synthetic
# text and goes through a file in the scratch directory, since the 800k point is about 3 MB, more than an argument holds.
{ set +x; } 2>/dev/null
set -euo pipefail
# shellcheck source=litellm_keys.sh
source "$(dirname "${BASH_SOURCE[0]}")/litellm_keys.sh"
command_name=gateway-probe
# The port-forward lives through the whole run, the wait of question 17 and the removal of the keys at its end included.
forward_limit=90m

# The only person this command sends for; its customer row is what --remove deletes.
probe_person=fp-litellm-gateway-probe
key_alias_prefix=gateway-probe
sonnet_model=text/sonnet-medium
haiku_model=text/haiku-fast
probe_models=("$sonnet_model" "$haiku_model")
probe_budget=5
# The prefix size from which a call asks the key's budget first, since a call that crosses the budget still runs in full.
guarded_tokens=800000
# The key's parallel limit, which the rate limit check exceeds by one request; a budget of one millionth of a dollar, which
# the first call of the budget key passes and the next is over; a prefix past every model's minimum cacheable prefix; the
# rules of the calibration prefix, from which each model's tokens per rule follow; the seconds from a 1-hour write to its
# read, past ten minutes; the seconds a request may take.
probe_parallel=2 exhausted_budget=0.000001 small_prefix_tokens=6000 calibration_rules=1000 ttl_wait=630 call_timeout=900
beta_inline=inline-tools-2026-09-15
beta_compaction=compact-2026-09-04
mark_none=""
mark_5m=',"cache_control":{"type":"ephemeral"}'
mark_1h=',"cache_control":{"type":"ephemeral","ttl":"1h"}'

run_stamp="$(date +%s)-$RANDOM"
probe_aliases=()
# The conversation of the next request: its route, model, system text, tools (a JSON array or empty), messages (JSON
# objects separated by commas), stream flag and the cache mark every marked block carries.
route=messages model=$sonnet_model system_text="" tools_json="" messages_json="" streamed=false cache_mark=$mark_5m
# What the last request answered: its status, call id, first token and the usage fields as the route names them.
call_status="" call_id="" first_token_ms="" usage="{}"
u_input="" u_prompt="" u_output="" u_completion="" u_write="" u_read="" u_5m="" u_1h=""
n_prompt=0 n_write=0 n_read=0 n_output=0
ok_calls=0
declare -A rule_tokens=() ttl_written=() ttl_system=() probe_key_hashes=() write_price=() read_price=()
main_key="" budget_key=""

# hash_of <text>: the sha256 LiteLLM stores for a key, through a pipe.
hash_of() { printf '%s' "$1" | sha256sum | cut -d ' ' -f 1; }
# answer <question> <tags> <where> <answer> <evidence>: the line of one question on one route and model.
answer() { printf 'litellm:gateway-probe: Q%s [%s] %s: %s; %s\n' "$1" "$2" "$3" "$4" "$5"; }
# yes_no <command>...: yes when the command succeeds, else no.
yes_no() { if "$@"; then echo yes; else echo no; fi; }
# covers <cached before> <read>: whether the read is all of a cache that held something, as a prefix that is read again is read
# to its end; a read short by a tail, the conversation after a large system text included, is not covered.
covers() { [ "$1" -gt 0 ] && [ "$2" -ge "$1" ]; }
# gated <status> <verdict>: the verdict when the request was answered 200, else no with the status.
gated() { if [ "$1" = 200 ]; then echo "$2"; else echo "no, status $1"; fi; }
where() { echo "$route $model"; }
route_path() { if [ "$route" = chat ]; then echo /v1/chat/completions; else echo /v1/messages; fi; }
# read_verdict <cached before>: the last request's status, then whether it read what was cached before.
read_verdict() { gated "$call_status" "$(yes_no covers "$1" "$n_read")"; }
contains() { [[ $1 == *"$2"* ]]; }
both_present() { [ "$u_5m" != absent ] && [ "$u_1h" != absent ]; }
# free_keep_alive: whether the last request wrote nothing and produced nothing.
free_keep_alive() { [ "$n_write" = 0 ] && [ "$n_output" = 0 ]; }
# conversation <JSON object>...: the objects joined by commas.
conversation() {
  local IFS=,
  printf '%s' "$*"
}

# The turns of a conversation. A user turn carries the cache mark only when it is the last of its request.
user_turn() { printf '{"role":"user","content":[{"type":"text","text":"%s"%s}]}' "$1" "${2:+$cache_mark}"; }
assistant_turn() { printf '{"role":"assistant","content":[{"type":"text","text":"%s"}]}' "$1"; }
# system_note <JSON array of blocks>: a mid-conversation system message.
system_note() { printf '{"role":"system","content":%s}' "$1"; }
# tool_call_turn <id> <name> <input JSON>: an assistant turn that calls a tool, which the model did not write.
tool_call_turn() {
  if [ "$route" = messages ]; then
    printf '{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"%s","input":%s}]}' "$1" "$2" "$3"
  else
    printf '{"role":"assistant","content":null,"tool_calls":[{"id":"%s","type":"function","function":{"name":"%s","arguments":"%s"}}]}' \
      "$1" "$2" "${3//\"/\\\"}"
  fi
}
# tool_result_turn <id> <content JSON: a string or an array of blocks> [last]
tool_result_turn() {
  if [ "$route" = messages ]; then
    printf '{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":%s%s}]}' "$1" "$2" "${3:+$cache_mark}"
  else
    printf '{"role":"tool","tool_call_id":"%s","content":%s}' "$1" "$2"
  fi
}
# tool_body <name> <description> [<extra field>]: a tool in the shape Anthropic names it, which a tool_definition carries.
tool_body() {
  printf '{"name":"%s","description":"%s","input_schema":{"type":"object","properties":{"q":{"type":"string"}}}%s}' "$1" "$2" "${3-}"
}
# tool_def <name> <description> [<extra field>]: an entry of the route's tools array; defer_loading is such a field.
tool_def() {
  if [ "$route" = messages ]; then
    tool_body "$@"
  else
    printf '{"type":"function","function":{"name":"%s","description":"%s","parameters":{"type":"object","properties":{"q":{"type":"string"}}}}%s}' \
      "$1" "$2" "${3-}"
  fi
}
# filler <rules> <tag>: a text of the given rules that holds no character JSON escapes.
filler() {
  awk -v n="$1" -v tag="$2" 'BEGIN { for (i = 1; i <= n; i++) printf "Rule %d of %s: answer with one word and keep rule %d. ", i, tag, i }'
}
# rules_for <model> <tokens>: the rules that make about that many tokens in the model.
rules_for() { echo $(($2 * calibration_rules / ${rule_tokens[$1]})); }
# fresh_system <label> <tokens>: a system text no earlier run sent, of about that many tokens in the model.
fresh_system() { system_text="Probe run $run_stamp $1. $(filler "$(rules_for "$model" "$2")" "$run_stamp-${1//[^A-Za-z0-9]/-}")"; }
# begin_flow: the defaults of a conversation.
begin_flow() {
  streamed=false cache_mark=$mark_5m tools_json="" messages_json=""
}

# build_body <max_tokens> <extra fields>: writes the request body of the conversation in the route's shape.
build_body() {
  local tools_part="" stream_part=""
  [ -z "$tools_json" ] || tools_part=",\"tools\":$tools_json"
  if [ "$route" = messages ]; then
    printf '{"model":"%s","max_tokens":%s,"stream":%s,"metadata":{"user_id":"%s"},"system":[{"type":"text","text":"%s"%s}],"messages":[%s]%s%s}' \
      "$model" "$1" "$streamed" "$probe_person" "$system_text" "$cache_mark" "$messages_json" "$tools_part" "$2"
  else
    [ "$streamed" = false ] || stream_part=',"stream_options":{"include_usage":true}'
    printf '{"model":"%s","max_tokens":%s,"stream":%s,"user":"%s","messages":[{"role":"system","content":[{"type":"text","text":"%s"%s}]},%s]%s%s%s}' \
      "$model" "$1" "$streamed" "$probe_person" "$system_text" "$cache_mark" "$messages_json" "$stream_part" "$tools_part" "$2"
  fi >"$scratch/body.json"
}
# curl_config <beta>: the curl configuration of a request with the probe key and the body file.
curl_config() {
  local config
  config="header = \"Authorization: Bearer $(quote_inner "$value")\""
  config+=$'\nheader = "Content-Type: application/json"\nheader = "anthropic-version: 2023-06-01"'
  [ -z "$1" ] || config+=$'\nheader = "anthropic-beta: '"$1"$'"'
  config+=$'\ndata-binary = "@'"$scratch"$'/body.json"'
  printf '%s' "$config"
}
# read_usage: sets the usage fields from the last reply: the merged usage objects of a stream, else the reply's own.
read_usage() {
  local picks="" field
  usage="{}"
  if [ "$call_status" = 200 ]; then
    if [ "$streamed" = true ]; then
      sed -n 's/^data: {/{/p' "$scratch/reply" >"$scratch/chunks"
      # shellcheck disable=SC2016 # $each is yq's variable
      usage="$(yq ea --input-format json --output-format json --indent 0 \
        '[.] | map((.message.usage // .usage) | select(. != null)) | .[] as $each ireduce ({}; . * $each)' "$scratch/chunks")" || usage="{}"
    else
      usage="$(yq --input-format json --output-format json --indent 0 '.usage // {}' "$scratch/reply")" || usage="{}"
    fi
    [ -n "$usage" ] || usage="{}"
  fi
  # A field is found wherever the route nests it.
  for field in input_tokens prompt_tokens output_tokens completion_tokens cache_creation_input_tokens \
    cache_read_input_tokens ephemeral_5m_input_tokens ephemeral_1h_input_tokens; do
    picks+="${picks:+,}(([.. | select(tag == \"!!map\") | select(has(\"$field\")) | .[\"$field\"]] | .[0]) // \"absent\")"
  done
  u_input=absent u_prompt=absent u_output=absent u_completion=absent u_write=absent u_read=absent u_5m=absent u_1h=absent
  read -r u_input u_prompt u_output u_completion u_write u_read u_5m u_1h < <(yq --input-format json "[$picks] | join(\" \")" <<<"$usage") || true
  n_write="${u_write/absent/0}" n_read="${u_read/absent/0}"
  n_output="${u_output/absent/${u_completion/absent/0}}"
  if [ "$route" = chat ] && [ "$u_prompt" != absent ]; then n_prompt="$u_prompt"; else n_prompt=$((${u_input/absent/0} + n_write + n_read)); fi
}
# send <beta>: sends the body file to the route with the probe key; sets the status, call id, first token (streamed),
# the reply file and the usage. The status is the answer, so a refusal is no failure here.
send() {
  local line sent_at first_at=""
  call_status=""
  : >"$scratch/reply"
  : >"$scratch/headers"
  sent_at="$(microseconds "$EPOCHREALTIME")"
  while IFS= read -r line; do
    if [[ $line =~ ^[0-9]{3}$ ]]; then
      call_status="$line"
      continue
    fi
    printf '%s\n' "$line" >>"$scratch/reply"
    if [ "$streamed" = true ] && [ -z "$first_at" ] && [[ $line == 'data: {'*'"text_delta"'* || $line =~ \"content\":\ ?\"[^\"] ]]; then
      first_at="$(microseconds "$EPOCHREALTIME")"
    fi
  done < <({ printf '%s\n' "$(curl_config "$1")" | curl --silent --no-buffer --max-time "$call_timeout" --config - \
    --dump-header "$scratch/headers" --write-out '\n%{http_code}\n' "http://127.0.0.1:$local_port$(route_path)" || printf '\n000\n'; })
  call_status="${call_status:-000}"
  first_token_ms=""
  [ -z "$first_at" ] || first_token_ms=$(((first_at - sent_at) / 1000))
  call_id="$(tr -d '\r' <"$scratch/headers" | sed -n 's/^[Xx]-[Ll]itellm-[Cc]all-[Ii]d: *//p' | tail -n 1)"
  [ "$call_status" != 200 ] || ok_calls=$((ok_calls + 1))
  read_usage
}
# exchange <max_tokens> [<beta>] [<extra body fields>]: builds the conversation's request and sends it.
exchange() {
  build_body "$1" "${3-}"
  send "${2-}"
}
# key_get <path>: a GET with the probe key; sets call_status and reply.
key_get() {
  local result
  result="$(printf '%s\n' "header = \"Authorization: Bearer $(quote_inner "$value")\"" | curl --silent --max-time 60 --config - \
    --write-out '\n%{http_code}' "http://127.0.0.1:$local_port$1")" || result=$'\n000'
  call_status="${result##*$'\n'}"
  reply="${result%"$call_status"}"
}
# reply_called: sets called to the tool names the last non-streamed reply calls.
reply_called() {
  local expression='[.content[]? | select(.type == "tool_use") | .name] | join(" ")'
  [ "$route" = messages ] || expression='[.choices[0].message.tool_calls[]?.function.name] | join(" ")'
  called="$(yq --input-format json "$expression" "$scratch/reply" 2>/dev/null)" || called=""
}
# reply_says <word>: whether the text of the last non-streamed reply holds the word; the text is not kept.
reply_says() {
  local expression='[.content[]? | select(.type == "text") | .text] | join(" ")' text
  [ "$route" = messages ] || expression='.choices[0].message.content // ""'
  text="$(yq --input-format json "$expression" "$scratch/reply" 2>/dev/null)" || text=""
  [[ $text == *"$1"* ]]
}

# make_key <name> <budget> <models JSON> <parallel>: makes a key of this run with the master key; sets made_key to its
# value, which stays in shell variables. The alias is recorded first, so a lost answer still has the key removed.
make_key() {
  local alias="$key_alias_prefix-$run_stamp-$1" hex body
  hex="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  made_key="sk-$key_alias_prefix-$hex"
  probe_aliases+=("$alias")
  body="{\"key\":\"$made_key\",\"key_alias\":\"$alias\",\"max_budget\":$2,\"models\":$3,\"max_parallel_requests\":$4,\"enable_prompt_caching\":true}"
  ask "making the probe key $1" /key/generate "$body" discard
  probe_key_hashes["$(hash_of "$made_key")"]=1
}
# matching_hashes <list path> <alias regex>: prints the hash of each key under a matching alias on every page of the list;
# returns 1 when a page cannot be read.
matching_hashes() {
  local page=1 pages=1
  while [ "$page" -le "$pages" ]; do
    request "listing the probe keys" "$1&page=$page" || return 1
    pages="$(json '.total_pages // 1')" || return 1
    ALIAS="$2" json '.keys[] | select((.key_alias // "") | test(strenv(ALIAS))) | .token' || return 1
    page=$((page + 1))
  done
}
# remove_keys <list path> <alias regex>: deletes the keys the list holds under a matching alias and reads the list again.
# Returns 1 when a key remains or a step failed; it never ends the command, since it runs in the exit handler.
remove_keys() {
  local hashes hash
  hashes="$(matching_hashes "$1" "$2")" || return 1
  while read -r hash; do
    [ -z "$hash" ] || request "deleting a probe key" /key/delete "{\"keys\":[\"$hash\"]}" discard || return 1
  done < <(printf '%s\n' "$hashes")
  hashes="$(matching_hashes "$1" "$2")" || return 1
  [ -z "$hashes" ]
}
# probe_exit: deletes this run's keys, ends the forwards and the scratch directory as litellm_keys.sh's handler does and exits
# with the status the run had, or 1 when a key remains.
probe_exit() {
  local exit_status=$? alias
  if [ -n "${local_port-}" ]; then
    for alias in "${probe_aliases[@]}"; do
      if remove_keys "/key/list?key_alias=$alias&return_full_object=true&size=100" "^$alias\$"; then
        echo "litellm:gateway-probe: the probe key $alias is gone"
      else
        echo "litellm:gateway-probe: the probe key $alias may remain; delete it with: mise run litellm:gateway-probe --remove" >&2
        exit_status=1
      fi
    done
  fi
  on_exit "$exit_status"
  exit "$exit_status"
}

# calibrate <model>: sets the tokens of calibration_rules rules in the model from a request that reports them.
calibrate() {
  begin_flow
  route=messages model="$1" cache_mark=$mark_none
  system_text="Calibration $run_stamp. $(filler "$calibration_rules" "$run_stamp-calibration")"
  messages_json="$(user_turn 'Reply with the single word ok.')"
  exchange 8
  [ "$call_status" = 200 ] || fail "the calibration request on $1 answered with status $call_status, not 200"
  [ "$n_prompt" -gt 1000 ] || fail "the calibration request on $1 carried no usage"
  rule_tokens[$1]=$((n_prompt - 20))
}
# each_target <command>...: runs the command once per route and model, which it finds in route and model.
each_target() {
  local target_route target_model
  for target_route in messages chat; do
    for target_model in "${probe_models[@]}"; do
      route="$target_route" model="$target_model"
      begin_flow
      "$@"
    done
  done
}

# Question 1, 2, 3: the inline tool messages and the cache around them.
flow_inline() {
  local question='List the names of every tool you can call, comma separated, nothing else.' cached_before add_block
  local add_note removal_note first_status control_status added_read added_write seen call_one result_one
  fresh_system "inline-$route-$model" "$small_prefix_tokens"
  tools_json="[$(tool_def ping 'Answers with pong.')]"
  messages_json="$(user_turn "$question" last)"
  exchange 1024
  cached_before=$((n_write + n_read))
  add_block='{"type":"tool_addition","tool":{"type":"tool_definition","definition":'"$(tool_body weather_probe 'Reports the weather.')"'}'"$cache_mark"'}'
  add_note="$(system_note "[$add_block]")"
  messages_json="$(conversation "$(user_turn "$question")" "$add_note")"
  exchange 1024 "$beta_inline"
  first_status=$call_status added_read=$n_read added_write=$n_write
  seen=no
  if reply_says weather_probe; then seen=yes; fi
  exchange 1024
  control_status=$call_status
  if [ "$first_status" != 200 ]; then seen="no, status $first_status"; elif [ "$seen" = yes ] && [ "$control_status" = 200 ]; then seen="yes, but also without the beta header"; fi
  answer 1 "O1 O2 F11" "$(where)" "$seen" "with the beta header status $first_status, the added tool listed: $seen; the same request without the header: status $control_status"
  answer 2 O3 "$(where)" "$(gated "$first_status" "$(yes_no covers "$cached_before" "$added_read") read; written only the new block: $(yes_no test "$added_write" -lt $((cached_before / 10)))")" \
    "the request before cached $cached_before tokens; the request after the addition read $added_read and wrote $added_write"
  call_one="$(tool_call_turn toolu_probe_a weather_probe '{}')"
  result_one="$(tool_result_turn toolu_probe_a '"22 degrees"')"
  removal_note="$(system_note '[{"type":"tool_removal","tool":{"type":"tool_reference","name":"weather_probe"}}]')"
  messages_json="$(conversation "$(user_turn "$question")" "$add_note" "$call_one" "$result_one" "$(assistant_turn ok)" \
    "$(user_turn thanks)" "$removal_note" "$(tool_call_turn toolu_probe_b weather_probe '{}')" "$(tool_result_turn toolu_probe_b '"22 degrees"' last)")"
  exchange 256 "$beta_inline"
  case "$call_status" in
    200) seen="only discouraged: the API accepted a call to the removed tool" ;;
    400) seen="refused by the API" ;;
    *) seen="no answer" ;;
  esac
  answer 3 O11 "$(where)" "$seen" "a call to weather_probe after its tool_removal: status $call_status"
}

# skill_tools <first> <last> <extra field>: the tool entries skill_NN, comma separated, each with a long description.
skill_tools() {
  local number list="" name
  for number in $(seq "$1" "$2"); do
    name="$(printf 'skill_%02d' "$number")"
    list+="${list:+,}$(tool_def "$name" "Skill $number of run $run_stamp: $(filler 15 "$run_stamp-s$number")" "$3")"
  done
  printf '%s' "$list"
}
# reference_blocks <first> <last>: the tool_reference blocks of skill_NN.
reference_blocks() {
  local number list=""
  for number in $(seq "$1" "$2"); do list+="${list:+,}{\"type\":\"tool_reference\",\"tool_name\":\"$(printf 'skill_%02d' "$number")\"}"; done
  printf '[%s]' "$list"
}
# Question 4, 5, 6, 8: deferred tools, references in a tool result, and the cache around both.
flow_deferred() {
  local deferral=',"defer_loading":true' head_tools question base_total full_total deferred_total first_cached
  local d1_status d2_status d2_write d2_read d2_called d3_status d3_read add_read drop_read call_load first_turn
  fresh_system "deferred-$route-$model" "$small_prefix_tokens"
  question='Load the tools with load_tools, then call skill_07 with q set to x.'
  head_tools="$(tool_def ping 'Answers with pong.'),$(tool_def load_tools 'Loads further tools by name.')"
  messages_json="$(user_turn "$question" last)"
  tools_json="[$head_tools]"
  exchange 64
  base_total=$n_prompt
  tools_json="[$head_tools,$(skill_tools 1 40 '')]"
  exchange 64
  full_total=$n_prompt
  tools_json="[$head_tools,$(skill_tools 1 40 "$deferral")]"
  exchange 64
  deferred_total=$n_prompt d1_status=$call_status first_cached=$((n_write + n_read))
  answer 4 F1 "$(where)" "$(gated "$d1_status" "$(yes_no test $(((full_total - deferred_total) * 10)) -ge $(((full_total - base_total) * 9)))")" \
    "status $d1_status; billed prompt tokens: no skill tools $base_total, 40 loaded $full_total, 40 deferred $deferred_total"
  first_turn="$(user_turn "$question")"
  call_load="$(tool_call_turn toolu_probe_load load_tools '{}')"
  messages_json="$(conversation "$first_turn" "$call_load" "$(tool_result_turn toolu_probe_load "$(reference_blocks 1 37)" last)")"
  exchange 256
  d2_status=$call_status d2_write=$n_write d2_read=$n_read
  reply_called
  d2_called="${called:-no tool}"
  answer 5 F2 "$(where)" "$(gated "$d2_status" "$(yes_no contains "$d2_called" skill_)")" \
    "37 references in the result of load_tools: status $d2_status, the next reply called: $d2_called"
  messages_json="$(conversation "$first_turn" "$call_load" "$(tool_result_turn toolu_probe_load "$(reference_blocks 1 37)")" \
    "$(tool_call_turn toolu_probe_skill skill_07 '{"q":"x"}')" "$(tool_result_turn toolu_probe_skill '"done"' last)")"
  exchange 256
  d3_status=$call_status d3_read=$n_read
  answer 6 F3 "$(where)" "$(gated "$d2_status" "before the activation read: $(yes_no covers "$first_cached" "$d2_read"); the activation read by the next request: $(gated "$d3_status" "$(yes_no covers $((d2_write + d2_read)) "$d3_read")")")" \
    "cached before $first_cached; the activation request read $d2_read, wrote $d2_write; the next read $d3_read"
  messages_json="$(user_turn "$question" last)"
  tools_json="[$head_tools,$(skill_tools 1 41 "$deferral")]"
  exchange 64
  add_read=$n_read
  tools_json="[$head_tools,$(skill_tools 1 39 "$deferral")]"
  exchange 64
  drop_read=$n_read
  answer 8 F5 "$(where)" "$(gated "$call_status" "$(if covers "$first_cached" "$add_read" && covers "$first_cached" "$drop_read"; then echo "no break"; else echo "break"; fi)")" \
    "cached before $first_cached; one deferred tool added: read $add_read; one dropped: read $drop_read"
}

# Question 7 and the time to first token of question 10 that follows an activation.
flow_skill() {
  local question='Activate the skill named reply, then follow it.' first_cached call result second_status second_ms second_read
  local second_cached third_status third_ms
  fresh_system "skill-$route-$model" "$small_prefix_tokens"
  tools_json="[$(tool_def ping 'Answers with pong.'),$(tool_def activate_skill 'Activates a skill by name.')]"
  messages_json="$(user_turn "$question" last)"
  exchange 64
  first_cached=$((n_write + n_read))
  call="$(tool_call_turn toolu_probe_skill activate_skill '{"name":"reply"}')"
  result='"Skill reply: answer with the single word ok."'
  streamed=true
  messages_json="$(conversation "$(user_turn "$question")" "$call" "$(tool_result_turn toolu_probe_skill "$result" last)")"
  exchange 64
  second_status=$call_status second_ms=$first_token_ms second_read=$n_read second_cached=$((n_write + n_read))
  messages_json="$(conversation "$(user_turn "$question")" "$call" "$(tool_result_turn toolu_probe_skill "$result")" \
    "$(assistant_turn ok)" "$(user_turn 'Again.' last)")"
  exchange 64
  third_status=$call_status third_ms=$first_token_ms
  answer 7 F4 "$(where)" "$(yes_no contains "$second_status/$third_status" 200/200)" \
    "the runner's activate_skill call and result after the user message: status $second_status, read $second_read of $first_cached cached; replayed in the next request: status $third_status, read $n_read of $second_cached cached"
  answer 10 "O5 F6" "$(where)" "${second_ms:-none} ms after activate_skill" \
    "first token of the extra request after the activation: ${second_ms:-none} ms; of the request after it: ${third_ms:-none} ms (streamed)"
}

# Question 16: the write split by lifetime, streamed and not.
flow_write_split() {
  local mode
  for mode in false true; do
    streamed=$mode
    fresh_system "split-$route-$model-$mode" "$small_prefix_tokens"
    messages_json="$(user_turn 'Reply with the single word ok.' last)"
    exchange 16
    answer 16 "O13 F10" "$(where) streamed=$mode" "$(gated "$call_status" "$(yes_no both_present)")" \
      "status $call_status, write $n_write, ephemeral_5m_input_tokens $u_5m, ephemeral_1h_input_tokens $u_1h"
  done
}

# Question 9: the caching marks of the key, with no mark in the request.
flow_marks() {
  local first_write second_read third_read
  cache_mark=$mark_none
  fresh_system "marks-$route-$model" "$small_prefix_tokens"
  messages_json="$(user_turn 'Reply with the single word ok.')"
  exchange 16
  first_write=$n_write
  if [ "$route $model" = "messages $haiku_model" ]; then spend_probe_id="$call_id"; fi
  messages_json="$(conversation "$(user_turn 'Reply with the single word ok.')" "$(assistant_turn ok)" "$(user_turn 'Reply ok again.')")"
  exchange 16
  second_read=$n_read
  messages_json="$(user_turn 'Another first message, reply ok.')"
  exchange 16
  third_read=$n_read
  answer 9 O4 "$(where)" "$(gated "$call_status" "last message marked: $(yes_no covers "$first_write" "$second_read"); end of system marked: $(yes_no test "$third_read" -gt 0)")" \
    "a request with no mark wrote $first_write; the same turns grown by two read $second_read; another first message read $third_read (the system text alone)"
}

# Question 15: the keep-alive request and the turn after it.
flow_keep_alive() {
  local first_status cached keep_text keep_id keep_verdict=no next_read spend_text spend_free=no
  fresh_system "keepalive-$route-$model" "$small_prefix_tokens"
  streamed=true
  messages_json="$(user_turn 'Reply with the single word ok.' last)"
  exchange 64
  first_status=$call_status cached=$((n_write + n_read))
  streamed=false
  exchange 0
  keep_id=$call_id
  keep_text="status $call_status, read $n_read of $cached cached, write $n_write, output $n_output"
  if [ "$call_status" != 200 ]; then
    exchange 1
    keep_id=$call_id
    keep_text+="; max_tokens 1: status $call_status, read $n_read, write $n_write, output $n_output"
  elif free_keep_alive; then
    keep_verdict="$(read_verdict "$cached")"
  fi
  streamed=true
  messages_json="$(conversation "$(user_turn 'Reply with the single word ok.')" "$(assistant_turn ok)" "$(user_turn 'Reply ok again.' last)")"
  exchange 64
  next_read=$n_read
  spend_text="spend log row of the last keep-alive request: not found"
  if spend_row_of "$keep_id"; then
    spend_text="spend log row of the last keep-alive request, which the budget counts: spend $row_spend, completion $row_completion, write $row_write, read $row_read"
    if [ "$row_write" = 0 ] && [ "$row_completion" = 0 ] && covers "$cached" "$row_read"; then spend_free=yes; fi
  fi
  [ "$keep_verdict" != yes ] || [ "$spend_free" = yes ] || keep_verdict="no, the spend log row is no free read of the whole prompt"
  [ "$keep_verdict" != yes ] || covers "$cached" "$next_read" || keep_verdict="no, the next streamed turn did not read the cache"
  answer 15 "O12 F12" "$(where)" "$keep_verdict" \
    "first turn status $first_status; max_tokens 0 copy: $keep_text; $spend_text; the next streamed turn read $next_read"
}

# Question 17: the 1-hour write and a 5-minute control, written now and read after ten minutes.
flow_ttl_write() {
  local ttl
  for ttl in 1h 5m; do
    if [ "$ttl" = 1h ]; then cache_mark=$mark_1h; else cache_mark=$mark_5m; fi
    fresh_system "ttl-$ttl-$route-$model" "$small_prefix_tokens"
    ttl_system["$route|$model|$ttl"]="$system_text"
    messages_json="$(user_turn 'Reply with the single word ok.' last)"
    exchange 16
    ttl_written["$route|$model|$ttl"]="$call_status $n_write $u_1h"
  done
}
flow_ttl_read() {
  local ttl status wrote one_hour result="" hit one_hour_hit=no
  for ttl in 1h 5m; do
    read -r status wrote one_hour <<<"${ttl_written["$route|$model|$ttl"]}"
    if [ "$ttl" = 1h ]; then cache_mark=$mark_1h; else cache_mark=$mark_5m; fi
    system_text="${ttl_system["$route|$model|$ttl"]}"
    messages_json="$(user_turn 'Reply with the single word ok.' last)"
    exchange 16
    hit="$(read_verdict "$wrote")"
    if [ "$ttl" = 1h ] && [ "${one_hour:-absent}" != absent ] && [ "${one_hour:-0}" -gt 0 ]; then one_hour_hit="$hit"; fi
    result+="${result:+; }$ttl mark: write status $status, wrote $wrote, ephemeral_1h_input_tokens $one_hour; ten minutes later read $n_read, hit: $hit"
  done
  answer 17 "O13 F13" "$(where)" "1-hour write in usage and hit after ten minutes: $one_hour_hit" "$result"
}

spend_probe_id=""
# find_row <call id>: sets row_spend, row_prompt, row_completion, row_write and row_read from the call's row of spend_rows;
# returns 1 when there is none.
find_row() {
  local line
  line="$(printf '%s\n' "$spend_rows" | grep "^$1 " || true)"
  [ -n "$line" ] || return 1
  read -r _ _ _ _ row_spend row_prompt row_completion row_write row_read < <(printf '%s\n' "$line")
}
# spend_row_of <call id>: find_row once LiteLLM has written the row; returns 1 when it never did.
spend_row_of() {
  [ -n "$1" ] || return 1
  await_spend_log "$probe_person" find_row "$1"
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
budget_note=""
# within_budget <tokens> <write|read>: whether a call of that many tokens, at the model's dearest cache price of that kind,
# stays within probe_budget on top of the cost so far; sets budget_note. Only the calls from guarded_tokens ask: LiteLLM lets
# the call that crosses the budget run in full. An unknown price or an incomplete spend log is no room.
within_budget() {
  local price="${write_price[$model]-0}" worst
  [ "$1" -ge "$guarded_tokens" ] || return 0
  [ "$2" = write ] || price="${read_price[$model]-0}"
  if [ "$price" = 0 ]; then
    budget_note="/model/info names no cache $2 price for $model"
    return 1
  fi
  if ! spent_so_far; then
    budget_note="the spend log never held the rows of the calls answered 200"
    return 1
  fi
  worst="$(awk -v tokens="$1" -v price="$price" 'BEGIN { printf "%.4f", tokens * price }')"
  budget_note="the probe keys spent $spent_total USD, this call costs at worst $worst USD, the key's budget is $probe_budget USD"
  awk -v spent="$spent_total" -v worst="$worst" -v budget="$probe_budget" 'BEGIN { exit !(spent + worst <= budget) }'
}
# One prefix of the given size on the model: written by /v1/messages, then read twice on each route, streamed. A route
# that does not read the other's cache writes its own at its first read and reads that at its second. A call the key's
# budget has no room for is not sent and ends the point.
large_point() {
  local tokens="$1" written first_status attempt chat_price stopped="" times_messages="" times_chat="" reads_messages="" reads_chat=""
  begin_flow
  route=messages
  fresh_system "large-$tokens-$model" "$tokens"
  messages_json="$(user_turn 'Reply with the single word ok.' last)"
  if ! within_budget "$tokens" write; then
    answer 10 "O5 F6" "$model" "not run: the key's budget" "the write of a $tokens-token prefix: $budget_note"
    return 0
  fi
  exchange 16
  first_status=$call_status written=$((n_write + n_read))
  if [ "$first_status" != 200 ]; then
    answer 10 "O5 F6" "$model" "no, status $first_status" "the write of a $tokens-token prefix on messages was refused$(budget_refused && echo " for the key's budget")"
    return 0
  fi
  streamed=true
  for attempt in 1 2; do
    chat_price=read
    [ "$attempt" = 2 ] || chat_price=write
    route=messages
    within_budget "$tokens" read || { stopped="; the next call was not run, the key's budget: $budget_note"; break; }
    exchange 16
    times_messages+=" ${first_token_ms:-none}" reads_messages+=" $n_read(status $call_status)"
    route=chat
    within_budget "$tokens" "$chat_price" || { stopped="; the next call was not run, the key's budget: $budget_note"; break; }
    exchange 16
    times_chat+=" ${first_token_ms:-none}" reads_chat+=" $n_read(status $call_status, write $n_write)"
  done
  answer 10 "O5 F6" "$model" "messages$times_messages ms, chat$times_chat ms" \
    "first token of each streamed read of a prefix of $written cached tokens; reads: messages$reads_messages, chat$reads_chat$stopped"
}
# replay_block: sends the compaction block, stored in a file as a restarted sender would hold it, as the first message, on
# the conversation's model and on the other one; sets restart_status and change_status.
replay_block() {
  restart_status="no block to replay" change_status="no block to replay"
  [ -n "$block" ] || return 0
  printf '%s' "$block" >"$scratch/block"
  messages_json="$(conversation "{\"role\":\"assistant\",\"content\":[$(<"$scratch/block")]}" "$(user_turn 'Reply with the single word ok.' last)")"
  exchange 16 "$beta_compaction"
  restart_status="status $call_status"
  if [ "$model" = "$haiku_model" ]; then model=$sonnet_model; else model=$haiku_model; fi
  exchange 16 "$beta_compaction"
  change_status="status $call_status on $model"
}
# Questions 12, 13, 14: compaction over the messages of two earlier requests, our own summary call over the same messages,
# and the stored block replayed after a restart of the sender and on the other model.
flow_compaction() {
  local t1 t2 t2_marked t3 t3_marked turn summary cached_older cached_full own_full own_older compaction_full
  local compaction_older param_status in_stream verdict=no original_model="$model" block="" restart_status="" change_status=""
  fresh_system "compaction-$model" "$small_prefix_tokens"
  t1="$(user_turn 'Remember the word alpha. Reply ok.')"
  t2="$(user_turn 'Remember the word beta. Reply ok.')" t2_marked="$(user_turn 'Remember the word beta. Reply ok.' last)"
  t3="$(user_turn 'Remember the word gamma. Reply ok.')" t3_marked="$(user_turn 'Remember the word gamma. Reply ok.' last)"
  turn="$(assistant_turn ok)" summary="$(user_turn 'Summarize the conversation so far in one sentence.' last)"
  messages_json="$(user_turn 'Remember the word alpha. Reply ok.' last)"
  exchange 16
  messages_json="$(conversation "$t1" "$turn" "$t2_marked")"
  exchange 16
  cached_older=$((n_write + n_read))
  messages_json="$(conversation "$t1" "$turn" "$t2" "$turn" "$t3_marked")"
  exchange 16
  cached_full=$((n_write + n_read))
  messages_json="$(conversation "$t1" "$turn" "$t2" "$turn" "$t3" "$summary")"
  exchange 512
  own_full="$(read_verdict "$cached_full")"
  messages_json="$(conversation "$t1" "$turn" "$t2" "$summary")"
  exchange 512
  own_older="$(read_verdict "$cached_older")"
  messages_json="$(conversation "$t1" "$turn" "$t2" "$turn" "$t3_marked")"
  exchange 4000 "$beta_compaction" ',"compaction":{"type":"summarize"}'
  param_status=$call_status compaction_full="$(read_verdict "$cached_full")"
  # The block is found wherever the route nests it.
  block="$(yq --input-format json --output-format json --indent 0 '[.. | select(tag == "!!map") | select(.type == "compaction")] | .[0] | select(. != null)' \
    "$scratch/reply" 2>/dev/null | head -n 1)" || block=""
  messages_json="$(conversation "$t1" "$turn" "$t2_marked")"
  exchange 4000 "$beta_compaction" ',"compaction":{"type":"summarize"}'
  compaction_older="$(read_verdict "$cached_older")"
  messages_json="$(conversation "$t1" "$turn" "$t2" "$turn" "$t3_marked")"
  streamed=true
  exchange 4000 "$beta_compaction" ',"compaction":{"type":"summarize"}'
  in_stream="$(gated "$call_status" "$(yes_no grep -Eq '"type": ?"compaction"' "$scratch/reply")")"
  streamed=false
  replay_block
  model="$original_model"
  if [ "$param_status" = 200 ] && [ -n "$block" ] && [ "$in_stream" = yes ] && [ "$restart_status" = "status 200" ]; then verdict=yes; fi
  answer 12 "O7 F8" "$(where)" "$verdict" \
    "compaction parameter: status $param_status, block in a stream: $in_stream, the stored block first in messages: $restart_status"
  answer 13 "O8 F7" "$(where)" "own summary call: full $own_full, older part $own_older; compaction: full $compaction_full, older part $compaction_older" \
    "cached by the requests: older part $cached_older, full $cached_full tokens"
  answer 14 O9 "$(where)" "$(yes_no contains "$restart_status/$change_status" "200/status 200")" \
    "the stored block replayed by a new request: $restart_status; on the other model: $change_status"
}
# Question 9: the rate limit, with one request more than the key's parallel limit at once.
flow_rate_limit() {
  local number pid statuses=""
  local -a pids=()
  begin_flow
  fresh_system "parallel-$route" "$small_prefix_tokens"
  messages_json="$(user_turn 'Count from 1 to 150, separated by commas, nothing else.')"
  build_body 400 ""
  for number in $(seq $((probe_parallel + 1))); do
    { printf '%s\n' "$(curl_config "")" | curl --silent --max-time "$call_timeout" --config - --output /dev/null \
      --write-out '%{http_code}' "http://127.0.0.1:$local_port$(route_path)" || printf 000; } >"$scratch/parallel-$number" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  for number in $(seq $((probe_parallel + 1))); do
    statuses+=" $(<"$scratch/parallel-$number")"
    if [ "$(<"$scratch/parallel-$number")" = 200 ]; then ok_calls=$((ok_calls + 1)); fi
  done
  answer 9 O4 "$(where)" "$(yes_no contains "$statuses" 429)" \
    "$((probe_parallel + 1)) requests at once on a key with a parallel limit of $probe_parallel answered:$statuses"
}
# budget_refused: whether the last request was refused for the key's budget: a client error whose reply names a budget.
budget_refused() { [[ $call_status == 4* ]] && grep -qi budget "$scratch/reply"; }
# Question 9: the budget, with a key whose budget its first call passes.
flow_budget() {
  local first_status refused_after=none messages_status messages_refused chat_status chat_refused attempt
  make_key budget "$exhausted_budget" "[\"$haiku_model\"]" 5
  budget_key="$made_key"
  value="$budget_key" route=messages model=$haiku_model
  begin_flow
  system_text="Probe run $run_stamp budget."
  messages_json="$(user_turn 'Reply with the single word ok.')"
  exchange 8
  first_status=$call_status
  for attempt in $(seq 12); do
    exchange 8
    if [ "$call_status" != 200 ]; then
      refused_after=$attempt
      break
    fi
    sleep 5
  done
  messages_status=$call_status messages_refused="$(yes_no budget_refused)"
  route=chat
  exchange 8
  chat_status=$call_status chat_refused="$(yes_no budget_refused)"
  value="$main_key"
  answer 9 O4 "messages $haiku_model" "$(yes_no test "$messages_refused/$chat_refused" = yes/yes)" \
    "a key with a budget of $exhausted_budget USD: first call status $first_status; /v1/messages ended with status $messages_status after $refused_after more calls (reply names the budget: $messages_refused); chat ended with status $chat_status (reply names the budget: $chat_refused)"
}

# model_price <model> <price name>: the dearest price in the last /model/info reply under the name, with or without the
# step above a size ("<name>_above_<n>k_tokens"); 0 when there is none.
model_price() {
  NAME="$1" STEM="$2" json '[.data[] | select(.model_name == strenv(NAME)) | .model_info | to_entries | .[] |
    select(.key | test("^" + strenv(STEM) + "(_above_[0-9]+k_tokens)?$")) | .value] | sort | .[-1] // 0'
}
# Question 11: what /model/info gives under the probe key; its cache write and read prices bound what a call may cost.
flow_model_info() {
  local entries
  key_get /model/info
  for model in "${probe_models[@]}"; do
    entries=""
    write_price[$model]=0 read_price[$model]=0
    if [ "$call_status" = 200 ]; then
      write_price[$model]="$(model_price "$model" cache_creation_input_token_cost)"
      read_price[$model]="$(model_price "$model" cache_read_input_token_cost)"
      entries="$(NAME="$model" json '[.data[] | select(.model_name == strenv(NAME)) | .model_info | to_entries | .[] |
        select(.value != null) | select(.key | test("max_input_tokens|cost"))] | map(.key + "=" + (.value | tostring)) | join(" ")')"
    fi
    answer 11 "O6 F9" "model/info $model" "$(gated "$call_status" "$(yes_no contains "$entries" cache_read_input_token_cost=)") (the 1-hour write price: $(yes_no contains "$entries" 1h); a step above a size: $(yes_no contains "$entries" above))" \
      "status $call_status, ${entries:-no entries}"
  done
}

# plain_check: one plain request on each route, so that a refused key or a body no route takes ends the run before it spends.
plain_check() {
  local checked
  for checked in messages chat; do
    route=$checked model=$haiku_model
    begin_flow
    system_text="Probe run $run_stamp plain check."
    messages_json="$(user_turn 'Reply with the single word ok.')"
    exchange 8
    [ "$call_status" = 200 ] || fail "the plain request on $checked answered with status $call_status, not 200"
  done
}

probe_command() {
  local text_models size
  trap probe_exit EXIT
  connect
  ask "listing LiteLLM's models" /v1/models
  [ "$(json '[.data[].id | select(. == "'"$sonnet_model"'" or . == "'"$haiku_model"'")] | length')" = 2 ] ||
    fail "LiteLLM does not list both $sonnet_model and $haiku_model"
  text_models="$(json --output-format json --indent 0 '[.data[].id | select(test("^text/"))] | sort')"
  # The person's spend starts at zero, so that an earlier run's cost never reaches the person's own budget.
  request "deleting the customer row of $probe_person" /customer/delete "{\"user_ids\":[\"$probe_person\"]}" discard || true
  make_key main "$probe_budget" "$text_models" "$probe_parallel"
  main_key="$made_key" main_alias="${probe_aliases[0]}" value="$made_key"
  plain_check
  for model in "${probe_models[@]}"; do calibrate "$model"; done
  flow_model_info
  value="$main_key"
  each_target flow_ttl_write
  ttl_started=$SECONDS
  each_target flow_inline
  each_target flow_deferred
  each_target flow_skill
  each_target flow_write_split
  each_target flow_marks
  each_target flow_keep_alive
  each_target flow_compaction
  model=$haiku_model
  for route in messages chat; do flow_rate_limit; done
  flow_budget
  for size in 50000 200000; do
    for model in "${probe_models[@]}"; do large_point "$size"; done
  done
  [ $((SECONDS - ttl_started)) -ge "$ttl_wait" ] || sleep $((ttl_wait + ttl_started - SECONDS))
  each_target flow_ttl_read
  # The key's budget ends the run at the largest points, which come last so that nothing else needs it after them.
  for model in "${probe_models[@]}"; do large_point 800000; done
  if spend_row_of "$spend_probe_id"; then
    answer 9 O4 "messages $haiku_model" yes "the spend log holds the /v1/messages call under the key and the person: spend $row_spend, prompt $row_prompt, completion $row_completion"
  else
    answer 9 O4 "messages $haiku_model" no "the spend log holds no row of the /v1/messages call"
  fi
  total_cost
  echo "litellm:gateway-probe: the test person $probe_person stays in LiteLLM's customer table; remove it with: mise run litellm:gateway-probe --remove"
}

remove_command() {
  connect
  ask "deleting the customer row of $probe_person" /customer/delete "{\"user_ids\":[\"$probe_person\"]}" discard
  remove_keys "/key/list?return_full_object=true&size=100" "^$key_alias_prefix-" || fail "a probe key remains or the key list cannot be read"
  echo "litellm:gateway-probe: the customer row of $probe_person and every probe key are deleted"
}

usage_hint="usage: scripts/litellm_gateway_probe.sh | --remove"
case "$#:${1-}" in
  0:) probe_command ;;
  1:--remove) remove_command ;;
  *) fail "$usage_hint" ;;
esac
