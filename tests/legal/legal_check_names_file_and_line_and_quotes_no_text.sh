#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_url="https://github.com/overnightworks/hopin"
marker="The marker sentence must never be printed."
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

image_ref="$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' apps/hopin/hopin.yaml)"
version="${image_ref#*:}"
version="${version%%@*}"
[ -n "$version" ] && [ "$version" != "$image_ref" ] || fail "apps/hopin/hopin.yaml names no hopin image tag"

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$version" "$repository_url" "$workspace/hopin" ||
  fail "fetching $repository_url at the tag v$version failed, so the real legal files could not be read"

# directory_digest <dir>: the paths and bytes of everything under the directory, so a write of any kind shows.
directory_digest() { (cd "$1" && find . -type f -not -path './.git/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum); }

# run_check <name> <dir>: sets output and status; the directory must be as before afterwards.
run_check() {
  local before after
  before="$(directory_digest "$2")"
  status=0
  output="$(mise run --quiet legal:check "$1" "$2" 2>&1)" || status=$?
  after="$(directory_digest "$2")"
  [ "$before" = "$after" ] || fail "legal:check changed $2"
}

run_check hopin "$workspace/hopin"
[ "$status" = 0 ] || fail "legal:check refused hopin's legal files at v$version ($status): $output"
case "$output" in
  *"legal:check: hopin valid: datenschutz"*) ;;
  *) fail "legal:check printed '$output', not a valid line for hopin's pages" ;;
esac
[ -f "$workspace/hopin/legal/nutzungsbedingungen.html" ] && [[ "$output" != *nutzungsbedingungen* ]] &&
  fail "legal:check did not name hopin's terms page: $output"
echo "hopin's legal files at v$version pass: $output"

broken="$workspace/broken"
mkdir -p "$broken/legal"
printf '<h2 id="hopin">Titel</h2>\n<p>%s</p>\n<img src="x">\n' "$marker" >"$broken/legal/datenschutz.html"
run_check hopin "$broken"
[ "$status" != 0 ] || fail "legal:check passed a file with a disallowed element"
[[ "$output" == *"legal/datenschutz.html: line 3"* ]] || fail "the refusal does not name legal/datenschutz.html and line 3: $output"
[[ "$output" != *"$marker"* ]] || fail "the refusal quotes the file's text"
echo "a disallowed element on line 3 is refused: $output"

rm "$broken/legal/datenschutz.html"
run_check hopin "$broken"
[ "$status" != 0 ] || fail "legal:check passed a directory without legal/datenschutz.html"
[[ "$output" == *"legal/datenschutz.html"* ]] || fail "the refusal does not name legal/datenschutz.html: $output"
echo "a missing datenschutz.html is refused: $output"
