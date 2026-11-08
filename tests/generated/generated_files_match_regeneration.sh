#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
generated=(clusters/pc/flux-system/gotk-components.yaml mise.lock infrastructure/)
mise run flux:export
mise lock
mise run charts:render
mise run legal:build

# An ignored output would escape the status below.
ignore_status=0
ignored="$(find "${generated[@]}" -type f | git check-ignore --no-index --stdin)" || ignore_status=$?
case "$ignore_status" in
  0) fail "git ignores ${ignored//$'\n'/ }, which the comparison below would not see" ;;
  1) echo "git ignores none of ${generated[*]}" ;;
  *) fail "git check-ignore failed with exit $ignore_status" ;;
esac

# git diff alone would miss a file the regeneration adds and the commit lacks.
changes="$(git status --porcelain --untracked-files=all -- "${generated[@]}")"
if [ -n "$changes" ]; then
  echo "::error::the regeneration changed, added or deleted generated files:"
  printf '%s\n' "$changes"
  git diff -- "${generated[@]}"
  exit 1
fi
echo "the regeneration of ${generated[*]} matches the commit"
