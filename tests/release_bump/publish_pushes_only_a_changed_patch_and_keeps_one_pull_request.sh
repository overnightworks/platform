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
branch_tip() { git ls-remote "${platform}" refs/heads/release/hopin | cut -f1; }
branch_version() { git --git-dir="${work}/remote/overnightworks/platform" show release/hopin:apps/hopin/release/kustomization.yaml | yq '.images[0].newTag'; }

app_release 2026.11.24.1 text
registry_add "${image}" 2026.11.24.1
log="$(bump)" || fail "the first bump failed: ${log}"
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

app_release 2026.11.25.1
registry_add "${image}" 2026.11.25.1
log="$(bump)" || fail "the newer bump failed: ${log}"
[ "$(branch_tip)" != "${tip}" ] && [ "$(branch_version)" = 2026.11.25.1 ] || fail "a newer release did not move the branch"
[ "$(calls "${work}/gh-calls" 'pr create')" -eq 1 ] || fail "a newer release opened a second pull request"
grep -q 'pr edit 1 --title hopin runs release 2026.11.25.1' "${work}/gh-calls" || fail "a newer release did not edit the pull request"
echo "a newer release moves the branch and edits the one pull request"

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
[ ! -e "${gh_state}/open" ] || fail "a pull request is still open after main runs the release"
echo "a release that main runs closes the open pull request"

# An unfinished release changes nothing: no gh call, no push.
app_release 2026.11.26.1
: >"${work}/gh-calls"
tip="$(branch_tip)"
grep -qF 'pr close 1 --delete-branch --comment main runs release 2026.11.25.1, so' "${work}/gh-calls" ||
  fail "the closing comment does not name the release main runs: $(grep 'pr close' "${work}/gh-calls")"
log="$(bump)" || fail "the bump of an unfinished release failed: ${log}"
[ ! -s "${work}/gh-calls" ] && [ "$(branch_tip)" = "${tip}" ] || fail "an unfinished release called gh or pushed"
echo "an unfinished release changes nothing"
