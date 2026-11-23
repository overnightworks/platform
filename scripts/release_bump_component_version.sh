#!/usr/bin/env bash
# The one version an app's release Component runs: print the newTag every image of the kustomization file holds, or
# refuse (exit 1) when the images are at more than one version or the file names none; exit 2 when it cannot read the file.
# Usage: scripts/release_bump_component_version.sh <kustomization file>
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: release_bump_component_version.sh <kustomization file>" >&2; exit 2; }
versions="$(yq '[.images[].newTag] | unique | .[]' "$1")" || exit 2
[ -n "${versions}" ] && [ "$(wc -l <<<"${versions}")" -eq 1 ] || {
  echo "release_bump_component_version: the images of $1 are at more than one version or none: $(tr '\n' ' ' <<<"${versions}")" >&2
  exit 1
}
echo "${versions}"
