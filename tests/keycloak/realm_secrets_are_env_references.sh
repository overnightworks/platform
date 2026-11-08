#!/usr/bin/env bash
# realm_secrets_are_env_references.sh <realm file>...: every value whose key ends in secret or password, in any case,
# is exactly one $(env:NAME) reference, which config-cli fills from its environment. Names each offending file and
# key path, never the value; exits 1 when one exists.
set -euo pipefail
# yq reads \( inside a string as an interpolation, so the reference's characters stand in brackets.
offending_keys='.. | select(path | length > 0) | select(path | .[-1] | tag == "!!str")
  | select(path | .[-1] | test("(?i)(secret|password)$"))
  | select([.] | map(select(tag == "!!str") | select(test("^[$][(]env:[A-Za-z_][A-Za-z0-9_]*[)]$"))) | length == 0)
  | path | map(tostring) | join(".")'
[ "$#" -gt 0 ] || { echo "::error::no realm file given"; exit 1; }
offending=0
for realm_file in "$@"; do
  keys="$(yq "$offending_keys" "$realm_file")" || { echo "::error::$realm_file cannot be read as YAML"; exit 1; }
  while IFS= read -r key; do
    [ -z "$key" ] || { echo "::error::$realm_file: $key holds no \$(env:NAME) reference"; offending=1; }
  done <<<"$keys"
done
[ "$offending" = 0 ] || exit 1
echo "every secret or password in $* is an \$(env:NAME) reference"
