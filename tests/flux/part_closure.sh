#!/usr/bin/env bash
# part_closure.sh <part>|--layers: the layers a part of the cluster job applies, one name per line, sorted: those its
# entry in PARTS_FILE names and every layer they reach through dependsOn in the Kustomizations of LAYERS_DIRECTORY, the
# one owner of that graph. `--layers` prints every layer instead, which is what the part core applies.
set -euo pipefail
# The callers read stdout, so a refusal goes to stderr.
fail() { echo "::error::$1" >&2; exit 1; }
parts_file="${PARTS_FILE:-$(dirname "${BASH_SOURCE[0]}")/parts.yaml}"
layers_directory="${LAYERS_DIRECTORY:-clusters/pc}"
requested="${1:?the part, or --layers}"

declare -A dependencies=()
while read -r layer needed; do
  dependencies["$layer"]="$needed"
done < <(yq --no-doc 'select(.kind == "Kustomization") | .metadata.name + " " + ([.spec.dependsOn[].name] | join(" "))' \
  "$layers_directory"/*.yaml)
[ "${#dependencies[@]}" -gt 0 ] || fail "$layers_directory holds no Kustomization"

if [ "$requested" = --layers ]; then
  printf '%s\n' "${!dependencies[@]}" | sort
  exit 0
fi
declared="$(PART="$requested" yq '.[strenv(PART)].layers' "$parts_file")"
[ "$declared" != null ] || fail "$parts_file declares no part $requested"
if [ "$declared" = all ]; then
  printf '%s\n' "${!dependencies[@]}" | sort
  exit 0
fi

declare -A closure=()
pending=()
mapfile -t pending < <(yq '.[]' <<<"$declared")
while [ "${#pending[@]}" -gt 0 ]; do
  layer="${pending[-1]}"
  unset 'pending[-1]'
  [ -z "${closure[$layer]:-}" ] || continue
  [ -n "${dependencies[$layer]+set}" ] || fail "the part $requested names the layer $layer, which $layers_directory does not hold"
  closure["$layer"]=1
  # shellcheck disable=SC2206 # a layer's dependencies are names without whitespace.
  pending+=(${dependencies[$layer]})
done
[ "${#closure[@]}" -eq 0 ] || printf '%s\n' "${!closure[@]}" | sort
