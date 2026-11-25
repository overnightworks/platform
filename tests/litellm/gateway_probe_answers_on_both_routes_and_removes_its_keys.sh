#!/usr/bin/env bash
# Drive `scripts/litellm_gateway_probe.sh` against a fake kubectl and a fake gateway (fake_gateway.py), for the outcomes
# the live gateway cannot arrange: a healthy run answers question 12, 13 and 14 on each route and model and question 10
# at every size on both models with chat measured on its own cache, ends 0 with its keys deleted and the cost of the
# successful spend log rows, and keeps its port-forward past everything it waits for; a key that cannot be deleted ends the
# run 1 although every question was answered; the budget answer is yes only when both routes refuse for the budget; a read
# short by the conversation after the system text is no read of what was cached, and a keep-alive is judged by the row of
# its last request; a spend log that lacks a successful row ends the run 1 although failed rows exist; a failed run ends
# its port-forward, deletes its keys and its scratch directory; `--remove` deletes the probe keys of every page of the key
# list and no other; question 18 answers from the call, the arguments and the billed prompt counts the gateway showed, on each
# model, a refusal or a reference that loads nothing is its own answer, and a run of that question alone sends only the
# requests it needs and deletes its key on every exit, an unknown question making none; question 4 alone asks the models
# given as arguments and no others, answers a refusing model as no, and ends 1 before any key for a model that is not a text
# name the gateway lists; and no key's value or hash reaches the argument of any command.
# Usage: mise exec -- tests/litellm/gateway_probe_answers_on_both_routes_and_removes_its_keys.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
fake_bin="$work_directory/bin"
guard_bin="$work_directory/guard-bin"
mkdir "$fake_bin" "$guard_bin"
master_key=sk-fake-master-key-0001
real_timeout="$(command -v timeout)"
real_curl="$(command -v curl)"
# stop_all: ends every run that still goes, which ends its probe and waits for it, and only then the gateways and
# forwards the runs leave and the directory of them all.
stop_all() {
  local pid_file
  # shellcheck disable=SC2046 # the job ids are numbers
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true
  for pid_file in "$work_directory"/*/server-pid "$work_directory"/*/forward-pids; do
    [ ! -f "$pid_file" ] || xargs -r kill <"$pid_file" 2>/dev/null || true
  done
  rm -rf "$work_directory"
}
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The fake tools read their directories and the fake master key from the environment, and find the real tool behind them on
# the path without the directory of the fakes.
export FAKE_BIN="$fake_bin" FAKE_MASTER_KEY="$master_key"
# Every run puts these in front of the tools of the probe, which refuse a key's value or a sha256 in their arguments,
# which a process list shows. Each starts one process of its own and then the tool, whose path it holds.
for tool in curl grep awk yq sed tr cut sha256sum head seq od; do
  printf '#!/bin/bash\nif [[ "$*" == *sk-* || "$*" =~ [0-9a-f]{64} ]]; then\n  echo "%s had a key or a hash in its arguments" >>"$FAKE_WORK/violations"\n  exit 1\nfi\nexec %q "$@"\n' \
    "$tool" "$(command -v "$tool")" >"$guard_bin/$tool"
  chmod +x "$guard_bin/$tool"
done
# The waits of the probe end at once, so that the run does not last half an hour, and each is recorded. A wait of a second
# or less is for a process that starts, which the wait runs for real.
cat >"$fake_bin/sleep" <<'FAKE'
#!/usr/bin/env bash
[ "$1" -gt 1 ] 2>/dev/null || exec "$(PATH="${PATH#"$FAKE_BIN:"}" command -v sleep)" "$1"
echo "$1" >>"$FAKE_WORK/sleeps"
FAKE
# The deadline of each port-forward is recorded; the command runs as it would.
cat >"$fake_bin/timeout" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *port-forward*) echo "$1" >>"$FAKE_WORK/forward-limits" ;; esac
shift
exec "$@"
FAKE
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"get secret litellm "*) printf '%s' "$FAKE_MASTER_KEY" | base64 --wrap=0 ;;
  *"get service litellm "*) printf 4000 ;;
  *port-forward*)
    echo $$ >>"$FAKE_WORK/forward-pids"
    echo "Forwarding from 127.0.0.1:$FAKE_PORT -> 4000"
    exec "$(PATH="${PATH#"$FAKE_BIN:"}" command -v sleep)" 3600 ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/sleep" "$fake_bin/timeout" "$fake_bin/kubectl"

# drive_probe <name> <faults> <seeded keys> <argument>...: runs the probe against a new fake gateway with
# the faults, in the directory $work_directory/<name>, which holds its status, output, the aliases the gateway holds
# afterwards and the files the fake tools write. Runs are independent, so the cell starts them all and then judges each.
drive_probe() {
  local name="$1" faults="$2" seeded="$3" directory port probe_pid status=0
  shift 3
  directory="$work_directory/$name"
  mkdir -p "$directory/tmp"
  mkfifo "$directory/port"
  python3 -I "$repository_root/tests/litellm/fake_gateway.py" "$master_key" "$faults" "$seeded" >"$directory/port" &
  echo $! >"$directory/server-pid"
  read -r port <"$directory/port" || fail "$name: the fake gateway did not listen"
  FAKE_WORK="$directory" FAKE_PORT="$port" PATH="$fake_bin:$guard_bin:$PATH" KUBECONFIG=/nonexistent MISE_DISABLE_TOOLS=kubectl \
    TMPDIR="$directory/tmp" "$real_timeout" 900 "$repository_root/scripts/litellm_gateway_probe.sh" "$@" >"$directory/output" 2>&1 &
  probe_pid=$!
  # A TERM to this run ends the probe, which runs its own cleanup, and the run waits for it.
  trap 'kill "$probe_pid" 2>/dev/null || true' TERM
  while kill -0 "$probe_pid" 2>/dev/null; do wait "$probe_pid" || status=$?; done
  echo "$status" >"$directory/status"
  "$real_curl" --silent "http://127.0.0.1:$port/__keys" | yq '.[]' >"$directory/held"
  kill "$(<"$directory/server-pid")"
}
declare -A drives=()
# start_probe <name> <faults> <seeded keys> <argument>...: starts drive_probe in the background.
start_probe() {
  drive_probe "$@" &
  drives[$1]=$!
}
# run_probe <name>: waits for the run; sets status, output and the aliases the gateway holds afterwards.
run_probe() {
  local directory="$work_directory/$1"
  wait "${drives[$1]}" || fail "$1: the run did not finish"
  status="$(<"$directory/status")"
  output="$(<"$directory/output")"
  held="$(<"$directory/held")"
  [ ! -f "$directory/violations" ] || fail "$1: $(<"$directory/violations")"
}
# has <name> <pattern>: the output of the run holds a line matching the pattern.
has() { grep -Eq "$2" <<<"$output" || fail "$1: no line matches $2: $(tail -n 40 <<<"$output")"; }
# lacks <name> <pattern>
lacks() { ! grep -Eq "$2" <<<"$output" || fail "$1: a line matches $2: $(grep -E "$2" <<<"$output")"; }
# count_of <name> <pattern> <number>: the number of lines matching the pattern.
count_of() {
  local seen
  seen="$(grep -Ec "$2" <<<"$output" || true)"
  [ "$seen" = "$3" ] || fail "$1: $seen lines match $2, not $3: $(grep -E "$2" <<<"$output")"
}
# ended_cleanly <name>: no scratch directory and no port-forward is left, and the gateway holds no probe key.
ended_cleanly() {
  local pid directory="$work_directory/$1"
  [ -z "$(ls -A "$directory/tmp")" ] || fail "$1: the scratch directory stays: $(ls "$directory/tmp")"
  if [ -f "$directory/forward-pids" ]; then
    while read -r pid; do ! kill -0 "$pid" 2>/dev/null || fail "$1: the port-forward $pid still runs"; done <"$directory/forward-pids"
  fi
  [ -z "$held" ] || fail "$1: the gateway holds the keys: $held"
}

start_probe healthy "" 0
for case in dear_writes spendy_calls heavy_first_call; do start_probe "$case" "$case" 0; done
start_probe small_limit "small_model_limit,heavy_first_call,spendy_calls" 0
start_probe dear_chat_write "dear_misses" 0
start_probe no_cache_reads "no_cache,dear_misses" 0
start_probe undeletable "delete_fails,messages_ignores_budget" 0
start_probe doubtful "unnamed_budget_refusal,short_read,refuse_zero,drop_row" 0
start_probe failed "chat_fails" 0
start_probe remove "" 120 --remove
start_probe alone "" 0 --question 18
start_probe alone_ignored "reference_ignored" 0 --question 18
start_probe alone_refused "mixed_refused" 0 --question 18
# Question 18's pass rule, one run alone for each way the evidence may fall short: <id> <faults> <the verdict with its evidence>.
alone_cases=(
  "alone_token_without_lane_billed_yes|lane_omitted|yes; status 200; the next reply called: vq_zeta, token in its arguments: yes, definition-only parameter used: no;"
  "alone_token_without_lane_unbilled_no|lane_omitted,definition_unbilled|no; status 200; the next reply called: vq_zeta, token in its arguments: yes, definition-only parameter used: no;"
  "alone_no_token_no|token_omitted|no; status 200; the next reply called: vq_zeta, token in its arguments: no, definition-only parameter used: yes;"
  "alone_extended_token_no|token_extended|no; status 200; the next reply called: vq_zeta, token in its arguments: no, definition-only parameter used: yes;"
  "alone_extended_lane_unbilled_no|lane_extended,definition_unbilled|no; status 200; the next reply called: vq_zeta, token in its arguments: yes, definition-only parameter used: no;"
  "alone_newline_token_no|token_newline|no; status 200; the next reply called: vq_zeta, token in its arguments: no, definition-only parameter used: yes;"
  "alone_newline_lane_unbilled_no|lane_newline,definition_unbilled|no; status 200; the next reply called: vq_zeta, token in its arguments: yes, definition-only parameter used: no;"
)
for alone_case in "${alone_cases[@]}"; do
  IFS='|' read -r case_id case_faults _ <<<"$alone_case"
  start_probe "$case_id" "$case_faults" 0 --question 18
done
start_probe alone_failed "chat_fails" 0 --question 18
start_probe alone_unknown "" 0 --question 3
# Question 4 alone, on the models it is given: the answered pair, a refusing model, a default pair, an unlisted name, a name
# that is no text name, a model argument for a question that takes none, and a failed run.
start_probe models_given "" 0 --question 4 --model text/sonnet --model text/haiku-low
start_probe models_refused "defer_refused" 0 --question 4 --model text/sonnet-low --model text/haiku-low
start_probe models_default "" 0 --question 4
start_probe models_unlisted "" 0 --question 4 --model text/sonnet --model text/nonesuch
start_probe models_not_text "" 0 --question 4 --model image/flare
start_probe models_misplaced "" 0 --question 18 --model text/sonnet
start_probe models_failed "chat_fails" 0 --question 4 --model text/sonnet

# A run with a healthy gateway.
run_probe healthy
[ "$status" = 0 ] || fail "healthy: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly healthy
count_of healthy '^litellm:gateway-probe: the probe key gateway-probe-[0-9]+-[0-9]+-(main|budget) is gone$' 2
for question in 12 13 14; do count_of healthy "Q$question \[" 4; done
for model in text/sonnet-medium text/haiku-fast; do
  count_of healthy "Q10 \[O5 F6\] $model: " 3
done
lacks healthy 'chat not run'
has healthy 'Q2 \[O3\] messages text/sonnet-medium: yes read'
has healthy 'Q9 \[O4\] messages text/haiku-fast: yes;'
has healthy 'Q15 \[O12 F12\] messages text/sonnet-medium: yes;'
for model in text/sonnet-medium text/haiku-fast; do
  has healthy "Q18 \[agents#1104\] chat $model: yes; status 200; the next reply called: [a-z_]+, token in its arguments: yes, definition-only parameter used: yes; billed prompt tokens: [0-9]+ with the reference, [0-9]+ for the control \(status 200, called: no tool\)"
done
count_of healthy 'Q18 \[' 2
has healthy '^litellm:gateway-probe: total cost [0-9.]+ USD from [0-9]+ spend log rows'
echo "a healthy run answers on both routes and models, deletes both keys and prints the cost"
# The forward outlives every wait of the run; the limit is read in minutes.
limit_seconds="$(awk '{ sub(/m$/, ""); print $1 * 60 }' "$work_directory/healthy/forward-limits")"
slept_seconds="$(awk '{ sum += $1 } END { print sum }' "$work_directory/healthy/sleeps")"
[ "$limit_seconds" -gt "$slept_seconds" ] || fail "healthy: the port-forward ends after $limit_seconds s, within the $slept_seconds s the run waits"
echo "the port-forward lives longer than everything the run waits for"

# An 800k call is sent only when the cost so far plus its worst case fits the key's budget: a write dearer than the whole
# budget is never sent, and a spend that leaves room for the prefix of the nominal 800k tokens but not for the most input
# tokens the model takes, which the write has no measured size to lower, is read from the spend log.
for case in dear_writes spendy_calls heavy_first_call; do
  run_probe "$case"
  [ "$status" = 0 ] || fail "$case: the probe ended $status: $(tail -n 20 <<<"$output")"
  ended_cleanly "$case"
  for model in text/sonnet-medium text/haiku-fast; do
    has "$case" "Q10 \[O5 F6\] $model: not run: the key's budget; the write of a 800000-token prefix: the probe keys spent [0-9.]+ USD"
    count_of "$case" "Q10 \[O5 F6\] $model: " 3
  done
done
echo "an 800k call whose worst case passes the key's budget is not run"

# A model whose map names fewer input tokens than the prefix is priced at the prefix, not at the map.
run_probe small_limit
[ "$status" = 0 ] || fail "small_limit: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly small_limit
has small_limit "Q10 \[O5 F6\] text/sonnet-medium: not run: the key's budget; the write of a 800000-token prefix: .*costs at worst [0-9.]+ USD \(([89][0-9]{5}|[0-9]{7,}) tokens"
echo "an 800k call is priced at its own size when the model names fewer input tokens"

# A read the budget has no room for is not sent: the chat write after a dear messages write, and a read of a cache that the
# write did not make, which costs the full price of its prefix.
stop_line="the next call was not run, the key's budget: the probe keys spent [0-9.]+ USD, this call costs at worst"
run_probe dear_chat_write
[ "$status" = 0 ] || fail "dear_chat_write: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly dear_chat_write
has dear_chat_write "Q10 \[O5 F6\] text/sonnet-medium: messages [0-9]+ ms, chat ms; .*reads: messages [0-9]+\(status 200\), chat; $stop_line"
run_probe no_cache_reads
[ "$status" = 0 ] || fail "no_cache_reads: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly no_cache_reads
has no_cache_reads "Q10 \[O5 F6\] text/sonnet-medium: messages ms, chat ms; .*reads: messages, chat; $stop_line"
echo "an 800k read is not sent when the budget has no room for what it costs without the cache"

# A key that cannot be deleted ends the run 1; a budget that /v1/messages does not enforce is no yes.
run_probe undeletable
[ "$status" = 1 ] || fail "undeletable: the probe ended $status, not 1: $(tail -n 5 <<<"$output")"
has undeletable 'the probe key gateway-probe-[0-9]+-[0-9]+-main may remain'
has undeletable 'Q9 \[O4\] messages text/haiku-fast: no;'
echo "a key that stays ends the run 1, and a budget only chat enforces is answered no"

# A refusal that names no budget, a read short by the tail of the conversation, a keep-alive refused with max_tokens 0 and
# a spend log without a successful row.
run_probe doubtful
[ "$status" = 1 ] || fail "doubtful: the probe ended $status, not 1: $(tail -n 5 <<<"$output")"
has doubtful 'Q9 \[O4\] messages text/haiku-fast: no;'
has doubtful 'Q2 \[O3\] messages text/sonnet-medium: no read'
has doubtful 'Q15 \[O12 F12\] messages text/sonnet-medium: no;.*max_tokens 1: status 200.*spend log row of the last keep-alive request, which the budget counts: spend 0\.001, completion 1,'
has doubtful 'the total cost is incomplete'
ended_cleanly doubtful
echo "an unnamed refusal, a short read, a refused keep-alive and a missing row are each answered as what they are"

# A run that fails at its first plain request leaves nothing behind.
run_probe failed
[ "$status" = 1 ] || fail "failed: the probe ended $status, not 1"
has failed 'the plain request on chat answered with status 500'
ended_cleanly failed
echo "a failed run ends its port-forward, its scratch directory and its keys"

# --remove reaches a probe key on the second page of the list and leaves the other keys.
run_probe remove
[ "$status" = 0 ] || fail "remove: the probe ended $status: $(tail -n 5 <<<"$output")"
[ "$(grep -c '^an-app-key-' <<<"$held")" = 120 ] || fail "remove: the gateway holds not its 120 other keys: $held"
! grep -q '^gateway-probe-' <<<"$held" || fail "remove: a probe key stays: $(grep '^gateway-probe-' <<<"$held")"
echo "--remove deletes the probe keys of every page of the list and no other key"

# Question 18 alone sends the plain check of its route and its own four requests, prints no other question and deletes its key.
run_probe alone
[ "$status" = 0 ] || fail "alone: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly alone
count_of alone 'Q[0-9]+ \[' 2
count_of alone 'Q18 \[agents#1104\] chat text/(sonnet-medium|haiku-fast): yes;' 2
count_of alone '^litellm:gateway-probe: the probe key gateway-probe-[0-9]+-[0-9]+-main is gone$' 1
has alone '^litellm:gateway-probe: total cost [0-9.]+ USD from 5 spend log rows of the probe keys \(5 calls answered 200\)'
echo "question 18 alone asks only what it needs and deletes its key"

# A reference that loads nothing and a refusal of the mixed result are answered as no, each with its evidence.
run_probe alone_ignored
[ "$status" = 0 ] || fail "alone_ignored: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly alone_ignored
count_of alone_ignored 'Q18 \[agents#1104\] chat text/(sonnet-medium|haiku-fast): no; status 200; the next reply called: no tool, token in its arguments: no, definition-only parameter used: no;' 2
run_probe alone_refused
[ "$status" = 0 ] || fail "alone_refused: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly alone_refused
count_of alone_refused 'Q18 \[agents#1104\] chat text/(sonnet-medium|haiku-fast): no, status 400; status 400; the next reply called: no tool' 2
for alone_case in "${alone_cases[@]}"; do
  IFS='|' read -r case_id _ case_verdict <<<"$alone_case"
  run_probe "$case_id"
  [ "$status" = 0 ] || fail "$case_id: the probe ended $status: $(tail -n 20 <<<"$output")"
  ended_cleanly "$case_id"
  count_of "$case_id" "Q18 \[agents#1104\] chat text/(sonnet-medium|haiku-fast): $case_verdict" 2
done
echo "question 18 answers no for a reference that loads nothing and for a refused result"
echo "question 18 answers from the token, the lane and the billed rise, each of which must hold on its own"

# A run of one question that fails deletes its key; a question that does not run alone makes none.
run_probe alone_failed
[ "$status" = 1 ] || fail "alone_failed: the probe ended $status, not 1"
has alone_failed 'the plain request on chat answered with status 500'
count_of alone_failed '^litellm:gateway-probe: the probe key gateway-probe-[0-9]+-[0-9]+-main is gone$' 1
ended_cleanly alone_failed
run_probe alone_unknown
[ "$status" = 1 ] || fail "alone_unknown: the probe ended $status, not 1"
has alone_unknown 'question 3 does not run alone; those that do: 4 18'
lacks alone_unknown 'the probe key'
ended_cleanly alone_unknown
echo "a run of one question deletes its key when it fails, and an unknown question makes none"

# Question 4 alone answers Q4, Q5, Q6 and Q8 on the chat route for each model it is given and for no other.
run_probe models_given
[ "$status" = 0 ] || fail "models_given: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly models_given
count_of models_given 'Q[0-9]+ \[' 8
for model in text/sonnet text/haiku-low; do
  for question in 4 5 6 8; do count_of models_given "Q$question \[[A-Z0-9 ]+\] chat $model: " 1; done
done
count_of models_given 'Q4 \[[A-Z0-9 ]+\] chat text/(sonnet|haiku-low): yes;' 2
count_of models_given '^litellm:gateway-probe: the probe key gateway-probe-[0-9]+-[0-9]+-main is gone$' 1
lacks models_given 'unbound variable'
has models_given 'Q4 \[[A-Z0-9 ]+\] chat text/sonnet: yes;.*no skill tools [0-9]{4,}'
echo "question 4 alone asks the deferral question of the models it is given and of no others"

# A model that refuses deferred tools is answered as no with its status, and the run ends 0 with its key gone.
run_probe models_refused
[ "$status" = 0 ] || fail "models_refused: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly models_refused
has models_refused 'Q4 \[[A-Z0-9 ]+\] chat text/haiku-low: no, status 400;'
has models_refused 'Q4 \[[A-Z0-9 ]+\] chat text/sonnet-low: yes;'
echo "a model that refuses deferred tools is answered no with its status"

# Without a model argument question 4 asks the pair of the full run.
run_probe models_default
[ "$status" = 0 ] || fail "models_default: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly models_default
count_of models_default 'Q[0-9]+ \[' 8
count_of models_default 'Q4 \[[A-Z0-9 ]+\] chat text/(sonnet-medium|haiku-fast): yes;' 2
echo "question 4 alone without a model argument asks the default pair"

# A model name the gateway does not list as a text name, and a model argument for a question without models, end the run 1 with
# no key made and no paid request sent.
for case_named in models_unlisted:text/nonesuch models_not_text:image/flare models_misplaced:takes.no.--model; do
  case="${case_named%%:*}"
  run_probe "$case"
  [ "$status" = 1 ] || fail "$case: the probe ended $status, not 1: $(tail -n 5 <<<"$output")"
  has "$case" "(${case_named#*:})"
  lacks "$case" 'Q[0-9]+ \['
  lacks "$case" 'the probe key'
  ended_cleanly "$case"
done
echo "a model that is no listed text name ends the run 1 before any key or request"

# A failed run of question 4 deletes its key.
run_probe models_failed
[ "$status" = 1 ] || fail "models_failed: the probe ended $status, not 1"
count_of models_failed '^litellm:gateway-probe: the probe key gateway-probe-[0-9]+-[0-9]+-main is gone$' 1
ended_cleanly models_failed
echo "a failed run of question 4 deletes its key"
