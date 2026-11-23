#!/usr/bin/env bash
# Drive scripts/release_bump_compute.sh against a fixture app repository, registry and platform main: the newest app
# release, whatever other tags the repository holds, gives a patch whose tree has the release's Component, legal copies,
# dates and sha256 and rebuilt legal pages; a second, newer release gives its own tree; a release that main runs is a
# no-op; an older version, an unknown name and a changed page set are refused; an unfinished release waits.
# Usage: mise exec -- tests/release_bump/compute_writes_the_release_tree_and_stops_where_it_cannot_settle.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/world.sh"

component=apps/hopin/release/kustomization.yaml
image=ghcr.io/overnightworks/hopin
output="${work}/output"

# compute <version>...: runs the compute step in the checkout, leaving its status in `status` and its lines in `lines`.
compute() {
  status=0
  lines="$(cd "${checkout}" && "${repository_root}/scripts/release_bump_compute.sh" "$@" 2>&1)" || status=$?
}
# expect_status <status> <text>: the last run ended so and said so.
expect_status() {
  [ "${status}" -eq "$1" ] || fail "the compute step ended ${status}, not $1: ${lines}"
  grep -qF -- "$2" <<<"${lines}" || fail "the compute step did not say '$2': ${lines}"
}
# patched <directory>: a fresh clone of main with the output's patch applied.
patched() {
  clone_main "$1"
  git -C "$1" apply "${output}/patch"
}

# Tags that are no app release never count, however high they sort; the first release changes a legal page.
app_release 0.99.0
app_release 2026.11.23.9-rc.1
app_release 2026.11.24.1 text
git -C "${app_repository}" tag not-a-release
registry_add "${image}" 2026.11.24.1
compute hopin "${output}"
expect_status 0 "bump ${main_version} -> 2026.11.24.1"
[ "$(cat "${output}/outcome")" = bump ] || fail "the outcome of a new release is not bump"
[ "$(cat "${output}/title")" = "hopin runs release 2026.11.24.1" ] || fail "the title is '$(cat "${output}/title")'"
grep -qF "https://github.com/overnightworks/hopin/releases/tag/v2026.11.24.1" "${output}/body" || fail "the body does not link the release"
patched "${work}/first"
[ "$(yq '.images[0].newTag' "${work}/first/${component}")" = 2026.11.24.1 ] || fail "the Component does not run 2026.11.24.1"
[ "$(yq '.images[0].digest' "${work}/first/${component}")" = "$(digest_of "${image}" 2026.11.24.1)" ] || fail "the Component holds another digest than the registry"
git -C "${work}/first" diff --stat -- "${component}" | grep -q '2 insertions(+), 2 deletions(-)' || fail "the Component changes more than tag and digest"
for page in datenschutz nutzungsbedingungen; do
  cmp -s "${work}/first/infrastructure/legal/app-texts/hopin/${page}.html" "${app_repository}/legal/${page}.html" || fail "the copy of ${page} differs from the app's file"
  grep -qF "sha256 = \"$(sha256sum <"${app_repository}/legal/${page}.html" | cut -d' ' -f1)\"" "${work}/first/infrastructure/legal/app-texts.toml" || fail "the toml holds another sha256 for ${page}"
done
grep -qF 'date = 2026-11-24' "${work}/first/infrastructure/legal/app-texts.toml" || fail "the toml holds no date of the release's commit"
grep -qF 'Videoanrufe und Chats im Browser' "${work}/first/infrastructure/legal/built/datenschutz.html" || fail "the built page does not carry the new text"
echo "a new release gives its Component, legal copies and rebuilt pages"

# A second, newer release rewrites the tree against main, which still runs the old one.
app_release 2026.11.25.1
registry_add "${image}" 2026.11.25.1
compute hopin "${output}"
expect_status 0 "bump ${main_version} -> 2026.11.25.1"
patched "${work}/second"
[ "$(yq '.images[0].newTag' "${work}/second/${component}")" = 2026.11.25.1 ] || fail "the second release is not in the Component"
[ "$(yq '.images[0].digest' "${work}/second/${component}")" = "$(digest_of "${image}" 2026.11.25.1)" ] || fail "the second release holds another digest"
echo "a second release rewrites the tree"

# main's own release is a no-op, an older one and an unknown name are refused, and a refusal writes no patch.
compute hopin "${output}" "${main_version}"
expect_status 0 "hopin: current ${main_version}"
[ "$(cat "${output}/outcome")" = current ] && [ ! -e "${output}/patch" ] || fail "the release main runs is not a no-op"
compute hopin "${output}" 2026.11.01.1
expect_status 1 "older than ${main_version}"
[ ! -e "${output}/patch" ] || fail "a refused release left a patch"
compute nosuchapp "${output}"
expect_status 1 "has no release Component"
echo "the release main runs is a no-op; an older version and an unknown name are refused"

# A release that adds or drops a legal page is a settings change.
app_release 2026.11.26.1 remove
registry_add "${image}" 2026.11.26.1
compute hopin "${output}" 2026.11.26.1
expect_status 1 "a changed page set"
[ ! -e "${output}/patch" ] || fail "a refused page set left a patch"
echo "a changed legal page set is refused"

# An unfinished release waits, also as the newest, and a release without a tag waits.
app_release 2026.11.27.1
compute hopin "${output}"
expect_status 0 "is not in the registry yet"
[ "$(cat "${output}/outcome")" = waiting ] && [ ! -e "${output}/patch" ] || fail "a release without its image did not wait"
compute hopin "${output}" 2026.11.28.1
expect_status 0 "has no tag v2026.11.28.1 yet"
[ "$(cat "${output}/outcome")" = waiting ] || fail "a release without its tag did not wait"
echo "an unfinished release waits"

# The run leaves the checkout and its worktree list as it found them.
[ -z "$(git -C "${checkout}" status --porcelain)" ] || fail "the compute step changed the checkout"
[ "$(git -C "${checkout}" worktree list | wc -l)" -eq 1 ] || fail "the compute step left a worktree"
echo "the checkout is untouched"
