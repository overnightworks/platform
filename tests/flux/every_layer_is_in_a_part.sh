#!/usr/bin/env bash
# Every layer Kustomization of LAYERS_DIRECTORY is in the closure of a part other than core, so a scoped part applies it;
# every layer a part of PARTS_FILE names exists; core applies all layers; and the parts of PARTS_FILE are the parts of the
# cluster job's matrix in WORKFLOW_FILE. Names each breach and fails after the last.
set -euo pipefail
export PARTS_FILE="${PARTS_FILE:-$(dirname "${BASH_SOURCE[0]}")/parts.yaml}"
export LAYERS_DIRECTORY="${LAYERS_DIRECTORY:-clusters/pc}"
workflow_file="${WORKFLOW_FILE:-.github/workflows/ci.yml}"
part_closure="$(dirname "${BASH_SOURCE[0]}")/part_closure.sh"

breaches=0
breach() {
  echo "::error::$1"
  breaches=$((breaches + 1))
}

mapfile -t layers < <("$part_closure" --layers)
mapfile -t parts < <(yq 'keys | .[]' "$PARTS_FILE")
mapfile -t matrix_parts < <(yq '.jobs.cluster.strategy.matrix.part[]' "$workflow_file")

for part in "${parts[@]}"; do
  if ! printf '%s\n' "${matrix_parts[@]}" | grep -qxF "$part"; then
    breach "the part $part of $PARTS_FILE is no leg of the matrix in $workflow_file"
  fi
done
for part in "${matrix_parts[@]}"; do
  if ! printf '%s\n' "${parts[@]}" | grep -qxF "$part"; then
    breach "the matrix in $workflow_file runs the part $part, which $PARTS_FILE does not declare"
  fi
done

[ "$(yq '.core.layers' "$PARTS_FILE")" = all ] || breach "the part core of $PARTS_FILE does not apply all layers"

declare -A in_a_scoped_part=()
for part in "${parts[@]}"; do
  [ "$part" != core ] || continue
  stale=0
  while IFS= read -r layer; do
    if ! printf '%s\n' "${layers[@]}" | grep -qxF "$layer"; then
      breach "the part $part of $PARTS_FILE names the layer $layer, which $LAYERS_DIRECTORY does not hold"
      stale=1
    fi
  done < <(PART="$part" yq '.[strenv(PART)].layers[]' "$PARTS_FILE")
  [ "$stale" -eq 0 ] || continue
  while IFS= read -r layer; do in_a_scoped_part["$layer"]=1; done < <("$part_closure" "$part")
done
for layer in "${layers[@]}"; do
  [ -n "${in_a_scoped_part[$layer]:-}" ] || breach "the layer $layer of $LAYERS_DIRECTORY is in the closure of no part but core"
done

[ "$breaches" -eq 0 ] || exit 1
echo "every one of ${#layers[@]} layers is in a part's closure, and the ${#parts[@]} parts are the matrix's"
