#!/usr/bin/env bash
# Drive `mise run litellm:keys` and `mise run litellm:key` against a fake kubectl and a fake curl, for the outcomes the
# cluster cannot arrange: a write that fails midway stops the rest, names what was made, which one failed and what was
# not made, and prints no reply body, a lost answer included; a failed key registration names the step and the status; a
# budget-only change sends no period; a table that is no table of numbers, a revision that is absent or changes while the
# table is read and a value with a newline are refused before any write; and neither a key's value, the master key nor
# the value's sha256 reaches an argument or any output, tracing included, while the value does reach curl's stdin.
# Usage: mise exec -- tests/litellm/failed_write_names_what_is_done.sh
# Proves docs/commands.md KEYS-2, KEY-1, KEY-2.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
layer="$repository_root/infrastructure/litellm"
master_key=sk-fake-master-key-0001
app_key=sk-fake-app-value-0123456789
reply_body=REPLY-BODY-THAT-MUST-NOT-APPEAR

# The fake answers what the task reads from the cluster; the shipped table, configuration and routes are its data.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in *" sk-"*) echo "fake kubectl: a key in the arguments" >&2; exit 1 ;; esac
case "$*" in
  *"get secret litellm "*) printf '%s' "$FAKE_MASTER_KEY" | base64 --wrap=0 ;;
  *"get service litellm "*) printf 4000 ;;
  *port-forward*) echo "Forwarding from 127.0.0.1:4000 -> 4000"; exec sleep 600 ;;
  *"get configmap litellm-keys"*) cat "$FAKE_LAYER/keys.yaml" ;;
  *"get deployment litellm "*) printf litellm-config ;;
  *"get configmap litellm-config"*) cat "$FAKE_LAYER/litellm-config.yaml" ;;
  *"get deployment litellm-front"*) printf front-routes ;;
  *"get configmap front-routes"*) cat "$FAKE_LAYER/front-route.yml" ;;
  *"get kustomization litellm"*)
    reads="$(cat "$FAKE_STATE/revision-reads" 2>/dev/null || echo 0)"
    echo $((reads + 1)) >"$FAKE_STATE/revision-reads"
    case "$FAKE_REVISION" in
      absent) ;;
      changing) printf 'main@sha1:read-%s' "$reads" ;;
      *) printf 'main@sha1:fake' ;;
    esac ;;
  *"get secret hopin "*) printf '%s' "$FAKE_SECRET_VALUE" | base64 --wrap=0 ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 1 ;;
esac
FAKE
# The fake LiteLLM lists one model and keeps what it is told in FAKE_STATE: the person budget, and for each app but hopin
# a key, which starts with fields that all differ from the table. A write named by FAKE_FAILING_WRITE (a path and a
# body marker) is answered with 500 and a body, or with FAKE_TRANSPORT_FAILURE after it was applied with a lost answer;
# every other write is applied and answered 200. It records each write's path, the body of the updates, and whether the
# key value reached its stdin.
cat >"$fake_bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
path="${url#http://127.0.0.1:4000}"
config="$(cat)"
for argument in "$@"; do
  case "$argument" in *"$FAKE_MASTER_KEY"* | *"$FAKE_APP_KEY"*) echo "fake curl: a key in the arguments" >&2; exit 1 ;; esac
done
case "$config" in *"Bearer $FAKE_MASTER_KEY"*) ;; *) echo "fake curl: no master key on stdin" >&2; exit 1 ;; esac
case "$config" in *"$FAKE_APP_KEY"*) echo "app-key-on-stdin $path" >>"$FAKE_STATE/writes" ;; esac
json() { yq --input-format json --output-format json --indent 0 "$@"; }
status=200 reply='{}'
case "$path" in
  /v1/models) reply='{"data":[{"id":"model-one"}]}' ;;
  /budget/list)
    reply='[]'
    [ ! -f "$FAKE_STATE/budget.json" ] || reply="[$(cat "$FAKE_STATE/budget.json")]" ;;
  "/key/list?key_alias=hopin"*) reply='{"keys":[]}' ;;
  "/key/list?key_alias="*)
    alias="${path#*key_alias=}"
    alias="${alias%%&*}"
    row="$FAKE_STATE/row-$alias.json"
    [ -f "$row" ] || printf '{"key_alias":"%s","token":"hash-%s","max_budget":1,"budget_duration":"1d","max_parallel_requests":1,"models":[],"allowed_routes":[]}' \
      "$alias" "$alias" >"$row"
    reply="{\"keys\":[$(cat "$row")]}" ;;
  *)
    echo "write $path" >>"$FAKE_STATE/writes"
    data="$(grep '^data = ' <<<"$config")"
    data="${data#data = \"}"
    data="$(sed 's/\\"/"/g; s/\\\\/\\/g' <<<"${data%\"}")"
    failing=false
    [ -z "$FAKE_FAILING_WRITE" ] || case "$path $config" in *"$FAKE_FAILING_WRITE"*) failing=true ;; esac
    if [ "$failing" = false ] || [ -n "$FAKE_TRANSPORT_FAILURE" ]; then
      case "$path" in
        /key/update)
          echo "update $data" >>"$FAKE_STATE/bodies"
          target="$(yq --input-format json '.key | sub("^hash-"; "")' <<<"$data")"
          json -i ". * $data" "$FAKE_STATE/row-$target.json" ;;
        /budget/new | /budget/update)
          echo "budget $data" >>"$FAKE_STATE/bodies"
          [ -f "$FAKE_STATE/budget.json" ] || echo '{}' >"$FAKE_STATE/budget.json"
          json -i ". * $data" "$FAKE_STATE/budget.json" ;;
      esac
    fi
    [ "$failing" = false ] || { [ -z "$FAKE_TRANSPORT_FAILURE" ] || exit 28; status=500 reply="$FAKE_REPLY_BODY"; } ;;
esac
case " $* " in *" --output /dev/null "*) reply="" ;; esac
printf '%s\n%s' "$reply" "$status"
FAKE
chmod +x "$fake_bin/kubectl" "$fake_bin/curl"
# mise puts its own kubectl before PATH and the tasks fall back to the PC's kubeconfig, so neither may be reachable.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
[ "$(command -v kubectl)" = "$fake_bin/kubectl" ] || fail "kubectl on PATH is not the fake"
[ "$(command -v curl)" = "$fake_bin/curl" ] || fail "curl on PATH is not the fake"
export FAKE_MASTER_KEY="$master_key" FAKE_APP_KEY="$app_key" FAKE_SECRET_VALUE="$app_key" FAKE_REPLY_BODY="$reply_body"
export FAKE_REVISION=applied FAKE_TRANSPORT_FAILURE=""

budget_id="$(yq '.litellm_settings.max_end_user_budget_id' "$layer/litellm-config.yaml")"
# use_table [<yq expression>]: the layer's files with the table reduced to the test's own rows and then edited, which the
# fake serves from now on. The rows sort as hopin, test-a, test-b, and hopin is the one without a key.
use_table() {
  rm -rf "$work_directory/layer"
  cp -r "$layer" "$work_directory/layer"
  yq -i '.apps = {"hopin": {"budget": 10, "parallel": 5}, "test-a": {"budget": 10, "parallel": 5}, "test-b": {"budget": 10, "parallel": 5}}' \
    "$work_directory/layer/keys.yaml"
  [ -z "${1-}" ] || yq -i "$1" "$work_directory/layer/keys.yaml"
  export FAKE_LAYER="$work_directory/layer"
}
use_table

runner=(mise run)
# run_task <case name> <expected exit> <failing write marker> <task argument>...: runs the task, which must end as
# expected, and sets status, output and writes; a case name used again keeps its fake LiteLLM's state.
run_task() {
  local case_name="$1" expected="$2" secret
  export FAKE_FAILING_WRITE="$3" FAKE_STATE="$work_directory/state-$1"
  shift 3
  mkdir -p "$FAKE_STATE"
  : >"$FAKE_STATE/writes"
  : >"$FAKE_STATE/bodies"
  rm -f "$FAKE_STATE/revision-reads"
  status=0
  output="$(cd "$repository_root" && "${runner[@]}" "$@" 2>&1)" || status=$?
  writes="$(cat "$FAKE_STATE/writes")"
  # A value the task must never print: the keys, and the sha256 of the app key.
  value_hash="$(printf '%s' "$app_key" | sha256sum)"
  for secret in "$master_key" "$app_key" "$reply_body" "${value_hash%% *}"; do
    case "$output" in *"$secret"*) fail "$case_name: the output holds a value or a reply body" ;; esac
  done
  [ "$status" = "$expected" ] || fail "$case_name: exit $status, not $expected: $output"
}

run_task failed-midway 1 /key/update litellm:keys
grep -q "writing key test-a answered with status 500, not 200; made: budget:$budget_id; failed: key:test-a; not made: key:test-b\$" \
  <<<"$output" || fail "failed-midway: the output does not name what was made, what failed and what was not: $output"
grep -q '^litellm:keys: table of revision main@sha1:fake$' <<<"$output" || fail "failed-midway: no revision: $output"
[ "$(grep -c '^write ' <<<"$writes")" = 2 ] ||
  fail "failed-midway: a write ran after the failed one, or the made ones did not run: $writes"
echo "a write that fails midway stops the rest and names what was made, which one failed and what was not, with no reply body"

FAKE_TRANSPORT_FAILURE=1 run_task lost-answer 1 hash-test-a litellm:keys
grep -q "writing key test-a answered with status 000, not 200; made: budget:$budget_id; failed: key:test-a; not made: key:test-b\$" \
  <<<"$output" || fail "lost-answer: the write that may have happened is not named as failed: $output"
FAKE_TRANSPORT_FAILURE=1 run_task lost-last-answer 1 hash-test-b litellm:keys
grep -q 'failed: key:test-b; not made: none$' <<<"$output" ||
  fail "lost-last-answer: the last write is not named as failed with nothing left: $output"
echo "a write whose answer is lost is named as failed, apart from the ones never tried"

run_task failed-registration 1 /key/generate litellm:key hopin
grep -q 'making the key of hopin answered with status 500, not 200' <<<"$output" ||
  fail "failed-registration: the output does not name the step and the status: $output"
grep -q '^litellm:key: table of revision main@sha1:fake$' <<<"$output" || fail "failed-registration: no revision: $output"
[ "$writes" = $'app-key-on-stdin /key/generate\nwrite /key/generate' ] ||
  fail "failed-registration: the value did not reach curl's stdin in one write: $writes"
echo "a failed registration names its step and status, and the value reaches only curl's stdin"

runner=(bash -x "$repository_root/scripts/litellm_keys.sh")
run_task traced-registration 1 /key/generate key hopin
[ "$writes" = $'app-key-on-stdin /key/generate\nwrite /key/generate' ] ||
  fail "traced-registration: the value did not reach curl's stdin in one write: $writes"
runner=(mise run)
echo "a script run under bash -x prints no value"

# A value that is not one printable line is refused before any write, a trailing newline included.
for value in $'sk-fake-app-value-0123456789\n' $'sk-fake-app-value\n0123456789' $'sk-fake-app-value-0123456789\n\n'; do
  FAKE_SECRET_VALUE="$value" run_task newline-value 1 "" litellm:key hopin
  grep -q 'is not one printable line starting with sk-' <<<"$output" || fail "newline-value: the value was not refused as such: $output"
  [ -z "$writes" ] || fail "newline-value: a write ran: $writes"
done
echo "a value with a newline, a trailing one included, is refused before any write"

# A table that is no table of numbers is refused, naming the row, before any write.
table_cases=(
  'no-person-budget~del(.person_budget)~the table.s person_budget is no number'
  'budget-typo~del(.apps.hopin.budget) | .apps.hopin.buget = 12~row hopin has no number budget'
  'budget-text~.apps.hopin.budget = "ten"~row hopin has no number budget'
  'parallel-missing~del(.apps.hopin.parallel)~row hopin has no whole number parallel'
  'row-scalar~.apps.hopin = 5~row hopin is no map'
  'apps-null~.apps = null~apps are no map with a row'
  'apps-number~.apps = 5~apps are no map with a row'
  'apps-empty~.apps = {}~apps are no map with a row'
  'bad-name~.apps.Bad_Name = .apps.hopin~which is no namespace name'
)
for table_case in "${table_cases[@]}"; do
  IFS='~' read -r case_name edit expected <<<"$table_case"
  for task in "litellm:keys" "litellm:key hopin"; do
    use_table "$edit"
    # shellcheck disable=SC2086 # the task and its argument are words
    run_task "$case_name" 1 "" $task
    grep -q "$expected" <<<"$output" || fail "$case_name: $task did not refuse the table as '$expected': $output"
    [ -z "$writes" ] || fail "$case_name: $task wrote: $writes"
  done
done
use_table
echo "a table without a number for the person budget or a row's limits, or without rows, is refused naming the row, with no write"

for revision in absent changing; do
  FAKE_REVISION="$revision" run_task "revision-$revision" 1 "" litellm:keys
  grep -q 'litellm has applied no revision\|applied another revision while the table was read' <<<"$output" ||
    fail "revision-$revision: the revision was not refused as such: $output"
  [ -z "$writes" ] || fail "revision-$revision: a write ran: $writes"
done
echo "an absent revision, or one that changes while the table is read, is refused before any write"

# A budget-only change sends the budget alone, since a resent period would move the reset.
use_table 'del(.apps.hopin)'
run_task budget-only 0 "" litellm:keys
run_task budget-only 0 "" litellm:keys --plan
grep -q ' 0 changes planned' <<<"$output" || fail "budget-only: a second plan differs: $output"
use_table 'del(.apps.hopin) | .apps."test-a".budget += 1'
run_task budget-only 0 "" litellm:keys
[ "$(grep -c '^update ' "$FAKE_STATE/bodies")" = 1 ] || fail "budget-only: not one update: $(cat "$FAKE_STATE/bodies")"
grep -q '^update .*"max_budget"' "$FAKE_STATE/bodies" || fail "budget-only: the update holds no budget: $(cat "$FAKE_STATE/bodies")"
! grep -q 'budget_duration\|"models"\|allowed_routes\|max_parallel' "$FAKE_STATE/bodies" ||
  fail "budget-only: the update holds more than the budget: $(cat "$FAKE_STATE/bodies")"
use_table
echo "a changed budget alone sends the budget and no period"
