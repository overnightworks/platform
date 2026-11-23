#!/usr/bin/env bash
# The legal copies under infrastructure/legal are what scripts/release_bump_legal.sh writes at the version each app's
# Component names: the script's regeneration on a copy leaves no difference.
# Usage: mise exec -- tests/legal/app_texts_equal_their_release.sh
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "${repository_root}/tests/failure.sh"
cd "${repository_root}"

list="infrastructure/legal/app-texts.toml"
workspace="$(mktemp -d)"
trap 'rm -rf "${workspace}"' EXIT
mkdir -p "${workspace}/infrastructure/legal"
cp -R infrastructure/legal/app-texts "${list}" "${workspace}/infrastructure/legal/"

while read -r app; do
  release="apps/${app}/release/kustomization.yaml"
  [ -f "${release}" ] || fail "${list} lists ${app}, which has no Component ${release}"
  versions="$(yq '[.images[].newTag] | unique | .[]' "${release}")"
  [ "$(wc -l <<<"${versions}")" -eq 1 ] ||
    fail "the images of ${app} in ${release} are at more than one version: $(tr '\n' ' ' <<<"${versions}")"
  (cd "${workspace}" && "${repository_root}/scripts/release_bump_legal.sh" "${app}" "v${versions}") ||
    fail "regenerating the legal copies of ${app} at v${versions} failed"
done < <(sed -n 's/^\[\([a-z0-9-]*\)\]$/\1/p' "${list}")

diff -r infrastructure/legal/app-texts "${workspace}/infrastructure/legal/app-texts" &&
  diff "${list}" "${workspace}/${list}" ||
  fail "the legal copies or ${list} differ from what scripts/release_bump_legal.sh writes at the version of each Component; run it in the tree"
echo "the legal copies equal their apps' files at the release each Component runs"
