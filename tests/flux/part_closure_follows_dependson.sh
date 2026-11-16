#!/usr/bin/env bash
# part_closure.sh prints a part's layers and what they depend on, all layers for core and --layers, and refuses an
# unknown part and a part that names a missing layer, on stderr.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=fixture_layers.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixture_layers.sh"
part_closure="$(dirname "${BASH_SOURCE[0]}")/part_closure.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
make_fixture "$scratch"

# expect_layers <part> <expected layers, space separated>
expect_layers() {
  local actual
  actual="$("$part_closure" "$1" | tr '\n' ' ')"
  [ "$actual" = "$2 " ] || fail "the closure of $1 is '$actual', not '$2'"
  echo "the closure of $1 is: $2"
}
expect_layers chain "base middle"
expect_layers single "alone"
expect_layers core "alone base middle"
expect_layers --layers "alone base middle"

# expect_refusal <part> <text of the message>
expect_refusal() {
  local output
  if output="$("$part_closure" "$1" 2>&1 >/dev/null)"; then fail "part_closure.sh $1 passed"; fi
  [[ $output == *"$2"* ]] || fail "part_closure.sh $1 refused with '$output', which lacks '$2'"
  echo "part_closure.sh $1 refuses: $output"
}
expect_refusal nosuch "declares no part nosuch"
yq --inplace '.chain.layers = ["missing"]' "$PARTS_FILE"
expect_refusal chain "names the layer missing"
