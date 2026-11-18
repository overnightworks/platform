# shellcheck shell=bash
# Sourced by the scripts under tests/.
# layer_includes <kustomization file> <resources|components> <directory>: the field of the layer names the directory, or,
# for resources, a layer inside its own directory does. Components are not followed.
layer_includes() {
  local layer="$1" field="$2" directory entry resolved
  directory="$(realpath --canonicalize-missing "$3")"
  while IFS= read -r entry; do
    resolved="$(realpath --canonicalize-missing "${layer%/*}/$entry")"
    [ "$resolved" != "$directory" ] || return 0
    if [ "$field" = resources ] && [[ $resolved == "$(realpath "${layer%/*}")"/* ]] && [ -f "$resolved/kustomization.yaml" ]; then
      ! layer_includes "$resolved/kustomization.yaml" resources "$3" || return 0
    fi
  done < <(FIELD="$field" yq '.[strenv(FIELD)] // [] | .[]' "$layer")
  return 1
}
