#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=hook_support.sh
source "$(dirname "${BASH_SOURCE[0]}")/hook_support.sh"
repository="$(new_repository missing)"
echo more >"$repository/more.txt"
git -C "$repository" add more.txt
# A home without quality, the hook files the dotfiles step wrote.
empty_home="$scratch/empty-home"
mkdir -p "$empty_home"
for hook in pre-commit pre-merge-commit; do
  status=0
  (cd "$repository" && HOME="$empty_home" "$hooks_directory/$hook") 2>"$scratch/stderr" || status=$?
  [ "$status" = 2 ] || fail "$hook ended $status without quality, not 2"
  grep -qF "quality is missing" "$scratch/stderr" || fail "$hook names no missing quality: $(cat "$scratch/stderr")"
done
before="$(commit_count "$repository")"
HOME="$empty_home" git -C "$repository" -c "core.hooksPath=$hooks_directory" commit --quiet -m blocked 2>/dev/null &&
  fail "git recorded a commit although quality is missing"
[ "$(commit_count "$repository")" = "$before" ] || fail "a commit was recorded although quality is missing"
