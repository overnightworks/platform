#!/usr/bin/env bash
# Drive `scripts/litellm_gateway_probe.sh` against a fake kubectl and a fake gateway (fake_gateway.py), for the outcomes
# the live gateway cannot arrange: a healthy run answers question 12, 13 and 14 on each route and model and question 10
# at every size on both models with chat measured on its own cache, ends 0 with its keys deleted and the cost of the
# successful spend log rows, and keeps its port-forward past everything it waits for; a key that cannot be deleted ends the
# run 1 although every question was answered; the budget answer is yes only when both routes refuse for the budget; a read
# short by the conversation after the system text is no read of what was cached, and a keep-alive is judged by the row of
# its last request; a spend log that lacks a successful row ends the run 1 although failed rows exist; a failed run ends
# its port-forward, deletes its keys and its scratch directory; `--remove` deletes the probe keys of every page of the key
# list and no other; and no key's value or hash reaches the argument of any command.
# Usage: mise exec -- tests/litellm/gateway_probe_answers_on_both_routes_and_removes_its_keys.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
master_key=sk-fake-master-key-0001
real_timeout="$(command -v timeout)"
real_curl="$(command -v curl)"
server_pid=""
stop_all() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ ! -f "$work_directory/forward-pids" ] || xargs -r kill <"$work_directory/forward-pids" 2>/dev/null || true
  rm -rf "$work_directory"
}
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The fake tools read their directories and the fake master key from the environment, and find the real tool behind them on
# the path without the directory of the fakes.
export FAKE_BIN="$fake_bin" FAKE_WORK="$work_directory" FAKE_MASTER_KEY="$master_key"
# A tool of the probe refuses a key's value or a sha256 in its arguments, which a process list shows.
cat >"$work_directory/guard" <<'GUARD'
#!/usr/bin/env bash
tool="${0##*/}"
for argument in "$@"; do
  if [[ $argument == *sk-* || $argument =~ [0-9a-f]{64} ]]; then
    echo "$tool had a key or a hash in its arguments" >>"$FAKE_WORK/violations"
    exit 1
  fi
done
exec "$(PATH="${PATH#"$FAKE_BIN:"}" command -v "$tool")" "$@"
GUARD
chmod +x "$work_directory/guard"
for tool in curl grep awk yq sed tr cut sha256sum head seq od; do
  ln -s "$work_directory/guard" "$fake_bin/$tool"
done
# The waits end at once, so that the run does not last half an hour; each is recorded.
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

# run_probe <name> <faults> <seeded keys> <argument>...: runs the probe against a new fake gateway with the faults; sets
# status, output and the aliases the gateway holds afterwards.
run_probe() {
  local name="$1" faults="$2" seeded="$3" port
  shift 3
  rm -f "$work_directory/sleeps" "$work_directory/forward-limits" "$work_directory/forward-pids" "$work_directory/violations"
  mkdir "$work_directory/tmp-$name"
  python3 -I "$repository_root/tests/litellm/fake_gateway.py" "$master_key" "$faults" "$seeded" >"$work_directory/port-$name" &
  server_pid=$!
  until_port() { [ -s "$work_directory/port-$name" ]; }
  until_true 30 "the fake gateway listens" until_port
  port="$(<"$work_directory/port-$name")"
  status=0
  FAKE_PORT="$port" PATH="$fake_bin:$PATH" KUBECONFIG=/nonexistent MISE_DISABLE_TOOLS=kubectl TMPDIR="$work_directory/tmp-$name" \
    "$real_timeout" 900 "$repository_root/scripts/litellm_gateway_probe.sh" "$@" >"$work_directory/output-$name" 2>&1 || status=$?
  output="$(<"$work_directory/output-$name")"
  held="$("$real_curl" --silent "http://127.0.0.1:$port/__keys" | yq '.[]')"
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  [ ! -f "$work_directory/violations" ] || fail "$name: $(<"$work_directory/violations")"
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
  local pid
  [ -z "$(ls -A "$work_directory/tmp-$1")" ] || fail "$1: the scratch directory stays: $(ls "$work_directory/tmp-$1")"
  if [ -f "$work_directory/forward-pids" ]; then
    while read -r pid; do ! kill -0 "$pid" 2>/dev/null || fail "$1: the port-forward $pid still runs"; done <"$work_directory/forward-pids"
  fi
  [ -z "$held" ] || fail "$1: the gateway still holds the keys: $held"
}

# A run with a healthy gateway.
run_probe healthy "" 0
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
has healthy '^litellm:gateway-probe: total cost [0-9.]+ USD from [0-9]+ spend log rows'
echo "a healthy run answers on both routes and models, deletes both keys and prints the cost"
# The forward outlives every wait of the run; the limit is read in minutes.
limit_seconds="$(awk '{ sub(/m$/, ""); print $1 * 60 }' "$work_directory/forward-limits")"
slept_seconds="$(awk '{ sum += $1 } END { print sum }' "$work_directory/sleeps")"
[ "$limit_seconds" -gt "$slept_seconds" ] || fail "healthy: the port-forward ends after $limit_seconds s, within the $slept_seconds s the run waits"
echo "the port-forward lives longer than everything the run waits for"

# An 800k call is sent only when the cost so far plus its worst case fits the key's budget: a write dearer than the whole
# budget is never sent, and a spend that leaves room for the prefix of the nominal 800k tokens but not for the most input
# tokens the model takes, which the write has no measured size to lower, is read from the spend log.
for case in dear_writes spendy_calls heavy_first_call; do
  run_probe "$case" "$case" 0
  [ "$status" = 0 ] || fail "$case: the probe ended $status: $(tail -n 20 <<<"$output")"
  ended_cleanly "$case"
  for model in text/sonnet-medium text/haiku-fast; do
    has "$case" "Q10 \[O5 F6\] $model: not run: the key's budget; the write of a 800000-token prefix: the probe keys spent [0-9.]+ USD"
    count_of "$case" "Q10 \[O5 F6\] $model: " 3
  done
done
echo "an 800k call whose worst case passes the key's budget is not run"

# A read the budget has no room for is not sent: the chat write after a dear messages write, and a read of a cache that the
# write did not make, which costs the full price of its prefix.
stop_line="the next call was not run, the key's budget: the probe keys spent [0-9.]+ USD, this call costs at worst"
run_probe dear_chat_write "dear_misses" 0
[ "$status" = 0 ] || fail "dear_chat_write: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly dear_chat_write
has dear_chat_write "Q10 \[O5 F6\] text/sonnet-medium: messages [0-9]+ ms, chat ms; .*reads: messages [0-9]+\(status 200\), chat; $stop_line"
run_probe no_cache_reads "no_cache,dear_misses" 0
[ "$status" = 0 ] || fail "no_cache_reads: the probe ended $status: $(tail -n 20 <<<"$output")"
ended_cleanly no_cache_reads
has no_cache_reads "Q10 \[O5 F6\] text/sonnet-medium: messages ms, chat ms; .*reads: messages, chat; $stop_line"
echo "an 800k read is not sent when the budget has no room for what it costs without the cache"

# A key that cannot be deleted ends the run 1; a budget that /v1/messages does not enforce is no yes.
run_probe undeletable "delete_fails,messages_ignores_budget" 0
[ "$status" = 1 ] || fail "undeletable: the probe ended $status, not 1: $(tail -n 5 <<<"$output")"
has undeletable 'the probe key gateway-probe-[0-9]+-[0-9]+-main may remain'
has undeletable 'Q9 \[O4\] messages text/haiku-fast: no;'
echo "a key that stays ends the run 1, and a budget only chat enforces is answered no"

# A refusal that names no budget, a read short by the tail of the conversation, a keep-alive refused with max_tokens 0 and
# a spend log without a successful row.
run_probe doubtful "unnamed_budget_refusal,short_read,refuse_zero,drop_row" 0
[ "$status" = 1 ] || fail "doubtful: the probe ended $status, not 1: $(tail -n 5 <<<"$output")"
has doubtful 'Q9 \[O4\] messages text/haiku-fast: no;'
has doubtful 'Q2 \[O3\] messages text/sonnet-medium: no read'
has doubtful 'Q15 \[O12 F12\] messages text/sonnet-medium: no;.*max_tokens 1: status 200.*spend log row of the last keep-alive request, which the budget counts: spend 0\.001, completion 1,'
has doubtful 'the total cost is incomplete'
ended_cleanly doubtful
echo "an unnamed refusal, a short read, a refused keep-alive and a missing row are each answered as what they are"

# A run that fails at its first plain request leaves nothing behind.
run_probe failed "chat_fails" 0
[ "$status" = 1 ] || fail "failed: the probe ended $status, not 1"
has failed 'the plain request on chat answered with status 500'
ended_cleanly failed
echo "a failed run ends its port-forward, its scratch directory and its keys"

# --remove reaches a probe key on the second page of the list and leaves the other keys.
run_probe remove "" 120 --remove
[ "$status" = 0 ] || fail "remove: the probe ended $status: $(tail -n 5 <<<"$output")"
[ "$(grep -c '^an-app-key-' <<<"$held")" = 120 ] || fail "remove: the gateway holds not its 120 other keys: $held"
! grep -q '^gateway-probe-' <<<"$held" || fail "remove: a probe key stays: $(grep '^gateway-probe-' <<<"$held")"
echo "--remove deletes the probe keys of every page of the list and no other key"
