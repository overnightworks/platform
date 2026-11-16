#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
hooks_directory="$HOME/.local/share/platform/git-hooks"
mise run bootstrap:hook
uv_tools="$(mise exec -- uv tool dir)"
# The gate's pin read from the workflow's text, not through the task's own yq call.
pin="$(sed -n 's|^ *uses: overnightworks/quality/\.github/workflows/gate\.yml@\([0-9a-f]\{40\}\) .*|\1|p' .github/workflows/ci.yml)"
[[ $pin =~ ^[0-9a-f]{40}$ ]] || fail "ci.yml holds no single full-commit pin of quality's gate: '$pin'"
grep -qF "overnightworks/quality?rev=$pin" "$uv_tools/overnightworks-quality/uv-receipt.toml" ||
  fail "uv's receipt of quality does not record the gate pin $pin"
quality --help >/dev/null || fail "quality does not start"
[ "$(git config --global --get core.hooksPath)" = "$hooks_directory" ] || fail "core.hooksPath does not name $hooks_directory"
