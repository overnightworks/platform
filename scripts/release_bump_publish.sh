#!/usr/bin/env bash
# Publish what scripts/release_bump_compute.sh wrote for one app, with git and gh only: for a bump, push release/<app>
# only when its patch differs from the open branch's or that branch conflicts with main, then open or edit the branch's
# one pull request; for an outcome current, close the open pull request, since main runs the release or a newer one;
# for waiting, change nothing. Run it in a checkout of platform whose origin is platform on GitHub, with the
# credential of the caller.
# Usage: scripts/release_bump_publish.sh <app> <output directory of the compute step>
set -Eeuo pipefail
trap 'echo "release_bump_publish: line ${LINENO} failed: ${BASH_COMMAND}" >&2; exit 2' ERR

[ "$#" -eq 2 ] || { echo "usage: release_bump_publish.sh <app> <output directory>" >&2; exit 2; }
app="$1" output="$2"
branch="release/${app}"
[ -f "${output}/outcome" ] || { echo "release_bump_publish: ${output} holds no outcome of the compute step" >&2; exit 2; }
outcome="$(cat "${output}/outcome")"

[ "${outcome}" != waiting ] || { echo "release_bump: ${app}: the release is not finished, so nothing changes"; exit 0; }

number="$(gh pr list --head "${branch}" --state open --json number --jq '.[0].number // empty')"

if [ "${outcome}" = current ]; then
  if [ -n "${number}" ]; then
    gh pr close "${number}" --delete-branch \
      --comment "main runs release $(cat "${output}/version"), so this pull request is overtaken."
    echo "release_bump: ${app}: closed pull request ${number}, since main runs the release"
  else
    echo "release_bump: ${app}: main runs the release and no pull request is open"
  fi
  exit 0
fi
[ "${outcome}" = bump ] || { echo "release_bump_publish: the outcome '${outcome}' is unknown" >&2; exit 2; }

workspace="$(mktemp -d)"
candidate_tree="${workspace}/candidate"
cleanup() {
  git worktree remove --force "${candidate_tree}" 2>/dev/null || true
  rm -rf "${workspace}"
}
trap cleanup EXIT

# patch_id <base> <tip>: the identity of the lines the tip changes against the base, whatever their context.
patch_id() { git diff -U0 --binary "$1" "$2" | git patch-id --stable | cut -d' ' -f1; }

GIT_TERMINAL_PROMPT=0 git fetch --quiet --no-tags origin main
remote_tip=""
listing=0
GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads origin "${branch}" >"${workspace}/head" || listing=$?
case "${listing}" in
  0)
    GIT_TERMINAL_PROMPT=0 git fetch --quiet --no-tags origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"
    remote_tip="$(git rev-parse "refs/remotes/origin/${branch}")"
    ;;
  2) ;; # no such branch
  *) echo "release_bump_publish: listing ${branch} of origin failed" >&2; exit 2 ;;
esac

git worktree add --quiet --detach "${candidate_tree}" origin/main
git -C "${candidate_tree}" apply --index "${output}/patch"
git -C "${candidate_tree}" -c user.name=release-bump -c user.email=release-bump@users.noreply.github.com \
  commit --quiet --file "${output}/title"
candidate="$(git -C "${candidate_tree}" rev-parse HEAD)"

reason=""
if [ -z "${remote_tip}" ]; then
  reason="the branch does not exist"
elif [ "$(patch_id origin/main "${candidate}")" != "$(patch_id "$(git merge-base origin/main "${remote_tip}")" "${remote_tip}")" ]; then
  reason="its patch differs"
elif ! git merge-tree --write-tree --quiet origin/main "${remote_tip}" >/dev/null; then
  reason="it conflicts with main"
fi
if [ -n "${reason}" ]; then
  git push --quiet --force-with-lease="refs/heads/${branch}:${remote_tip}" origin "${candidate}:refs/heads/${branch}"
  echo "release_bump: ${app}: pushed ${branch}, since ${reason}"
else
  echo "release_bump: ${app}: ${branch} holds this patch and merges into main, so nothing is pushed"
fi

if [ -n "${number}" ]; then
  gh pr edit "${number}" --title "$(cat "${output}/title")" --body-file "${output}/body"
  echo "release_bump: ${app}: edited pull request ${number}"
else
  gh pr create --base main --head "${branch}" --title "$(cat "${output}/title")" --body-file "${output}/body"
fi
