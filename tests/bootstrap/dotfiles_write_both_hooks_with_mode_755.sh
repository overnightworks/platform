#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
hooks_directory="$HOME/.local/share/platform/git-hooks"
for hook in pre-commit pre-merge-commit; do
  cmp --silent host/git-hooks/git_hook "$hooks_directory/$hook" || fail "$hooks_directory/$hook is missing or differs from host/git-hooks/git_hook"
  [ "$(stat --format=%a "$hooks_directory/$hook")" = 755 ] || fail "$hooks_directory/$hook is not mode 755"
done
# The dotfiles step only writes the files; core.hooksPath is bootstrap:hook's last act.
if git config --global --get core.hooksPath; then
  fail "core.hooksPath is set before bootstrap:hook ran"
fi
