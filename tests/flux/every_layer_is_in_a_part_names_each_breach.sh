#!/usr/bin/env bash
# every_layer_is_in_a_part.sh passes on a tree whose every layer is in a part and whose parts are the matrix's, and names
# an orphan layer, a part that names a missing layer, a part outside the matrix, a matrix leg outside the parts and a core
# that applies less than all layers.
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

fresh unlisted
yq --inplace '.parts_outside_the_matrix = {"layers": ["alone"]}' "$PARTS_FILE"
expect_breach "a part outside the matrix" "the part parts_outside_the_matrix of $PARTS_FILE is no leg of the matrix"

fresh unplanned
yq --inplace '.jobs.cluster.strategy.matrix.part += ["unplanned"]' "$WORKFLOW_FILE"
expect_breach "a leg outside the parts" "runs the part unplanned, which $PARTS_FILE does not declare"

fresh partial_core
yq --inplace '.core.layers = ["base"]' "$PARTS_FILE"
expect_breach "a core that applies less" "the part core of $PARTS_FILE does not apply all layers"
