# shellcheck shell=bash
# Sourced by the tests of part_closure.sh and every_layer_is_in_a_part.sh. make_fixture <directory> writes a tree of three
# layers, base, middle (depends on base) and alone, with the parts core, chain (middle) and single (alone), all in the matrix.
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
core: {layers: all}
chain: {layers: [middle]}
single: {layers: [alone]}
YAML
  cat >"$directory/workflow.yaml" <<'YAML'
jobs:
  cluster:
    strategy:
      matrix:
        part: [core, chain, single]
YAML
  export LAYERS_DIRECTORY="$directory/clusters" PARTS_FILE="$directory/parts.yaml" WORKFLOW_FILE="$directory/workflow.yaml"
}
