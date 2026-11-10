#!/usr/bin/env bash
set -euo pipefail
# The job root's overlay adds spec.patches to the root and to the layers below, which would replace committed ones
# without a word (RFC 6902 add).
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
root_file=clusters/pc/flux-system/gotk-sync.yaml
objects="$(kubectl create --dry-run=client -f "$root_file" \
  -o go-template='{{.kind}}{{if .spec.patches}} with spec.patches{{end}}{{"\n"}}')"
case "$(grep '^Kustomization' <<<"$objects" || true)" in
  Kustomization) echo "the root Kustomization in $root_file carries no spec.patches" ;;
  "Kustomization with spec.patches")
    fail "the root Kustomization in $root_file carries spec.patches, which the job root's overlay would replace" ;;
  *) fail "$root_file holds not exactly one Kustomization" ;;
esac
# The job root's overlay patches these layers, one list with it (tests/flux/reconcile_the_candidate_tree.sh).
for layers_file_and_layer in clusters/pc/infrastructure.yaml:tunnel clusters/pc/infrastructure.yaml:nvidia \
  clusters/pc/apps.yaml:songmaker; do
  layers_file="${layers_file_and_layer%%:*}"
  layer="${layers_file_and_layer##*:}"
  objects="$(kubectl create --dry-run=client -f "$layers_file" -o go-template='{{if eq .metadata.name "'"$layer"'"}}
    {{- .kind}}{{if .spec.patches}} with spec.patches{{end}}{{"\n"}}{{end}}')"
  case "$objects" in
    Kustomization) echo "the Kustomization $layer in $layers_file carries no spec.patches" ;;
    "Kustomization with spec.patches")
      fail "the Kustomization $layer in $layers_file carries spec.patches, which the job root's patch would replace" ;;
    *) fail "$layers_file holds not exactly one Kustomization $layer" ;;
  esac
done
