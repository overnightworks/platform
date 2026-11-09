#!/usr/bin/env bash
# Run scripts/verify_image_release.sh on every case under tests/images/: the case's files laid over base/, then its
# exit status and red records compared with its expected-exit.txt and expected-red.txt. Each line of expected-red.txt
# matches one red record; a * in it stands for any text, since flux's messages name the runner's own resolver.
# Tag lookups read local bare repositories, so no case needs the network.
# RENDER_IMAGE is the images job's own when unset. RENDER_TIMEOUT_SECONDS is the render's bound in every case, short
# enough that the case with a Kustomization path that contains itself ends soon; every other render takes seconds.
# A case's expected-gaps.txt, absent when it expects none, matches the same way the gap lines of the log other than
# G1, which every run prints.
# Usage: mise exec -- tests/images/run.sh
set -euo pipefail

cases_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify="${cases_directory}/../../scripts/verify_image_release.sh"
# The one scenario every case runs in; the base's root GitRepository matches it.
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=overnightworks/platform
export GITHUB_REPOSITORY_OWNER=overnightworks DEFAULT_BRANCH=main RENDER_TIMEOUT_SECONDS=20
RENDER_IMAGE="${RENDER_IMAGE:-$(yq eval '.jobs.images.env.RENDER_IMAGE' "${cases_directory}/../../.github/workflows/ci.yml")}"
export RENDER_IMAGE

# Whether every record of the file $2 matches one line of the file $1, and every line one record.
line_set_matches() {
  local expected=() actual=() line pattern index
  mapfile -t expected <"$1"
  mapfile -t actual <"$2"
  [ "${#expected[@]}" -eq "${#actual[@]}" ] || return 1
  for line in "${expected[@]}"; do
    pattern="^$(sed 's/[][\\.^$+?(){}|]/\\&/g; s/\*/.*/g' <<<"${line}")\$"
    for index in "${!actual[@]}"; do
      if [[ ${actual[index]} =~ ${pattern} ]]; then
        unset 'actual[index]'
        continue 2
      fi
    done
    return 1
  done
}

work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT
# git reads github.com/overnightworks/hopin from an empty bare repository, which lists no tag.
git init --bare -q "${work_directory}/remote/overnightworks/hopin"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://${work_directory}/remote/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/
failed=0 case_count=0
for case_directory in "${cases_directory}"/*/; do
  case_name="$(basename "${case_directory}")"
  [ "${case_name}" != base ] || continue
  case_count=$((case_count + 1))
  if [ ! -f "${case_directory}/expected-exit.txt" ] || [ ! -f "${case_directory}/expected-red.txt" ]; then
    failed=1
    echo "images case ${case_name}: lacks expected-exit.txt or expected-red.txt"
    continue
  fi
  tree="${work_directory}/${case_name}"
  mkdir "${tree}"
  cp -R "${cases_directory}/base/." "${case_directory}." "${tree}"
  rm "${tree}/expected-exit.txt" "${tree}/expected-red.txt"
  # A case stores a dotfile as dot.<name> and a symlink as symlink.<name> holding its target: a .sourceignore or a
  # symlink in this repository is itself red.
  find "${tree}" -name 'dot.*' -exec sh -c 'mv "$1" "${1%/*}/.${1##*/dot.}"' rename {} \;
  find "${tree}" -name 'symlink.*' -exec sh -c 'ln -sfn "$(cat "$1")" "${1%/*}/${1##*/symlink.}" && rm "$1"' link {} \;
  status=0
  "${verify}" "${tree}" >"${tree}.log" 2>&1 || status=$?
  grep '^red: ' "${tree}.log" >"${tree}.red" || true
  grep '^images: gap G' "${tree}.log" | grep -v '^images: gap G1:' >"${tree}.gaps" || true
  expected_gaps="${case_directory}/expected-gaps.txt"
  [ -f "${expected_gaps}" ] || expected_gaps=/dev/null
  if [ "${status}" = "$(cat "${case_directory}/expected-exit.txt")" ] &&
    line_set_matches "${case_directory}/expected-red.txt" "${tree}.red" &&
    line_set_matches "${expected_gaps}" "${tree}.gaps"; then
    echo "images case ${case_name}: holds"
  else
    failed=1
    echo "images case ${case_name}: exit ${status}, expected $(cat "${case_directory}/expected-exit.txt"); its log:"
    cat "${tree}.log"
    echo "expected red:"
    cat "${case_directory}/expected-red.txt"
    echo "expected gaps:"
    cat "${expected_gaps}"
  fi
done
[ "${case_count}" -gt 0 ] || { echo "images: no case under ${cases_directory}" && exit 1; }
exit "${failed}"
