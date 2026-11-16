#!/usr/bin/env bash
# parts_for_paths.sh --all | <base> <head>: the parts of the cluster job a run executes, as a JSON array in the order of
# PARTS_FILE, which is the matrix the job takes. `--all` is every part, what a scheduled or dispatched run executes. Given
# two commits, the part core plus every part a changed path selects: a path under a layer's directory selects the parts
# whose closure holds the layer (part_closure.sh owns that graph), and a path that matches a glob of a part's `paths` in
# PARTS_FILE selects that part (a bash pattern, in which * also crosses /). A path no glob and no layer claims is unknown,
# and so is a zero <base> or a failing `git diff`; either selects every part. The parts marked `nightly_only` are chosen
# by --all alone.
set -euo pipefail
# The workflow reads stdout, so a notice goes to stderr.
notice() { echo "::notice::$1" >&2; }
parts_file="${PARTS_FILE:-$(dirname "${BASH_SOURCE[0]}")/parts.yaml}"
export PARTS_FILE="$parts_file"
export LAYERS_DIRECTORY="${LAYERS_DIRECTORY:-clusters/pc}"
part_closure="$(dirname "${BASH_SOURCE[0]}")/part_closure.sh"
mode="${1:?--all, or the base commit and the head commit}"

mapfile -t parts < <(yq 'keys | .[]' "$parts_file")
declare -A nightly_only=() selected=()
while read -r part; do nightly_only["$part"]=1; done < <(yq 'to_entries | .[] | select(.value.nightly_only == true) | .key' "$parts_file")

print_selection() {
  local part names=()
  for part in "${parts[@]}"; do
    [ -z "${selected[$part]:-}" ] || names+=("\"$part\"")
  done
  local IFS=,
  echo "[${names[*]}]"
}
select_every_part_but_the_nightly_only() {
  local part
  for part in "${parts[@]}"; do
    [ -n "${nightly_only[$part]:-}" ] || selected["$part"]=1
  done
}

if [ "$mode" = --all ]; then
  selected=()
  for part in "${parts[@]}"; do selected["$part"]=1; done
  print_selection
  exit 0
fi

base="$mode"
head="${2:?the head commit}"
selected[core]=1
if [[ $base =~ ^0+$ ]]; then
  notice "the base commit is all zeros, so every part but the nightly-only ones runs"
  select_every_part_but_the_nightly_only
  print_selection
  exit 0
fi
if ! changed="$(git diff --name-only "$base" "$head")"; then
  notice "git diff $base $head failed, so every part but the nightly-only ones runs"
  select_every_part_but_the_nightly_only
  print_selection
  exit 0
fi

declare -A layer_directories=() part_layers=()
while read -r layer directory; do
  # The path ./ is the secrets repository's, which this tree does not hold.
  [ -z "$directory" ] || layer_directories["$layer"]="$directory"
done < <(yq --no-doc 'select(.kind == "Kustomization") | .metadata.name + " " + (.spec.path | sub("^\./", "") | sub("/$", ""))' "$LAYERS_DIRECTORY"/*.yaml)
for part in "${parts[@]}"; do
  [ "$part" != core ] || continue
  part_layers["$part"]=" $("$part_closure" "$part" | tr '\n' ' ')"
done
glob_parts=()
globs=()
while read -r part glob; do
  glob_parts+=("$part")
  globs+=("$glob")
done < <(yq 'to_entries | .[] | .key as $part | (.value.paths // [])[] | $part + " " + .' "$parts_file")

while IFS= read -r path; do
  [ -n "$path" ] || continue
  known=0
  for index in "${!globs[@]}"; do
    # shellcheck disable=SC2053 # the glob is the point.
    [[ $path == ${globs[$index]} ]] || continue
    known=1
    [ -n "${nightly_only[${glob_parts[$index]}]:-}" ] || selected["${glob_parts[$index]}"]=1
  done
  for layer in "${!layer_directories[@]}"; do
    [[ $path == "${layer_directories[$layer]}"/* ]] || continue
    known=1
    for part in "${!part_layers[@]}"; do
      if [[ ${part_layers[$part]} == *" $layer "* && -z "${nightly_only[$part]:-}" ]]; then selected["$part"]=1; fi
    done
  done
  if [ "$known" -eq 0 ]; then
    notice "$path belongs to no part, so every part but the nightly-only ones runs"
    select_every_part_but_the_nightly_only
  fi
done <<<"$changed"
print_selection
