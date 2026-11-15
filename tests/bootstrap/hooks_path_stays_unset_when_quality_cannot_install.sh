#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
# A proxy nobody listens on, and an empty tool directory, so uv has nothing installed and cannot reach GitHub.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
dead_proxy=http://127.0.0.1:9
if env "UV_TOOL_DIR=$scratch/tools" "HTTPS_PROXY=$dead_proxy" "https_proxy=$dead_proxy" mise run bootstrap:hook >"$scratch/output" 2>&1; then
  fail "bootstrap:hook passed although quality could not be installed: $(cat "$scratch/output")"
fi
grep -qF 'bootstrap:hook: uv could not install quality' "$scratch/output" || fail "the task named no failed install: $(cat "$scratch/output")"
if git config --global --get core.hooksPath; then
  fail "core.hooksPath is set although quality was not installed"
fi
