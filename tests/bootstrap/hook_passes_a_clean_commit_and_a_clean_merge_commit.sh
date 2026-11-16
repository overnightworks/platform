#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=hook_support.sh
source "$(dirname "${BASH_SOURCE[0]}")/hook_support.sh"
require_the_global_hook
repository="$(new_repository clean)"
echo more >"$repository/more.txt"
git -C "$repository" add more.txt
git -C "$repository" commit --quiet -m more || fail "the hook refused a clean commit"
git -C "$repository" merge --quiet --no-ff -m merge feature || fail "the hook refused a clean merge commit"
[ "$(git -C "$repository" rev-list --count --merges HEAD)" = 1 ] || fail "no merge commit was recorded"
