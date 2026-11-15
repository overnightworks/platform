#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=hook_support.sh
source "$(dirname "${BASH_SOURCE[0]}")/hook_support.sh"
require_the_global_hook
repository="$(new_repository merge)"
# The secret reaches main only through the merge, so the refusal is pre-merge-commit's, which git runs for a merge
# that commits by itself; a merge stopped with --no-commit is committed by `git commit`, which runs pre-commit.
git -C "$repository" switch --quiet feature
stage_dummy_secret "$repository"
git -C "$repository" -c core.hooksPath=/dev/null commit --quiet -m secret
git -C "$repository" switch --quiet main
before="$(commit_count "$repository")"
output="$(git -C "$repository" merge --no-ff -m merge feature 2>&1)" && fail "git recorded a merge commit that brings in a dummy secret: $output"
grep -qF credentials.txt <<<"$output" || fail "the refusal names no file: $output"
[ "$(commit_count "$repository")" = "$before" ] || fail "a merge commit was recorded despite the refusal"
git -C "$repository" merge --abort
git -C "$repository" -c core.hooksPath=/dev/null merge --quiet --no-ff -m merge feature ||
  fail "the control merge without the hook failed, so the refusal proves nothing"
[ "$(git -C "$repository" rev-list --count --merges HEAD)" = 1 ] || fail "the control merge is no merge commit"
