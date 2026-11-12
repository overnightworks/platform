#!/usr/bin/env bash
# Usage: tests/workloads/pull_layers_mount_every_app_ref_their_app_runs.sh
# Needs kubectl and yq, and GITHUB_REPOSITORY_OWNER, whose registry path holds the app refs.
# For every app with a pull layer (apps/<app>/pull), renders apps/<app> and apps/<app>/pull and judges that each app ref
# the app's layer renders is the reference of an image volume of the pull layer's Job, and that a container of the Job
# mounts every image volume, since the kubelet reports a failed pull of an image volume only for a container that
# mounts it. It then runs the same judgement on each case under pull_layer_cases/ (the case's files laid over base/ and
# over a copy of infrastructure/pull) and compares the problems with the case's expected-problems.txt.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

: "${GITHUB_REPOSITORY_OWNER:?the owner whose ghcr.io path holds the app refs}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cases_directory="$(dirname "${BASH_SOURCE[0]}")/pull_layer_cases"
POD_SPEC='(.spec.template.spec // .spec.jobTemplate.spec.template.spec // (select(.kind == "Pod") | .spec)) | select(. != null)'
CONTAINERS='[.containers[], .initContainers[]]'
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

# render <root> <layer directory> <file>: kubectl kustomize of the layer, or the reason it failed on stderr.
render() { kubectl kustomize "$1/$2" >"$3"; }

# judge_pull_layers <root>: prints one problem line for each app ref that its pull layer does not mount and each image
# volume that no container mounts, and one for a layer that does not render.
judge_pull_layers() {
  local root="$1" pull_directory app app_render pull_render app_refs pull_refs name
  for pull_directory in "$root"/apps/*/pull; do
    [ -d "$pull_directory" ] || continue
    app="$(basename "$(dirname "$pull_directory")")"
    app_render="$work_directory/$app.yaml" pull_render="$work_directory/$app-pull.yaml"
    render "$root" "apps/$app" "$app_render" 2>&1 || { echo "problem: apps/$app does not render"; continue; }
    render "$root" "apps/$app/pull" "$pull_render" 2>&1 || { echo "problem: apps/$app/pull does not render"; continue; }
    app_refs="$(yq --no-doc "select(.kind != \"PodConfig\") | $POD_SPEC | ($CONTAINERS | .[].image), (.volumes[] | select(has(\"image\")) | .image.reference)" "$app_render" |
      grep -F "ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/" | sort -u || true)"
    pull_refs="$(yq --no-doc "select(.kind == \"Job\") | $POD_SPEC | .volumes[] | select(has(\"image\")) | .image.reference" "$pull_render" | sort -u)"
    while IFS= read -r ref; do
      [ -z "$ref" ] || grep -qxF "$ref" <<<"$pull_refs" ||
        echo "problem: the app ref $ref of apps/$app is no image volume of apps/$app/pull"
    done <<<"$app_refs"
    while IFS= read -r name; do
      [ -z "$name" ] || echo "problem: the image volume $name of apps/$app/pull is mounted by no container"
    done < <(comm -23 \
      <(yq --no-doc "select(.kind == \"Job\") | $POD_SPEC | .volumes[] | select(has(\"image\")) | .name" "$pull_render" | sort -u) \
      <(yq --no-doc "select(.kind == \"Job\") | $POD_SPEC | $CONTAINERS | .[].volumeMounts[].name" "$pull_render" | sort -u))
  done
}

problems="$(judge_pull_layers "$repository_root")"
[ -z "$problems" ] || fail "a pull layer of this repository breaks its contract: ${problems//$'\n'/; }"
echo "every pull layer of this repository mounts each app ref its app renders and mounts all its image volumes: $(find "$repository_root/apps" -mindepth 2 -maxdepth 2 -type d -name pull -printf '%P\n' | sed 's|/pull$||' | sort | paste -sd' ')"

for case_directory in "$cases_directory"/*/; do
  case_name="$(basename "$case_directory")"
  [ "$case_name" != base ] || continue
  tree="$work_directory/$case_name"
  mkdir -p "$tree/infrastructure"
  cp -R "$repository_root/infrastructure/pull" "$tree/infrastructure/pull"
  cp -R "$cases_directory/base/." "$case_directory." "$tree"
  actual="$(judge_pull_layers "$tree")"
  expected="$(cat "$tree/expected-problems.txt")"
  [ "$actual" = "$expected" ] ||
    fail "the case $case_name reads '${actual//$'\n'/; }', not '${expected//$'\n'/; }'"
  echo "the case $case_name reads '${actual:-no problem}'"
done
