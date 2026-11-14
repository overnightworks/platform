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

# value_from_file <file>: sets value to the key in the file, which must be one printable line starting with sk-.
value_from_file() {
  [ -f "$1" ] && [ -r "$1" ] || fail "the key file cannot be read"
  value="$(<"$1")" || fail "the key file cannot be read"
  [[ $value == "$key_prefix"* && $value =~ ^[!-~]+$ ]] || fail "the key file is not one printable line starting with $key_prefix"
  [ "${#value}" -ge "$key_minimum_length" ] || fail "the key in the file is shorter than $key_minimum_length characters"
}
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
# spend_since <start>: sets recorded_calls, recorded_writes and recorded_reads to the calls and the cache writes and reads
# that LiteLLM's spend log holds for the key under the test person since the start; the log is written in batches, so it is
# read again for two minutes until it holds all three calls. The route's key filter would put the key's hash, which LiteLLM
# takes as the key itself, into curl's arguments, so the unfiltered log (its most recent rows) is read and the rows are
# selected here by the hash, which stays in a shell variable and reaches the loop through a pipe, since a here-string
# longer than a pipe holds is written to a temporary file.
spend_since() {
  local key_hash rows row_key started writes reads
  key_hash="$(printf '%s' "$value" | sha256sum)"
  key_hash="${key_hash%% *}"
  for _ in $(seq 12); do
    ask "reading the spend log" /spend/logs
    rows="$(PERSON="$probe_person" json '
      .[] | select(.end_user == strenv(PERSON)) | .api_key + " " + (.startTime | tostring) + " " + (.metadata |
      ((select(tag == "!!str") | from_json) // .) | .additional_usage_values |
      ((.cache_creation_input_tokens // 0) | tostring) + " " + ((.cache_read_input_tokens // 0) | tostring))')"
    recorded_calls=0 recorded_writes=0 recorded_reads=0
    while read -r row_key started writes reads; do
      # UTC timestamps of one format compare as text.
      [ "$row_key" = "$key_hash" ] && [[ $started > $1 ]] || continue
      recorded_calls=$((recorded_calls + 1))
      recorded_writes=$((recorded_writes + writes))
      recorded_reads=$((recorded_reads + reads))
    done < <(printf '%s\n' "$rows")
    [ "$recorded_calls" -lt 3 ] || return 0
    sleep 10
  done
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
