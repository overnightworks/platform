#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

list="infrastructure/legal/app-texts.toml"
copies="infrastructure/legal/app-texts"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

# One line per app: its key and its declared tag, "-" when it declares none; then one line per page: key, page, date, sha256.
declared="$(python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    apps = tomllib.load(handle)
for key, table in apps.items():
    print(key, table.get("tag", "-"))
    for page, entry in table.items():
        if page != "tag":
            print(key, page, entry["date"], entry["sha256"])
' "$list")" || fail "reading $list failed"

declare -A tag_of
while read -r key tag; do
  tag_of[$key]="$tag"
done < <(awk 'NF == 2' <<<"$declared")

# set_release_tag <key> <declared tag>: sets tag, so a failure is not captured by a command substitution.
set_release_tag() {
  local key="$1" declared_tag="$2" image_ref
  image_ref="$(grep -rhoE "ghcr\.io/overnightworks/$key:[^@\" ]+" "apps/$key" 2>/dev/null | head -n 1 || true)"
  if [ -n "$image_ref" ]; then
    [ "$declared_tag" = "-" ] || fail "$list names a tag for $key, which has the image $image_ref under apps/$key; drop the tag"
    tag="v${image_ref#*:}"
    return
  fi
  [ "$declared_tag" != "-" ] || fail "$list names no tag for $key, which has no image under apps/$key"
  tag="$declared_tag"
}

for key in "${!tag_of[@]}"; do
  set_release_tag "$key" "${tag_of[$key]}"
  url="https://github.com/overnightworks/$key"
  git init --quiet "$workspace/$key"
  git -C "$workspace/$key" fetch --quiet --no-tags --filter=blob:none "$url" "refs/tags/$tag:refs/tags/release" ||
    fail "fetching $url at the tag $tag failed, so $key's legal files could not be read"

  at_release="$(git -C "$workspace/$key" ls-tree -r --name-only release -- legal | grep -E '^legal/(datenschutz|nutzungsbedingungen)\.html$' | sort || true)"
  on_disk="$(cd "$copies/$key" 2>/dev/null && find . -type f | sed 's|^\./|legal/|' | sort || true)"
  [ "$at_release" = "$on_disk" ] ||
    fail "$key at $tag holds the pages [$(tr '\n' ' ' <<<"$at_release")] and $copies/$key [$(tr '\n' ' ' <<<"$on_disk")]; a page exists on one side only"

  while read -r _ page day sha256; do
    file="legal/$page.html"
    git -C "$workspace/$key" show "release:$file" >"$workspace/$key.$page" ||
      fail "$key at $tag has no $file"
    cmp -s "$workspace/$key.$page" "$copies/$key/$page.html" ||
      fail "$copies/$key/$page.html differs from $file at $tag; the new sha256 is $(sha256sum <"$workspace/$key.$page" | cut -d' ' -f1)"
    [ "$(sha256sum <"$workspace/$key.$page" | cut -d' ' -f1)" = "$sha256" ] ||
      fail "$list declares another sha256 for $key.$page than $file at $tag has: $(sha256sum <"$workspace/$key.$page" | cut -d' ' -f1)"
    commit_date="$(git -C "$workspace/$key" log -1 --format=%cs release -- "$file")"
    [ "$commit_date" = "$day" ] ||
      fail "$list declares the date $day for $key.$page, but $file at $tag was last committed on $commit_date"
    echo "$key.$page equals $file at $tag ($day)"
  done < <(awk -v key="$key" 'NF == 4 && $1 == key' <<<"$declared")
done
