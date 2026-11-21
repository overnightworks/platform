#!/usr/bin/env bash
# The command behind `mise run litellm:cache-probe`: shows on the live gateway that a key with prompt caching on gets the
# provider's cache write and then the cache read, and that LiteLLM records the read under that key.
#   scripts/litellm_cache_probe.sh <key file>  reads an app key's value from the file, sends three streamed rounds to the
#                                              smallest text model under one test person, whose long first system text is
#                                              new to each run so that the first round writes the cache; round n sends that
#                                              system text and n consecutive user messages, each earlier one unchanged, as
#                                              a voice call's turns grow; prints each round's usage counts, then the cache
#                                              writes and reads LiteLLM's spend log holds for this run's calls of the key;
#                                              exits 1 when the first round shows no write, a later round reads less than
#                                              the round before cached (its write and read) or the log another read
#   scripts/litellm_cache_probe.sh --remove    deletes the test person's customer row, which the first call makes
# The run writes the test person's row and one spend log row per call to the live store and reads the spend log. The key's
# value and the master key travel as litellm_keys.sh says: from a file or kubectl's stdout through shell variables to
# curl's stdin, never into an argument, a URL or an output; a failure names the step and the HTTP status, never a body.
{ set +x; } 2>/dev/null
set -euo pipefail
# shellcheck source=litellm_keys.sh
source "$(dirname "${BASH_SOURCE[0]}")/litellm_keys.sh"
command_name=cache-probe

# The only person this command sends for; its customer row is what --remove deletes.
probe_person=fp-litellm-cache-probe
# The smallest of the text names litellm-config.yaml maps.
probe_model=text/haiku
# The system text's length: past the provider's minimum cacheable prefix of every model, a few thousand tokens.
probe_rules=400

# system_text: a text no earlier run sent, long enough to be cached.
system_text() {
  local rule
  printf 'Probe run %s-%s.\n' "$(date +%s)" "$RANDOM"
  for rule in $(seq "$probe_rules"); do printf 'Rule %s: answer with one word and keep rule %s.\n' "$rule" "$rule"; done
}
# stream_round <step> <body>: sends the body to the chat route with the key, streamed; sets usage to the JSON of the last
# usage object of the stream. Fails naming the step and the status when the status is not 200 or no usage came.
stream_round() {
  local step="$1" body="$2" config result stream_status data_lines
  config="header = \"Authorization: Bearer $(quote_inner "$value")\""
  config+=$'\nheader = "Content-Type: application/json"\ndata = "'"$(quote_inner "$body")"'"'
  result="$(printf '%s\n' "$config" | curl --silent --no-buffer --max-time 120 --config - \
    --write-out '\n%{http_code}' "http://127.0.0.1:$local_port/v1/chat/completions")" || result=$'\n000'
  stream_status="${result##*$'\n'}"
  [ "$stream_status" = 200 ] || fail "$step answered with status $stream_status, not 200"
  data_lines="$(sed -n 's/^data: {/{/p' <<<"${result%"$stream_status"}")"
  usage="$(yq --input-format json --output-format json --indent 0 '.usage | select(. != null)' <<<"$data_lines" | tail -n 1)"
  [ -n "$usage" ] || fail "$step carried no usage in its stream"
}
# usage_field <usage JSON> <yq path>: the number at the path, or absent.
usage_field() { yq --input-format json "$2 // \"absent\"" <<<"$1"; }
# growing_body <user messages>: the request body of a round: the system text and that many consecutive user messages.
growing_body() {
  local count="$1" messages
  messages="$(for number in $(seq "$count"); do printf 'Present %s: reply with the single word ok.\n' "$number"; done)"
  MODEL="$probe_model" PERSON="$probe_person" SYSTEM="$system" MESSAGES="$messages" yq --null-input --output-format json --indent 0 '
    {"model": strenv(MODEL), "user": strenv(PERSON), "stream": true, "stream_options": {"include_usage": true},
    "max_tokens": 16, "messages": [{"role": "system", "content": strenv(SYSTEM)}] +
    (strenv(MESSAGES) | split("\n") | map(select(. != "") | {"role": "user", "content": .}))}'
}
# count_recorded <key hash> <start>: sets recorded_calls, recorded_writes and recorded_reads to the calls and the cache
# writes and reads of spend_rows under the key since the start; returns 0 once they hold all three calls. The rows reach the
# loop through a pipe.
count_recorded() {
  local row_key started writes reads
  recorded_calls=0 recorded_writes=0 recorded_reads=0
  while read -r _ row_key started _ _ _ _ writes reads; do
    # UTC timestamps of one format compare as text.
    [ "$row_key" = "$1" ] && [[ $started > $2 ]] || continue
    recorded_calls=$((recorded_calls + 1))
    recorded_writes=$((recorded_writes + writes))
    recorded_reads=$((recorded_reads + reads))
  done < <(printf '%s\n' "$spend_rows")
  [ "$recorded_calls" -ge 3 ]
}
# spend_since <start>: sets recorded_calls, recorded_writes and recorded_reads to what LiteLLM's spend log holds for the key
# under the test person since the start, read again for two minutes until it holds all three calls. The rows are selected by
# the key's hash, which stays in a shell variable.
spend_since() {
  local key_hash
  key_hash="$(printf '%s' "$value" | sha256sum)"
  key_hash="${key_hash%% *}"
  await_spend_log "$probe_person" count_recorded "$key_hash" "$1" || true
}

probe_command() {
  local started system round usage_of_round written read_back expected_reads=0 held=1 previous_cached=0
  usage="" value=""
  value_from_file "$1"
  connect
  ask "listing LiteLLM's models" /v1/models
  [ "$(json "[.data[].id] | map(select(. == \"$probe_model\")) | length")" = 1 ] || fail "LiteLLM does not list the model $probe_model"
  system="$(system_text)"
  started="$(date -u +%Y-%m-%dT%H:%M:%S)"
  for round in 1 2 3; do
    stream_round "round $round" "$(growing_body "$round")"
    usage_of_round="$usage"
    written="$(usage_field "$usage_of_round" .cache_creation_input_tokens)"
    read_back="$(usage_field "$usage_of_round" .cache_read_input_tokens)"
    echo "litellm:cache-probe: round $round ($round user messages): prompt $(usage_field "$usage_of_round" .prompt_tokens), completion $(usage_field "$usage_of_round" .completion_tokens), cache write $written, cache read $read_back"
    if [[ $written =~ ^[0-9]+$ && $read_back =~ ^[0-9]+$ ]]; then
      if [ "$round" = 1 ]; then [ "$written" -gt 0 ] || held=0; else
        [ "$read_back" -ge "$previous_cached" ] && [ "$read_back" -gt 0 ] || held=0
        expected_reads=$((expected_reads + read_back))
      fi
      previous_cached=$((written + read_back))
    else
      held=0
    fi
  done
  spend_since "$started"
  echo "litellm:cache-probe: the spend log holds $recorded_calls calls of the key since this run began, cache writes $recorded_writes, cache reads $recorded_reads"
  echo "litellm:cache-probe: the test person $probe_person stays in LiteLLM's customer table; remove it with: mise run litellm:cache-probe --remove"
  [ "$held" = 1 ] && [ "$recorded_reads" = "$expected_reads" ] ||
    fail "the cache did not hold: expected a write in round 1, in each later round a read covering the round before's write and read, and those reads in the spend log"
  echo "litellm:cache-probe: held: round 1 wrote the cache, each later round read at least what the round before cached and the spend log counts the reads under the key"
}

remove_command() {
  connect
  ask "deleting the customer row of $probe_person" /customer/delete "{\"user_ids\":[\"$probe_person\"]}" discard
  echo "litellm:cache-probe: the customer row of $probe_person is deleted"
}

usage_text="usage: scripts/litellm_cache_probe.sh <key file> | --remove"
[ "$#" = 1 ] || fail "$usage_text"
case "$1" in
  --remove) remove_command ;;
  -*) fail "$usage_text" ;;
  *) probe_command "$1" ;;
esac
