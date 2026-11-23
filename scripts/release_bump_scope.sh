#!/usr/bin/env bash
# The mandatory guard's judgement of one bump pull request, run by ci.yml's release-bump-scope job from the pull
# request's base with the runner's own tools: it reads the pull request's merge commit as data and admits only what
# scripts/release_bump_compute.sh writes. Every changed path is a regular file edited in place: one app's
# apps/<app>/release/kustomization.yaml, its legal copies under infrastructure/legal/app-texts/<app>/, its tables of
# infrastructure/legal/app-texts.toml and the rebuilt pages under infrastructure/legal/built/. The changed paths name
# one app; a Component keeps its names and every other field and moves each image to a newer version and a digest; the
# list changes only inside the app's tables. A script, another app's file, a name change, an added or deleted file, a
# renamed one (judged as the deletion and addition it is), a mode or type change and an older version are refused.
# Usage: scripts/release_bump_scope.sh <merge commit>, in a repository that holds the merge commit and its parents.
# Exit: 0 the bump is in scope, 1 a refusal, 2 any other failure.
set -Eeuo pipefail
trap 'echo "release_bump_scope: line ${LINENO} failed: ${BASH_COMMAND}" >&2; exit 2' ERR

[ "$#" -eq 1 ] || { echo "usage: release_bump_scope.sh <merge commit>" >&2; exit 2; }
merge="$1"
scripts_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${scripts_directory}/release_bump_patterns.sh"
list="infrastructure/legal/app-texts.toml"

refuse() { echo "release_bump_scope: refused: $1" >&2; exit 1; }

git rev-parse --verify --quiet "${merge}^2" >/dev/null || { echo "release_bump_scope: ${merge} is no merge commit of a pull request" >&2; exit 2; }
base="$(git rev-parse --verify "${merge}^1")"
workspace="$(mktemp -d)"
trap 'rm -rf "${workspace}"' EXIT

git diff --no-renames --ignore-submodules=none --raw -z "${base}" "${merge}" >"${workspace}/diff"
declare -A apps=()
list_changed=false
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  read -r old_mode new_mode _ _ status <<<"${meta#:}"
  if [[ ${path} =~ ^apps/(${app_name_pattern})/release/kustomization\.yaml$ ]] ||
    [[ ${path} =~ ^infrastructure/legal/app-texts/(${app_name_pattern})/[a-z]+\.html$ ]]; then
    apps["${BASH_REMATCH[1]}"]=true
  elif [ "${path}" = "${list}" ]; then
    list_changed=true
  elif [[ ! ${path} =~ ^infrastructure/legal/built/[^/]+$ ]]; then
    refuse "$(printf '%q' "${path}") is outside what a bump changes"
  fi
  [ "${status}" = M ] && [ "${old_mode}" = 100644 ] && [ "${new_mode}" = 100644 ] ||
    refuse "$(printf '%q' "${path}") is ${status} from mode ${old_mode} to ${new_mode}, and a bump only edits regular files in place"
done <"${workspace}/diff"
[ "${#apps[@]}" -eq 1 ] || refuse "the changed paths name ${#apps[@]} apps [${!apps[*]}], and a bump changes exactly one"
app="${!apps[*]}"
component="apps/${app}/release/kustomization.yaml"

# at <commit> <path>: the file's content in the commit.
at() { git show "$1:$2"; }

if [ "$(at "${base}" "${component}" | sha256sum)" != "$(at "${merge}" "${component}" | sha256sum)" ]; then
  at "${base}" "${component}" >"${workspace}/base.yaml"
  at "${merge}" "${component}" >"${workspace}/merge.yaml"
  strip='del(.images[].newTag, .images[].digest)'
  [ "$(yq -o json -I 0 "${strip}" "${workspace}/base.yaml")" = "$(yq -o json -I 0 "${strip}" "${workspace}/merge.yaml")" ] ||
    refuse "${component} changes more than newTag and digest, or the names of its images"
  while IFS= read -r digest; do
    [[ ${digest} =~ ^${digest_pattern}$ ]] || refuse "${component} holds the digest '${digest}', which is no sha256 digest"
  done < <(yq '.images[].digest' "${workspace}/merge.yaml")
  for side in base merge; do
    status=0
    "${scripts_directory}/release_bump_component_version.sh" "${workspace}/${side}.yaml" >"${workspace}/${side}.version" || status=$?
    [ "${status}" -ne 1 ] || refuse "the images of ${component} are not at one version in the ${side}"
    [ "${status}" -eq 0 ] || exit 2
  done
  base_version="$(cat "${workspace}/base.version")" merge_version="$(cat "${workspace}/merge.version")"
  [[ ${merge_version} =~ ^${version_pattern}$ ]] || refuse "${component} runs '${merge_version}', which is no release version"
  [ "${merge_version}" != "${base_version}" ] &&
    [ "$(printf '%s\n%s\n' "${base_version}" "${merge_version}" | "${scripts_directory}/release_bump_newest.sh")" = "${merge_version}" ] ||
    refuse "${component} runs ${merge_version}, which is not newer than ${base_version} of the base"
fi

if "${list_changed}"; then
  # outside_tables <commit>: the list without the tables [<app>] and [<app>.*].
  outside_tables() {
    at "$1" "${list}" | awk -v app="${app}" '
      /^\[/ { name = $0; sub(/^\[/, "", name); sub(/\].*$/, "", name); split(name, parts, "."); inside = (parts[1] == app) }
      !inside { print }
    '
  }
  [ "$(outside_tables "${base}")" = "$(outside_tables "${merge}")" ] || refuse "${list} changes outside the tables of ${app}"
fi
echo "release_bump_scope: the bump of ${app} is in scope"
