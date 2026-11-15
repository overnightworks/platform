#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=hook_support.sh
source "$(dirname "${BASH_SOURCE[0]}")/hook_support.sh"
require_the_global_hook
repository="$(new_repository merge)"
before="$(commit_count "$repository")"
git -C "$repository" merge --quiet --no-ff --no-commit feature
stage_dummy_secret "$repository"
output="$(git -C "$repository" commit -m merge 2>&1)" && fail "git recorded a merge commit that stages a dummy secret: $output"
grep -qF credentials.txt <<<"$output" || fail "the refusal names no file: $output"
[ "$(commit_count "$repository")" = "$before" ] || fail "a merge commit was recorded despite the refusal"
git -C "$repository" -c core.hooksPath=/dev/null commit --quiet -m merge ||
  fail "the control merge commit without the hook failed, so the refusal proves nothing"
[ "$(git -C "$repository" rev-list --count --merges HEAD)" = 1 ] || fail "the control commit is no merge commit"
