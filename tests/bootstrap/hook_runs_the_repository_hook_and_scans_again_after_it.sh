#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=hook_support.sh
source "$(dirname "${BASH_SOURCE[0]}")/hook_support.sh"
require_the_global_hook
repository="$(new_repository chain)"
install_repository_hook() {
  printf '#!/bin/sh\n%s\n' "$1" >"$repository/.git/hooks/pre-commit"
  chmod 755 "$repository/.git/hooks/pre-commit"
}
secret_line="$(dummy_secret)"
echo more >"$repository/more.txt"
git -C "$repository" add more.txt

# A repository hook that only records its run: the commit passes and the hook ran.
install_repository_hook "touch '$scratch/repository-hook-ran'"
git -C "$repository" commit --quiet -m ran || fail "the hook refused a commit whose repository hook passes"
[ -e "$scratch/repository-hook-ran" ] || fail "the repository hook did not run"

# A repository hook that fails blocks the commit.
install_repository_hook "exit 1"
echo again >"$repository/again.txt"
git -C "$repository" add again.txt
before="$(commit_count "$repository")"
git -C "$repository" commit --quiet -m failing && fail "git recorded a commit whose repository hook failed"
[ "$(commit_count "$repository")" = "$before" ] || fail "a commit was recorded despite the failed repository hook"

# A repository hook that stages a secret after the first scan is caught by the second.
install_repository_hook "printf 'aws_access_key_id = %s\n' '$secret_line' >credentials.txt && git add credentials.txt"
output="$(git -C "$repository" commit -m staged-by-hook 2>&1)" && fail "git recorded a commit whose repository hook staged a secret: $output"
grep -qF credentials.txt <<<"$output" || fail "the second scan names no file: $output"
[ "$(commit_count "$repository")" = "$before" ] || fail "a commit was recorded despite the second scan"
