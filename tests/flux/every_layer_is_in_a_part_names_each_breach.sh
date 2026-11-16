#!/usr/bin/env bash
# every_layer_is_in_a_part.sh passes on a tree whose every layer is in a part and whose globs match tracked files, and names
# an orphan layer, a part that names a missing layer, a glob that matches no tracked file and a core that applies less
# than all layers.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=fixture_layers.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixture_layers.sh"
check="$(dirname "${BASH_SOURCE[0]}")/every_layer_is_in_a_part.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# expect_breach <name> <text of the error>: the fixture, changed as the caller did, fails naming the text.
expect_breach() {
  local output
  if output="$("$check" 2>&1)"; then fail "$1: the check passed"; fi
  [[ $output == *"::error::"*"$2"* ]] || fail "$1: the check printed '$output', which lacks '$2'"
  echo "$1: $2"
}
# fresh <name>: a new fixture, which the case then changes.
fresh() { make_fixture "$scratch/$1"; }

fresh whole
"$check" >/dev/null || fail "the check refuses a tree whose every layer is in a part"
echo "the check passes on a tree whose every layer is in a part"

fresh orphan
yq --inplace '.single.layers = []' "$PARTS_FILE"
expect_breach "an orphan layer" "the layer alone of $LAYERS_DIRECTORY is in the closure of no part but core"

fresh stale
yq --inplace '.single.layers = ["alone", "retired"]' "$PARTS_FILE"
expect_breach "a stale name" "the part single of $PARTS_FILE names the layer retired"

fresh dead_glob
yq --inplace '.chain.paths += ["moved-cells/*"]' "$PARTS_FILE"
expect_breach "a glob that matches nothing" "the glob moved-cells/* of the part chain in $PARTS_FILE matches no tracked file"

fresh partial_core
yq --inplace '.core.layers = ["base"]' "$PARTS_FILE"
expect_breach "a core that applies less" "the part core of $PARTS_FILE does not apply all layers"
