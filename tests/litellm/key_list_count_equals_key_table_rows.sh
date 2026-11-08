#!/usr/bin/env bash
# Through the PC's k3s and a port-forward to LiteLLM, compares the total of keys /key/list counts with the row count of
# the layer's key table in LiteLLM's Postgres, as the check of key-tables counts it. Prints both counts and equal or
# DIFFERS, never a key; exits 1 when they differ or a step fails, naming the step.
set -euo pipefail
usage="usage: $0 <namespace>: the operator's to run, since it reads LiteLLM's master key from the Secret litellm"
[ "$#" = 1 ] || {
  echo "$usage" >&2
  exit 2
}
namespace="$1"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fail() {
  echo "key count: $1" >&2
  exit 1
}
scratch="$(mktemp -d)"
forward=""
trap '[ -z "$forward" ] || kill "$forward" 2>/dev/null || true; rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

master_key="$(kubectl --namespace "$namespace" get secret litellm -o jsonpath='{.data.master_key}' | base64 --decode)" ||
  fail "the Secret litellm in $namespace gives no readable master_key"
[ -n "$master_key" ] || fail "the Secret litellm in $namespace holds an empty master_key"
port="$(kubectl --namespace "$namespace" get service litellm -o jsonpath='{.spec.ports[0].port}')" ||
  fail "the Service litellm in $namespace cannot be read"

kubectl --namespace "$namespace" port-forward service/litellm ":$port" >"$scratch/forward.log" 2>&1 &
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

counts="$(kubectl --namespace "$namespace" exec postgres-0 --container postgres -- \
  sh /etc/postgres-checks/check-key-tables.sh --counts-only)" || fail "the key-table check in $namespace's Postgres failed"
[[ $counts =~ ^([^:$'\n']+):\ ([0-9]+)\ rows$ ]] ||
  fail "the key-table check in $namespace's Postgres counts not exactly one table: $counts"
table="${BASH_REMATCH[1]}" rows="${BASH_REMATCH[2]}"

if [ "$listed" = "$rows" ]; then verdict=equal; else verdict=DIFFERS; fi
echo "LiteLLM lists $listed keys, its key table $table holds $rows rows: $verdict"
[ "$verdict" = equal ]
