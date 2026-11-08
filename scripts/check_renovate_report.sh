#!/usr/bin/env bash
# Fail unless Renovate's file report holds every pin of this checkout: each pair of file and digest under
# infrastructure/ (rendered.yaml excepted), each chart line of mise.toml, K3S_VERSION and the workflow's own image,
# with no skipReason. A pin form no manager extracts cannot go unwatched in silence.
# Usage: scripts/check_renovate_report.sh <report>
# The report is the file at RENOVATE_REPORT_PATH of a run with RENOVATE_REPORT_TYPE=file.
set -euo pipefail

fail() { echo "check_renovate_report: $1" >&2; exit 1; }

[ $# -eq 1 ] || fail "usage: scripts/check_renovate_report.sh <report>"
report="$1"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repository_root}"
[ -s "${report}" ] || fail "the report ${report} is missing or empty"

# Every dependency of the report as <file> TAB <digest, or the version where a pin has none> TAB <skipReason>.
extracted="$(jq -r '
  [.repositories[]?.packageFiles // {} | to_entries[].value[] | .packageFile as $file | .deps[]?
    | [$file, (.currentDigest // .currentValue), (.skipReason // "")]] | .[] | @tsv' "${report}")" ||
  fail "the report ${report} is no Renovate file report"
[ -n "${extracted}" ] || fail "the report ${report} holds no dependency"

digest_pattern='sha256:[0-9a-f]{64}'
# <file> TAB <digest> of each pin the check names.
pins="$(
  {
    grep -rEo --exclude=rendered.yaml "${digest_pattern}" infrastructure | sed 's/:/\t/'
    grep -Eo "${digest_pattern}" mise.toml .github/workflows/renovate.yml | sed 's/:/\t/'
    sed -n 's/^K3S_VERSION = "\(.*\)"$/mise.toml\t\1/p' mise.toml
  } | sort -u
)"
[ -n "${pins}" ] || fail "no pin found in ${repository_root}"

missing=()
skipped=()
while IFS=$'\t' read -r file value; do
  reasons="$(awk -F'\t' -v file="${file}" -v value="${value}" '$1 == file && $2 == value { print ($3 == "" ? "-" : $3) }' <<<"${extracted}")"
  [ -n "${reasons}" ] || { missing+=("${file} ${value}"); continue; }
  # An extracted pin is watched only when at least one of its entries has no skipReason.
  grep -qx -- '-' <<<"${reasons}" || skipped+=("${file} ${value} (skipReason: $(head -n 1 <<<"${reasons}"))")
done <<<"${pins}"

[ ${#missing[@]} -eq 0 ] || fail "the report lacks ${#missing[@]} pin(s): $(printf '%s; ' "${missing[@]}")"
[ ${#skipped[@]} -eq 0 ] || fail "Renovate skipped ${#skipped[@]} pin(s): $(printf '%s; ' "${skipped[@]}")"
echo "check_renovate_report: $(wc -l <<<"${pins}") pins found in the report, each looked up"
