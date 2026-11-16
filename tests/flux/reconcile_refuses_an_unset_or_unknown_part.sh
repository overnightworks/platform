#!/usr/bin/env bash
# reconcile_the_candidate_tree.sh fails before it builds an overlay or calls kubectl when CLUSTER_PART is unset or
# names no part, and its message names CLUSTER_PART or the part.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
reconcile="$(realpath "$(dirname "${BASH_SOURCE[0]}")/reconcile_the_candidate_tree.sh")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# expect_refusal <label> <text of the message> <env arguments>...
expect_refusal() {
  local label="$1" expected="$2" output
  shift 2
  if output="$(env RUNNER_TEMP="$scratch" "$@" "$reconcile" 2>&1)"; then fail "the reconcile script passed with $label"; fi
  [[ $output == *"$expected"* ]] || fail "the reconcile script refused $label with '$output', which lacks '$expected'"
  [ -z "$(ls -A "$scratch")" ] || fail "the reconcile script created $(ls "$scratch") with $label"
  echo "the reconcile script refuses $label: $output"
}
expect_refusal "CLUSTER_PART unset" CLUSTER_PART env -u CLUSTER_PART
expect_refusal "an unknown part" "declares no part nosuch" CLUSTER_PART=nosuch
