#!/usr/bin/env bash
# Run scripts/verify_image_release.sh on every case under tests/images/: the case's files laid over base/, then its
# exit status and red records compared with its expected-exit.txt and expected-red.txt. Each line of expected-red.txt
# matches one red record; a * in it stands for any text, since flux's messages name the runner's own resolver.
# Usage: mise exec -- tests/images/run.sh
set -euo pipefail

cases_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify="${cases_directory}/../../scripts/verify_image_release.sh"
# The one scenario every case runs in; the base's root GitRepository matches it.
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=overnightworks/platform
export GITHUB_REPOSITORY_OWNER=overnightworks DEFAULT_BRANCH=main

# Whether every red record of the file $2 matches one line of the file $1, and every line one record.
red_set_matches() {
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
failed=0
for case_directory in "${cases_directory}"/*/; do
  case_name="$(basename "${case_directory}")"
  [ -f "${case_directory}/expected-exit.txt" ] || continue
  tree="${work_directory}/${case_name}"
  mkdir "${tree}"
  cp -R "${cases_directory}/base/." "${case_directory}." "${tree}"
  rm "${tree}/expected-exit.txt" "${tree}/expected-red.txt"
  # A case stores a dotfile as dot.<name>: a .sourceignore in this repository is itself red.
  find "${tree}" -name 'dot.*' -exec sh -c 'mv "$1" "${1%/*}/.${1##*/dot.}"' rename {} \;
  status=0
  "${verify}" "${tree}" >"${tree}.log" 2>&1 || status=$?
  grep '^red: ' "${tree}.log" >"${tree}.red" || true
  if [ "${status}" = "$(cat "${case_directory}/expected-exit.txt")" ] &&
    red_set_matches "${case_directory}/expected-red.txt" "${tree}.red"; then
    echo "images case ${case_name}: holds"
  else
    failed=1
    echo "images case ${case_name}: exit ${status}, expected $(cat "${case_directory}/expected-exit.txt"); its log:"
    cat "${tree}.log"
    echo "expected red:"
    cat "${case_directory}/expected-red.txt"
  fi
done
exit "${failed}"
