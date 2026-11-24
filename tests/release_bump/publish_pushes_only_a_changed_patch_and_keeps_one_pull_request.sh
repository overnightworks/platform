#!/usr/bin/env bash
# Drive scripts/release_bump_compute.sh and scripts/release_bump_publish.sh against a fixture platform remote and a
# fake gh: the first bump pushes release/hopin and opens one pull request; the same bump again pushes nothing; a newer
# release moves the branch and edits that pull request; a branch that conflicts with main is pushed again; a release
# that main runs closes the open pull request; an unfinished release changes nothing and calls no gh.
# Usage: mise exec -- tests/release_bump/publish_pushes_only_a_changed_patch_and_keeps_one_pull_request.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/world.sh"

image=ghcr.io/overnightworks/hopin
output="${work}/output"
platform="file://${work}/remote/overnightworks/platform"

# bump <version>: compute and publish in the checkout.
bump() {
  (cd "${checkout}" && "${repository_root}/scripts/release_bump_compute.sh" hopin "${output}" "$@" &&
    "${repository_root}/scripts/release_bump_publish.sh" hopin "${output}") 2>&1
}
# release_and_bump <version> [change]: the app releases <version>, the registry holds it, and the bump runs; the output is in $log.
release_and_bump() {
  app_release "$@"
  registry_add "${image}" "$1"
  log="$(bump)"
}
branch_tip() { git ls-remote "${platform}" refs/heads/release/hopin | cut -f1; }
branch_version() { git --git-dir="${work}/remote/overnightworks/platform" show release/hopin:apps/hopin/release/kustomization.yaml | yq '.images[0].newTag'; }

release_and_bump 2026.11.24.1 text || fail "the first bump failed: ${log}"
[ "$(branch_version)" = 2026.11.24.1 ] || fail "release/hopin does not run 2026.11.24.1"
[ "$(git ls-remote "${platform}" refs/heads/release/hopin | wc -l)" -eq 1 ] || fail "release/hopin is not one branch"
[ "$(git --git-dir="${work}/remote/overnightworks/platform" rev-list --count main..release/hopin)" -eq 1 ] || fail "the branch is not one commit on main"
[ "$(calls "${work}/gh-calls" 'pr create')" -eq 1 ] || fail "the first bump did not open one pull request: $(cat "${work}/gh-calls")"
grep -q 'pr create --base main --head release/hopin --title hopin runs release 2026.11.24.1 --body-file' "${work}/gh-calls" || fail "the pull request has another title or head"
echo "a first bump pushes the branch and opens one pull request"

tip="$(branch_tip)"
log="$(bump)" || fail "the repeated bump failed: ${log}"
[ "$(branch_tip)" = "${tip}" ] || fail "an identical second run pushed the branch again"
[ "$(calls "${work}/gh-calls" 'pr create')" -eq 1 ] || fail "an identical second run opened another pull request"
grep -q 'nothing is pushed' <<<"${log}" || fail "the second run did not say it pushed nothing: ${log}"
echo "the same bump again pushes nothing and keeps the pull request"

release_and_bump 2026.11.25.1 || fail "the newer bump failed: ${log}"
[ "$(branch_tip)" != "${tip}" ] && [ "$(branch_version)" = 2026.11.25.1 ] || fail "a newer release did not move the branch"
[ "$(calls "${work}/gh-calls" 'pr create')" -eq 1 ] || fail "a newer release opened a second pull request"
grep -q 'pr edit 1 --title hopin runs release 2026.11.25.1' "${work}/gh-calls" || fail "a newer release did not edit the pull request"
echo "a newer release moves the branch and edits the one pull request"

# Lines added to the open pull request's body by others survive the next bump, and the Release line stays one.
{ printf 'Release: https://example.org/old\n'; printf 'Work-Item: #7\n'; printf 'Closes #7\n'; } >"${gh_state}/body"
landed_version=2026.11.25.2
release_and_bump "${landed_version}" || fail "the bump over a body with other lines failed: ${log}"
body="$(cat "${gh_state}/body")"
[ "$(grep -c '^Release: ' <<<"${body}")" -eq 1 ] && ! grep -q 'example.org/old' <<<"${body}" ||
  fail "the body does not carry the new Release line once: ${body}"
grep -qx 'Work-Item: #7' <<<"${body}" && grep -qx 'Closes #7' <<<"${body}" || fail "the bump dropped a line it did not write: ${body}"
! grep -qx '' "${gh_state}/body" || fail "the bump added a blank line to the body: ${body}"
echo "a newer release keeps the lines of the pull request's body it did not write and adds no blank line"

# Main runs the older release a caller names: the open pull request proposes a newer one and stays.
tip="$(branch_tip)"
log="$(bump "${main_version}")" || fail "the bump of the release main runs failed: ${log}"
[ "$(calls "${work}/gh-calls" 'pr close')" -eq 0 ] && [ -e "${gh_state}/open" ] && [ "$(branch_tip)" = "${tip}" ] ||
  fail "a pull request that proposes a newer release than main runs was closed: ${log}"
echo "a pull request that proposes a newer release stays open"

# main changes the line below the Component's tag and digest, so the branch conflicts with it while its own patch stays.
tip="$(branch_tip)"
clone_main "${work}/mover"
sed -i 's/^configurations:/configurations: # moved/' "${work}/mover/apps/hopin/release/kustomization.yaml"
git -C "${work}/mover" -c user.name=fixture -c user.email=fixture@example.org commit --quiet --all --message "main moves"
git -C "${work}/mover" push --quiet origin main
log="$(bump)" || fail "the bump against a moved main failed: ${log}"
[ "$(branch_tip)" != "${tip}" ] || fail "a branch that conflicts with main was not pushed again"
grep -q 'since it conflicts with main' <<<"${log}" || fail "the push did not name the conflict: ${log}"
git --git-dir="${work}/remote/overnightworks/platform" merge-tree --write-tree --quiet main release/hopin >/dev/null || fail "the pushed branch still conflicts with main"
echo "a branch that conflicts with main is pushed again"

# main runs the release once the branch lands; the pull request closes.
git --git-dir="${work}/remote/overnightworks/platform" update-ref refs/heads/main "$(branch_tip)"
log="$(bump)" || fail "the bump after the landing failed: ${log}"
[ "$(calls "${work}/gh-calls" 'pr close 1')" -eq 1 ] || fail "the overtaken pull request was not closed"
grep -qF "pr close 1 --delete-branch --comment main runs release ${landed_version}, so" "${work}/gh-calls" ||
  fail "the closing comment does not name the release main runs: $(grep 'pr close' "${work}/gh-calls")"
[ ! -e "${gh_state}/open" ] || fail "a pull request is still open after main runs the release"
echo "a release that main runs closes the open pull request"

# An unfinished release changes nothing: no gh call, no push.
app_release 2026.11.26.1
: >"${work}/gh-calls"
tip="$(branch_tip)"
log="$(bump)" || fail "the bump of an unfinished release failed: ${log}"
[ ! -s "${work}/gh-calls" ] && [ "$(branch_tip)" = "${tip}" ] || fail "an unfinished release called gh or pushed"
echo "an unfinished release changes nothing"

# The steps accept a relative output directory, which the compute step's own tree does not move.
registry_add "${image}" 2026.11.26.1
(cd "${checkout}" && "${repository_root}/scripts/release_bump_compute.sh" hopin relative-output &&
  "${repository_root}/scripts/release_bump_publish.sh" hopin relative-output) >"${work}/relative.log" 2>&1 ||
  fail "the steps failed with a relative output directory: $(cat "${work}/relative.log")"
[ "$(branch_version)" = 2026.11.26.1 ] && [ "$(calls "${work}/gh-calls" 'pr create')" -eq 1 ] ||
  fail "the steps did not publish through a relative output directory: $(cat "${work}/relative.log")"
echo "the steps accept a relative output directory"
