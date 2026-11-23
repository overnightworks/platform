#!/usr/bin/env bash
# Compute the bump of one app's release Component and legal copies, with no credential of its own and writing only the
# output directory. It takes origin's main, finds the newest release of the app (a tag v<year>.<month>.<day>.<n> of the
# app's repository, sorted by version, so a prerelease or another tag scheme never counts), reads each image's digest
# by tag from the registry through the docker login its caller made, sets newTag and digest on a fresh tree of main,
# runs the legal step for an app whose legal texts the pages show and rebuilds the pages. It does not check
# attestations: scripts/verify_image_release.sh, in CI, owns them. Settings are never guessed: a Component name it
# cannot resolve, a changed page set or a version older than main's is refused and the release stays an ordinary lane.
# Output: `outcome` (bump, current or waiting) and, with a bump, `version`, `patch` against main, `title` and `body`;
# with current, `version` of main. Current means main already runs the release; waiting means the release is not
# finished (no tag or no image yet), which is no failure.
# Usage: scripts/release_bump_compute.sh <app> <output directory> [version]
# Exit: 0 an outcome is written, 1 a refusal, 2 any other failure.
set -Eeuo pipefail
trap 'echo "release_bump_compute: line ${LINENO} failed: ${BASH_COMMAND}" >&2; exit 2' ERR

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "usage: release_bump_compute.sh <app> <output directory> [version]" >&2; exit 2; }
app="$1" output="$2" requested="${3:-}"
scripts_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server="${GITHUB_SERVER_URL:-https://github.com}"
version_pattern='[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+'
component="apps/${app}/release/kustomization.yaml"

refuse() { echo "release_bump_compute: refused: $1; ${app}'s release stays an ordinary lane" >&2; exit 1; }
finish() { # finish <outcome>
  [ "$1" != current ] || echo "${version}" >"${output}/version"
  echo "$1" >"${output}/outcome"
  echo "release_bump: ${app}: $1${version:+ ${version}}"
  exit 0
}

[[ ${app} =~ ^[a-z][a-z0-9-]*$ ]] || { echo "release_bump_compute: ${app} is no app name" >&2; exit 2; }
[ -z "${requested}" ] || [[ ${requested} =~ ^${version_pattern}$ ]] || { echo "release_bump_compute: ${requested} is no release version" >&2; exit 2; }
mkdir -p "${output}"
rm -f "${output}"/{outcome,version,patch,title,body}

workspace="$(mktemp -d)"
tree="${workspace}/tree"
cleanup() {
  git worktree remove --force "${tree}" 2>/dev/null || true
  rm -rf "${workspace}"
}
trap cleanup EXIT
GIT_TERMINAL_PROMPT=0 git fetch --quiet --no-tags origin main
git worktree add --quiet --detach "${tree}" FETCH_HEAD
cd "${tree}"

[ -f "${component}" ] || refuse "${component} does not exist, so ${app} has no release Component"
mapfile -t names < <(yq '.images[].name' "${component}")
[ "${#names[@]}" -gt 0 ] || refuse "${component} names no image"
repository=""
for name in "${names[@]}"; do
  [[ ${name} =~ ^ghcr\.io/overnightworks/([a-z0-9-]+)(/[a-z0-9-]+)?$ ]] ||
    refuse "the image name ${name} in ${component} is no ghcr.io/overnightworks/<repository>[/<part>]"
  [ -z "${repository}" ] || [ "${repository}" = "${BASH_REMATCH[1]}" ] ||
    refuse "the images of ${component} belong to more than one repository"
  repository="${BASH_REMATCH[1]}"
done
current="$(yq '[.images[].newTag] | unique | .[]' "${component}")"
[ "$(wc -l <<<"${current}")" -eq 1 ] || refuse "the images of ${component} are at more than one version"
url="${server}/overnightworks/${repository}"

tags="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "${url}" 'refs/tags/v*')"
if [ -n "${requested}" ]; then
  version="${requested}"
else
  version="$(sed -nE "s|^.*refs/tags/v(${version_pattern})\$|\1|p" <<<"${tags}" | sort -V | tail -1)"
  [ -n "${version}" ] || { echo "release_bump: ${app}: ${url} has no release tag yet, so it waits"; finish waiting; }
fi

newest="$(printf '%s\n%s\n' "${current}" "${version}" | sort -V | tail -1)"
[ "${newest}" = "${version}" ] || refuse "the release ${version} is older than ${current}, which main runs"
[ "${version}" != "${current}" ] || finish current
if ! grep -qE "refs/tags/v${version//./\\.}\$" <<<"${tags}"; then
  echo "release_bump: ${app}: ${url} has no tag v${version} yet, so it waits"
  finish waiting
fi

# A missing image is an unfinished release; any other failure of the registry is a failure.
for name in "${names[@]}"; do
  if ! manifest="$(docker buildx imagetools inspect "${name}:${version}" --format '{{json .Manifest}}' 2>"${workspace}/inspect-errors")"; then
    grep -qi 'not found' "${workspace}/inspect-errors" || { cat "${workspace}/inspect-errors" >&2; exit 2; }
    echo "release_bump: ${app}: ${name}:${version} is not in the registry yet, so it waits"
    finish waiting
  fi
  digest="$(yq -p json '.digest' <<<"${manifest}")"
  [[ ${digest} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "release_bump_compute: the registry gave no digest for ${name}:${version}" >&2; exit 2; }
  NAME="${name}" VERSION="${version}" DIGEST="${digest}" yq -i \
    '(.images[] | select(.name == strenv(NAME))) |= (.newTag = strenv(VERSION) | .digest = strenv(DIGEST))' "${component}"
done

if grep -qxF "[${app}]" infrastructure/legal/app-texts.toml; then
  "${scripts_directory}/release_bump_legal.sh" "${app}" "v${version}" || refuse "the legal step refused the release"
  # The tree's own mise.toml is a file of main, which this one run trusts.
  MISE_TRUSTED_CONFIG_PATHS="${tree}" mise run legal:build
fi

git add --all
git diff --cached --binary >"${workspace}/patch"
[ -s "${workspace}/patch" ] || refuse "the release ${version} changes nothing against main"
cp "${workspace}/patch" "${output}/patch"
echo "${app} runs release ${version}" >"${output}/title"
echo "Release: ${url}/releases/tag/v${version}" >"${output}/body"
echo "${version}" >"${output}/version"
echo bump >"${output}/outcome"
echo "release_bump: ${app}: bump ${current} -> ${version}"
