#!/usr/bin/env bash
# The one owner of an app's legal copies: copy legal/datenschutz.html and legal/nutzungsbedingungen.html of the app's
# repository at the tag into infrastructure/legal/app-texts/<app>/ and write each page's date (the commit date of the
# file at the tag) and sha256 into the app's tables of infrastructure/legal/app-texts.toml, in the current directory.
# A page that appears or disappears at the tag is a settings change, which the script refuses: the release goes to an
# ordinary lane. tests/legal/app_texts_equal_their_release.sh runs it on a copy and demands an empty diff.
# Usage: scripts/release_bump_legal.sh <app> <tag>
# Exit: 0 the copies are written, 1 a refusal (a changed page set), 2 any other failure, a failed fetch included.
set -Eeuo pipefail
trap 'echo "release_bump_legal: line ${LINENO} failed: ${BASH_COMMAND}" >&2; exit 2' ERR

[ "$#" -eq 2 ] || { echo "usage: release_bump_legal.sh <app> <tag>" >&2; exit 2; }
app="$1" tag="$2"
list="infrastructure/legal/app-texts.toml"
copies="infrastructure/legal/app-texts/${app}"
url="${GITHUB_SERVER_URL:-https://github.com}/overnightworks/${app}"

refuse() { echo "release_bump_legal: $1" >&2; exit 1; }

workspace="$(mktemp -d)"
trap 'rm -rf "${workspace}"' EXIT
git init --quiet "${workspace}/repository"
# The tag is fetched without file contents: only the pages are read afterwards.
GIT_TERMINAL_PROMPT=0 git -C "${workspace}/repository" fetch --quiet --no-tags --filter=blob:none "${url}" \
  "refs/tags/${tag}:refs/tags/release" || { echo "release_bump_legal: fetching ${url} at the tag ${tag} failed, so ${app}'s legal files could not be read" >&2; exit 2; }

at_tag="$(git -C "${workspace}/repository" ls-tree -r --name-only release -- legal |
  { grep -E '^legal/(datenschutz|nutzungsbedingungen)\.html$' || true; } | sort)"
on_disk="$(cd "${copies}" 2>/dev/null && find . -type f | sed 's|^\./|legal/|' | sort || true)"
declared="$(sed -n "s/^\[${app}\.\([a-z]*\)\]\$/legal\/\1.html/p" "${list}" | sort)"
[ "${at_tag}" = "${on_disk}" ] && [ "${at_tag}" = "${declared}" ] ||
  refuse "${app} at ${tag} holds the pages [$(tr '\n' ' ' <<<"${at_tag}")], ${copies} [$(tr '\n' ' ' <<<"${on_disk}")] and ${list} [$(tr '\n' ' ' <<<"${declared}")]; a changed page set is a settings change for an ordinary lane"

for file in ${at_tag}; do
  page="$(basename "${file}" .html)"
  git -C "${workspace}/repository" show "release:${file}" >"${copies}/${page}.html"
  sha256="$(sha256sum <"${copies}/${page}.html" | cut -d' ' -f1)"
  day="$(git -C "${workspace}/repository" log -1 --format=%cs release -- "${file}")"
  awk -v table="[${app}.${page}]" -v day="${day}" -v sha256="${sha256}" '
    /^\[/ { inside = ($0 == table) }
    inside && /^date = / { print "date = " day; next }
    inside && /^sha256 = / { print "sha256 = \"" sha256 "\""; next }
    { print }
  ' "${list}" >"${workspace}/list"
  cat "${workspace}/list" >"${list}"
  echo "${app}.${page} is ${file} at ${tag} (${day})"
done
