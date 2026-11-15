# shellcheck shell=bash
# Sourced by the hook cells, which run after `mise run bootstrap:hook` made the global hook the one git calls.
export PATH="$HOME/.local/bin:$PATH"
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
hooks_directory="$HOME/.local/share/platform/git-hooks"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# A key shape gitleaks flags, made at run time so that no value of the tree looks like a real key.
dummy_secret() {
  printf 'AKIA%s' "$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"
}

require_the_global_hook() {
  [ "$(git config --global --get core.hooksPath)" = "$hooks_directory" ] ||
    fail "core.hooksPath is not $hooks_directory; mise run bootstrap:hook comes first"
}

# new_repository <name> makes a repository with one clean commit, a branch `feature` with another, and main checked out.
new_repository() {
  local repository="$scratch/$1"
  git init --quiet -b main "$repository"
  git -C "$repository" config user.name cell
  git -C "$repository" config user.email cell@example.invalid
  echo base >"$repository/base.txt"
  git -C "$repository" add base.txt
  git -C "$repository" commit --quiet -m base || fail "the hook refused a clean first commit in $1"
  git -C "$repository" switch --quiet -c feature
  echo feature >"$repository/feature.txt"
  git -C "$repository" add feature.txt
  git -C "$repository" commit --quiet -m feature || fail "the hook refused a clean commit on feature in $1"
  git -C "$repository" switch --quiet main
  echo "$repository"
}

stage_dummy_secret() {
  printf 'aws_access_key_id = %s\n' "$(dummy_secret)" >"$1/credentials.txt"
  git -C "$1" add credentials.txt
}

commit_count() {
  git -C "$1" rev-list --count --all
}
