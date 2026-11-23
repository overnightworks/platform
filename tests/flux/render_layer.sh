#!/usr/bin/env bash
# Sourced: render_layer <directory> <output file> renders one Flux layer as Flux does, the one owner of that rule: with
# `kubectl kustomize` where the directory holds a kustomization.yaml, kustomization.yml or Kustomization, else as the
# generated kustomization of every *.yaml and *.yml file in its tree. It returns 1 where the render fails, printing the
# reason on one line on stdout, and 2, naming the subdirectories on stdout, where a directory without a kustomization
# holds one below it, which Flux would render as a resource of its own and this function does not.

# layer_has_kustomization <directory>: Flux's own test for a directory that carries a kustomization.
layer_has_kustomization() {
  [ -f "$1/kustomization.yaml" ] || [ -f "$1/kustomization.yml" ] || [ -f "$1/Kustomization" ]
}

render_layer() {
  local directory="$1" output="$2" nested files reason
  if layer_has_kustomization "$directory"; then
    reason="$(kubectl kustomize "$directory" 2>&1 >"$output")" || { echo "${reason//$'\n'/ }"; return 1; }
    return
  fi
  nested="$(find "$directory" -mindepth 2 \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) -type f -printf '%h\n' | sort -u)"
  if [ -n "$nested" ]; then
    echo "${nested//$'\n'/, }"
    return 2
  fi
  files="$(find "$directory" \( -name '*.yaml' -o -name '*.yml' \) -type f | sort)"
  [ -n "$files" ] || { : >"$output"; return; }
  # shellcheck disable=SC2086 # one path per line, none with a space
  reason="$(yq eval-all '.' $files 2>&1 >"$output")" || { echo "${reason//$'\n'/ }"; return 1; }
}
