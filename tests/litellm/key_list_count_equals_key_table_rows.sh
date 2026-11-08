#!/usr/bin/env bash
# Through the PC's k3s and a port-forward to LiteLLM, compares the total of keys /key/list counts with the rows of the
# layer's key table in LiteLLM's Postgres that /key/list can list: LiteLLM v1.106.6 leaves out the rows whose team_id is
# the dashboard's UI session id. Prints the table's rows, the rows LiteLLM does not list, the rows it lists and the
# total it counts, then equal or DIFFERS, never a key; exits 1 when they differ or a step fails, naming the step and,
# when one ended it, the deadline.
set -euo pipefail
usage="usage: $0 <namespace>: the operator's to run, since it reads LiteLLM's master key from the Secret litellm"
[ "$#" = 1 ] || {
  echo "$usage" >&2
  exit 2
}
namespace="$1"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# LiteLLM's constant UI_SESSION_TOKEN_TEAM_ID, the team_id of the dashboard's session tokens, which /key/list omits.
ui_session_team_id=litellm-dashboard
# A kubectl call ends past the deadline, a connection attempt past 10 s, a statement past 60 s and a lock wait past
# 10 s, as a lock the operator's session holds could otherwise hold this command forever.
deadline=2m
fail() {
  echo "key count: $1" >&2
  exit 1
}
# bounded <step> <command>...: runs the command under the deadline; fails naming the step when it fails or runs out.
bounded() {
  local step="$1" status=0
  shift
  timeout "$deadline" "$@" || status=$?
  [ "$status" != 124 ] || fail "$step did not end within $deadline, the local deadline"
  return "$status"
}
in_postgres() {
  bounded "$1" kubectl --namespace "$namespace" exec postgres-0 --container postgres -- \
    env PGCONNECT_TIMEOUT=10 PGOPTIONS='-c statement_timeout=60s -c lock_timeout=10s' "${@:2}"
}
scratch="$(mktemp -d)"
forward=""
trap '[ -z "$forward" ] || kill "$forward" 2>/dev/null || true; rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

secret_data="$(bounded "reading the Secret litellm in $namespace" kubectl --namespace "$namespace" get secret litellm \
  -o jsonpath='{.data.master_key}')" || fail "the Secret litellm in $namespace cannot be read"
master_key="$(base64 --decode <<<"$secret_data")" ||
  fail "the Secret litellm in $namespace gives no readable master_key"
[ -n "$master_key" ] || fail "the Secret litellm in $namespace holds an empty master_key"
port="$(bounded "reading the Service litellm in $namespace" kubectl --namespace "$namespace" get service litellm \
  -o jsonpath='{.spec.ports[0].port}')" ||
  fail "the Service litellm in $namespace cannot be read"

timeout 10m kubectl --namespace "$namespace" port-forward service/litellm ":$port" >"$scratch/forward.log" 2>&1 &
forward=$!
local_port=""
for _ in $(seq 30); do
  local_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$scratch/forward.log" | head -n 1)"
  [ -z "$local_port" ] || break
  kill -0 "$forward" 2>/dev/null || fail "kubectl port-forward to the Service litellm ended: $(cat "$scratch/forward.log")"
  sleep 1
done
[ -n "$local_port" ] || fail "kubectl port-forward to the Service litellm did not start within 30 seconds"

# The key goes to curl on stdin, never into an argument another process could read.
escaped_key="${master_key//\\/\\\\}"
escaped_key="${escaped_key//\"/\\\"}"
listing="$(curl --silent --show-error --fail --max-time 60 --config - "http://127.0.0.1:$local_port/key/list?size=1" \
  <<<"header = \"Authorization: Bearer $escaped_key\"")" || fail "LiteLLM's /key/list did not answer with 200"
listed="$(yq --input-format json '.total_count' <<<"$listing")"
[[ $listed =~ ^[0-9]+$ ]] || fail "LiteLLM's /key/list answered without a total_count"

# The table's name comes from key-tables beside the check; exactly one is required.
tables="$(in_postgres "reading the key tables of $namespace's Postgres" cat /etc/postgres-checks/key-tables)" ||
  fail "the key tables of $namespace's Postgres cannot be read"
[[ $tables =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "the key tables of $namespace's Postgres are not exactly one table name"
table="$tables"
# psql's stderr stays in the container, since a message of it may quote data.
counts="$(in_postgres "counting the key table $table in $namespace's Postgres" sh -c 'exec psql --no-psqlrc \
  --tuples-only --no-align --field-separator=" " --set=ON_ERROR_STOP=1 --command="$1" 2>/dev/null' sh \
  "SELECT count(*), count(*) FILTER (WHERE team_id = '$ui_session_team_id') FROM \"$table\"")" ||
  fail "counting the key table $table in $namespace's Postgres failed"
read -r rows unlisted <<<"$counts"
[[ ${rows-} =~ ^[0-9]+$ && ${unlisted-} =~ ^[0-9]+$ ]] || fail "the count of the key table $table gave no two numbers"
listable=$((rows - unlisted))

if [ "$listed" = "$listable" ]; then verdict=equal; else verdict=DIFFERS; fi
echo "key table $table holds $rows rows, $unlisted of the UI session which LiteLLM does not list, $listable it lists;" \
  "LiteLLM lists $listed: $verdict"
[ "$verdict" = equal ]
