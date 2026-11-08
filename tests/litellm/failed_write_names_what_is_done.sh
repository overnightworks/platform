#!/usr/bin/env bash
# Drive `mise run litellm:keys` and `mise run litellm:key` against a fake kubectl and a fake curl, for the outcomes the
# cluster cannot arrange: a write that fails midway stops the rest, names what was made and what was not, and prints no
# reply body; a failed key registration names the step and the status; and neither a key's value, the master key nor
# the value's sha256 reaches an argument or any output, while the value does reach curl's stdin.
# Usage: mise exec -- tests/litellm/failed_write_names_what_is_done.sh
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
  *"get kustomization litellm"*) printf 'main@sha1:fake' ;;
  *"get secret hopin "*) printf '%s' "$FAKE_APP_KEY" | base64 --wrap=0 ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 1 ;;
esac
FAKE
# The fake LiteLLM lists one model, no budget, and for each app but hopin a key whose fields all differ from the table;
# it answers the write named by FAKE_FAILING_WRITE (a path and a body marker) with 500 and a body, every other with 200.
# It records each write's path and whether the key value reached its stdin.
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
status=200 body='{}'
case "$path" in
  /v1/models) body='{"data":[{"id":"model-one"}]}' ;;
  /budget/list) body='[]' ;;
  "/key/list?key_alias=hopin"*) body='{"keys":[]}' ;;
  "/key/list?key_alias="*)
    alias="${path#*key_alias=}"
    alias="${alias%%&*}"
    body="{\"keys\":[{\"key_alias\":\"$alias\",\"token\":\"hash-$alias\",\"max_budget\":1,\"budget_duration\":\"1d\",\"max_parallel_requests\":1,\"models\":[],\"allowed_routes\":[]}]}" ;;
  *)
    echo "write $path" >>"$FAKE_STATE/writes"
    case "$path $config" in *"$FAKE_FAILING_WRITE"*) status=500 body="$FAKE_REPLY_BODY" ;; esac ;;
esac
case " $* " in *" --output /dev/null "*) body="" ;; esac
printf '%s\n%s' "$body" "$status"
FAKE
chmod +x "$fake_bin/kubectl" "$fake_bin/curl"
# mise puts its own kubectl before PATH and the tasks fall back to the PC's kubeconfig, so neither may be reachable.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
[ "$(command -v kubectl)" = "$fake_bin/kubectl" ] || fail "kubectl on PATH is not the fake"
[ "$(command -v curl)" = "$fake_bin/curl" ] || fail "curl on PATH is not the fake"
export FAKE_MASTER_KEY="$master_key" FAKE_APP_KEY="$app_key" FAKE_LAYER="$layer" FAKE_REPLY_BODY="$reply_body"

# run_task <case name> <failing write marker> <task argument>...: runs the task and sets status, output and writes.
run_task() {
  local case_name="$1"
  export FAKE_FAILING_WRITE="$2" FAKE_STATE="$work_directory/state-$1"
  shift 2
  mkdir "$FAKE_STATE"
  touch "$FAKE_STATE/writes"
  status=0
  output="$(cd "$repository_root" && mise run "$@" 2>&1)" || status=$?
  writes="$(cat "$FAKE_STATE/writes")"
  [ "$status" != 0 ] || fail "$case_name: the task succeeded"
  # A value the task must never print: the keys, and the sha256 of the app key.
  value_hash="$(printf '%s' "$app_key" | sha256sum)"
  for secret in "$master_key" "$app_key" "$reply_body" "${value_hash%% *}"; do
    case "$output" in *"$secret"*) fail "$case_name: the output holds a value or a reply body: $output" ;; esac
  done
}

run_task failed-midway /key/update litellm:keys
[ "$status" = 1 ] || fail "failed-midway: exit $status, not 1: $output"
grep -q 'writing key presentator answered with status 500, not 200; made: budget:person-monthly; not made: key:presentator key:songmaker' \
  <<<"$output" || fail "failed-midway: the output does not name what was made and what was not: $output"
[ "$(grep -c '^write ' <<<"$writes")" = 2 ] ||
  fail "failed-midway: a write ran after the failed one, or the made ones did not run: $writes"
echo "a write that fails midway stops the rest and names what was made and what was not, with no reply body"

run_task failed-registration /key/generate litellm:key hopin
[ "$status" = 1 ] || fail "failed-registration: exit $status, not 1: $output"
grep -q 'making the key of hopin answered with status 500, not 200' <<<"$output" ||
  fail "failed-registration: the output does not name the step and the status: $output"
[ "$writes" = $'app-key-on-stdin /key/generate\nwrite /key/generate' ] ||
  fail "failed-registration: the value did not reach curl's stdin in one write: $writes"
echo "a failed registration names its step and status, and the value reaches only curl's stdin"
