#!/usr/bin/env bash
set -eo pipefail
export PATH="$HOME/.local/bin:$PATH"
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# Each line holds a path and its type; a non-directory also holds its size and timestamp. Directory timestamps are
# not compared, but the paths inside every directory are. uv's cache and mise's own cache are not state of the hook.
list_state() {
  find "$HOME/.local/bin" "$HOME/.local/share/mise" "$HOME/.local/share/uv/tools" "$HOME/.local/share/platform" "$HOME/.gitconfig" \
    \( -type d -printf '%y %p\n' \) -o \( -printf '%y %p %s %T@\n' \) | sort
}
list_state >"$scratch/before"
git config --global --list >"$scratch/config-before"
scripts/bootstrap_pc.sh --only dotfiles
mise run bootstrap:hook
list_state >"$scratch/after"
git config --global --list >"$scratch/config-after"
diff "$scratch/before" "$scratch/after" >"$scratch/diff" || { echo "::error::the second run changed the installed state:"; cat "$scratch/diff"; exit 1; }
diff "$scratch/config-before" "$scratch/config-after" || fail "the second run changed git's global configuration"
