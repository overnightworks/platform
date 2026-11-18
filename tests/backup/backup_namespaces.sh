#!/usr/bin/env bash
# The one owner of which namespaces back up: those whose layer under infrastructure/ or apps/ includes
# POSTGRES_BACKUP_COMPONENT.
#   no argument: one line per layer, `<layer directory> <namespace>`, in the order the cells loop in.
#   <part>: the namespaces of the layers in that part's closure (tests/flux/part_closure.sh), space separated, which is
#           what the backup cells of the part loop over.
#   --covered-by <part>...: fails naming every namespace that no listed part holds, so a new backup namespace never falls
#           between the parts that run the backup cells.
set -euo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../failure.sh
source "$here/../failure.sh"
# shellcheck source=../layer_includes.sh
source "$here/../layer_includes.sh"
layers_directory="${LAYERS_DIRECTORY:-clusters/pc}"

backup_layers() {
  local layer
  for layer in infrastructure/*/kustomization.yaml apps/*/kustomization.yaml; do
    layer_includes "$layer" components "$POSTGRES_BACKUP_COMPONENT" || continue
    echo "${layer%/kustomization.yaml} $(yq '.namespace' "$layer")"
  done
}

# kustomization_of <layer directory>: the name of the Kustomization of LAYERS_DIRECTORY that applies it.
kustomization_of() {
  local name
  name="$(DIRECTORY="./$1" yq --no-doc 'select(.kind == "Kustomization" and .spec.path == strenv(DIRECTORY)) | .metadata.name' \
    "$layers_directory"/*.yaml)"
  [ -n "$name" ] || fail "no Kustomization of $layers_directory applies $1"
  echo "$name"
}

# namespaces_of_part <part>: the backup namespaces whose layer the part applies, in tree order.
namespaces_of_part() {
  local directory namespace closure
  closure=" $("$here/../flux/part_closure.sh" "$1" | tr '\n' ' ')"
  while read -r directory namespace; do
    [[ $closure == *" $(kustomization_of "$directory") "* ]] && echo "$namespace"
  done < <(backup_layers)
  return 0
}

case "${1:-}" in
  "") backup_layers ;;
  --covered-by)
    shift
    [ "$#" -gt 0 ] || fail "--covered-by names no part"
    held=" $(for part in "$@"; do namespaces_of_part "$part"; done | tr '\n' ' ')"
    missing=
    while read -r _ namespace; do
      [[ $held == *" $namespace "* ]] || missing="$missing $namespace"
    done < <(backup_layers)
    [ -z "$missing" ] || fail "the namespaces$missing back up but no part of: $* holds them"
    echo "the parts $* hold every backup namespace: $(backup_layers | cut -d' ' -f2 | tr '\n' ' ')"
    ;;
  *) namespaces_of_part "$1" | tr '\n' ' ' | sed 's/ $//'; echo ;;
esac
