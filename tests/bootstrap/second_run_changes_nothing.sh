#!/usr/bin/env bash
set -eo pipefail
# Each line holds a path and its type; a non-directory also holds its size and timestamp. Directory timestamps
# are not compared (mise refreshes the shims directory's on every run), but the paths inside every directory are.
list_state() {
  find "$HOME/.local/bin" "$HOME/.local/share/mise" \( -type d -printf '%y %p\n' \) -o \( -printf '%y %p %s %T@\n' \) | sort
}
list_state >"$RUNNER_TEMP/before-second-run"
scripts/bootstrap_pc.sh --only tools
list_state >"$RUNNER_TEMP/after-second-run"
diff "$RUNNER_TEMP/before-second-run" "$RUNNER_TEMP/after-second-run" >"$RUNNER_TEMP/second-run.diff" ||
  { echo "::error::the second run changed the installed state:"; cat "$RUNNER_TEMP/second-run.diff"; exit 1; }
