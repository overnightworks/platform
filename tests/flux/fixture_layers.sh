# shellcheck shell=bash
# Sourced by the tests of part_closure.sh, every_layer_is_in_a_part.sh and parts_for_paths.sh. make_fixture <directory>
# writes a git repository of three layers, base, middle (depends on base) and alone, with their directories and a few
# other files, and the parts core, chain (middle), single (alone) and nightly (middle, nightly only).
make_fixture() {
  local directory="$1"
  mkdir -p "$directory/clusters"
  cat >"$directory/clusters/layers.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: base, namespace: flux-system}
spec: {path: ./base}
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: middle, namespace: flux-system}
spec: {path: ./middle, dependsOn: [{name: base}]}
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: alone, namespace: flux-system}
spec: {path: ./alone}
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: {name: not-a-layer, namespace: flux-system}
YAML
  cat >"$directory/parts.yaml" <<'YAML'
core: {layers: all, paths: [docs/*, "*.md"]}
chain: {layers: [middle], paths: [chain-cells/*]}
single: {layers: [alone]}
nightly: {layers: [middle], nightly_only: true, paths: [nightly-cells/*]}
YAML
  mkdir -p "$directory/base" "$directory/middle" "$directory/alone" "$directory/docs" "$directory/chain-cells" "$directory/nightly-cells"
  touch "$directory/base/file" "$directory/middle/file" "$directory/alone/file" "$directory/docs/guide.txt" "$directory/README.md" \
    "$directory/chain-cells/cell.sh" "$directory/nightly-cells/cell.sh" "$directory/unclaimed.txt"
  git -C "$directory" init --quiet
  git -C "$directory" add .
  export LAYERS_DIRECTORY="$directory/clusters" PARTS_FILE="$directory/parts.yaml" TREE_DIRECTORY="$directory"
}
