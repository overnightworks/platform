#!/usr/bin/env bash
# The command behind `mise run litellm:measure`: compares the text names of one model family at each effort on the live
# gateway by the time to the first token and the cost of a synthetic, call-turn-shaped request.
#   scripts/litellm_effort_measure.sh <key file> [<requests per name>]
#                                              reads an app key's value from the file (its models must list every name
#                                              below) and sends the requests streamed under one test person, one round
#                                              after the other over all names so that a slow period weighs on each alike;
#                                              each request is a short system text, new to it, and three consecutive user
#                                              messages that ask for one word, with no real content and 1024 tokens at most, which
#                                              leaves room for the thinking of a name whose tokens count in its cost;
#                                              prints per name the median time from sending to the first content chunk of
#                                              the stream, the median cost of a request and the total, and exits 1 on any
#                                              answer other than 200 or a stream without usage
#   scripts/litellm_effort_measure.sh --remove deletes the test person's customer row, which the first call makes
# The names are text/sonnet, text/haiku and their -medium, -low and -fast variants. The cost is the stream's usage
# (prompt and completion tokens) times the prices of the name's /model/info, so it ignores the discount of a cache read,
# which a text this short does not earn; LiteLLM's response cost header is not used, as a stream sends its headers
# before the cost is known. The run spends money and writes one spend log row per request and the test person's row to
# the live store.
# The key's value and the master key travel as litellm_keys.sh says: from a file or kubectl's stdout through shell
# variables to curl's stdin, never into an argument, a URL or an output; a failure names the step and the HTTP status,
# never a body.
{ set +x; } 2>/dev/null
set -euo pipefail
# shellcheck source=litellm_keys.sh
source "$(dirname "${BASH_SOURCE[0]}")/litellm_keys.sh"
command_name=measure

# The only person this command sends for; its customer row is what --remove deletes.
measure_person=fp-litellm-effort-measure
measured_names=(text/sonnet text/sonnet-medium text/sonnet-low text/sonnet-fast text/haiku text/haiku-medium text/haiku-low text/haiku-fast)
default_requests=10
# The lines of the system text, as many as a short call prompt holds.
system_lines=20

# microseconds <EPOCHREALTIME value>: the instant as whole microseconds.
microseconds() { echo "${1/./}"; }
# median <number>...: the middle of the numbers in ascending order, the mean of the two middle ones for an even count.
median() {
  printf '%s\n' "$@" | sort -g | awk '{ value[NR] = $1 } END { print (NR % 2) ? value[(NR + 1) / 2] : (value[NR / 2] + value[NR / 2 + 1]) / 2 }'
}
# request_body <name>: the JSON body of one request; its system text carries a stamp no other request has.
request_body() {
  local system line
  system="Measurement $(date +%s)-$RANDOM-$RANDOM."
  for line in $(seq "$system_lines"); do system+=" Rule $line: answer with one word."; done
  MODEL="$1" PERSON="$measure_person" SYSTEM="$system" yq --null-input --output-format json --indent 0 '
    {"model": strenv(MODEL), "user": strenv(PERSON), "stream": true, "stream_options": {"include_usage": true},
    "max_tokens": 1024, "messages": [{"role": "system", "content": strenv(SYSTEM)},
    {"role": "user", "content": "Present 1: reply with the single word ok."},
    {"role": "user", "content": "Present 2: reply with the single word ok."},
    {"role": "user", "content": "Present 3: reply with the single word ok."}]}'
}
# send_once <name>: sends one request; sets first_token_ms and usage_tokens ("<prompt> <completion>"). Fails naming the
# name and the status when the status is not 200, the stream holds no content (naming the spent max_tokens when the
# stream ended with finish_reason length) or no usage came.
send_once() {
  local name="$1" config line sent_at first_at="" status="" usage_line="" tokens cut_off=""
  config="header = \"Authorization: Bearer $(quote_inner "$value")\""
  config+=$'\nheader = "Content-Type: application/json"\ndata = "'"$(quote_inner "$(request_body "$name")")"'"'
  sent_at="$(microseconds "$EPOCHREALTIME")"
  while IFS= read -r line; do
    if [ -z "$first_at" ] && [[ $line == 'data: {'*'"content":"'[!\"]* ]]; then
      first_at="$(microseconds "$EPOCHREALTIME")"
    fi
    if [[ $line == 'data: {'*'"finish_reason":"length"'* ]]; then cut_off=1; fi
    if [[ $line == 'data: {'*'"usage":{'* ]]; then usage_line="${line#data: }"; fi
    if [[ $line =~ ^[0-9]{3}$ ]]; then status="$line"; fi
  done < <({ printf '%s\n' "$config" | curl --silent --no-buffer --max-time 120 --config - \
    --write-out '\n%{http_code}\n' "http://127.0.0.1:$local_port/v1/chat/completions" || printf '\n000\n'; })
  [ "$status" = 200 ] || fail "$name answered with status ${status:-000}, not 200"
  if [ -z "$first_at" ] && [ -n "$cut_off" ]; then fail "$name spent its max_tokens before its text"; fi
  [ -n "$first_at" ] || fail "$name streamed no content"
  tokens="$(yq --input-format json '.usage | [.prompt_tokens, .completion_tokens] | join(" ")' <<<"$usage_line")" ||
    fail "$name carried no readable usage in its stream"
  [[ $tokens =~ ^[0-9]+\ [0-9]+$ ]] || fail "$name carried no usage in its stream"
  usage_tokens="$tokens"
  first_token_ms=$(((first_at - sent_at) / 1000))
}
# price <name> <field>: the per-token price the model info of the name gives.
price() {
  local result
  result="$(NAME="$1" json ".data[] | select(.model_name == strenv(NAME)) | .model_info.$2 | select(. != null)")"
  [[ $result =~ ^[0-9.e-]+$ ]] || fail "the model info of $1 holds no $2"
  echo "$result"
}

measure_command() {
  local requests="$1" name prompt_tokens completion_tokens cost total
  local -A first_tokens=() costs=() input_price=() output_price=()
  usage_tokens="" first_token_ms="" value=""
  [[ $requests =~ ^[1-9][0-9]*$ ]] || fail "the number of requests per name is no positive whole number"
  value_from_file "$KEY_FILE"
  connect
  ask "reading the model info" /model/info
  for name in "${measured_names[@]}"; do
    [ "$(NAME="$name" json '[.data[] | select(.model_name == strenv(NAME))] | length')" = 1 ] ||
      fail "the model info does not list $name"
    input_price[$name]="$(price "$name" input_cost_per_token)"
    output_price[$name]="$(price "$name" output_cost_per_token)"
  done
  for _ in $(seq "$requests"); do
    for name in "${measured_names[@]}"; do
      send_once "$name"
      read -r prompt_tokens completion_tokens <<<"$usage_tokens"
      cost="$(awk -v p="$prompt_tokens" -v c="$completion_tokens" -v i="${input_price[$name]}" -v o="${output_price[$name]}" \
        'BEGIN { printf "%.8f", p * i + c * o }')"
      first_tokens[$name]+="$first_token_ms "
      costs[$name]+="$cost "
    done
  done
  for name in "${measured_names[@]}"; do
    # shellcheck disable=SC2086 # the lists are space-separated numbers
    total="$(printf '%s\n' ${costs[$name]} | awk '{ sum += $1 } END { printf "%.6f", sum }')"
    # shellcheck disable=SC2086
    echo "litellm:measure: $name: $requests requests, median first token $(median ${first_tokens[$name]}) ms, median cost $(median ${costs[$name]}) USD, total $total USD"
  done
  echo "litellm:measure: the test person $measure_person stays in LiteLLM's customer table; remove it with: mise run litellm:measure --remove"
}

remove_command() {
  connect
  ask "deleting the customer row of $measure_person" /customer/delete "{\"user_ids\":[\"$measure_person\"]}" discard
  echo "litellm:measure: the customer row of $measure_person is deleted"
}

usage_text="usage: scripts/litellm_effort_measure.sh <key file> [<requests per name>] | --remove"
case "${1-}" in
  --remove) [ "$#" = 1 ] || fail "$usage_text"; remove_command ;;
  -* | "") fail "$usage_text" ;;
  *) [ "$#" -le 2 ] || fail "$usage_text"; KEY_FILE="$1"; measure_command "${2:-$default_requests}" ;;
esac
