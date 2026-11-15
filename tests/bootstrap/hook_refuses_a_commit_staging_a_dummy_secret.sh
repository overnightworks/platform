#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=hook_support.sh
source "$(dirname "${BASH_SOURCE[0]}")/hook_support.sh"
require_the_global_hook
repository="$(new_repository commit)"
before="$(commit_count "$repository")"
stage_dummy_secret "$repository"
output="$(git -C "$repository" commit -m secret 2>&1)" && fail "git recorded a commit that stages a dummy secret: $output"
grep -qF credentials.txt <<<"$output" || fail "the refusal names no file: $output"
[ "$(commit_count "$repository")" = "$before" ] || fail "a commit was recorded despite the refusal"
# The same change passes with the hook off, so the refusal is the hook's.
git -C "$repository" -c core.hooksPath=/dev/null commit --quiet -m secret ||
  fail "the control commit without the hook failed, so the refusal proves nothing"
