#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The role room of stage_files.sh never reads a signal as a fit: a TERM that reaches it while its awk runs ends it non-zero
# at once, where the roles that serve a step end 0 on a TERM. awk is a stand-in that outlasts the signal.
script="$PWD/infrastructure/postgres/backup/files/scripts/stage_files.sh"
[ -f "$script" ] || fail "$script is missing"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '#!/bin/sh\nsleep 3\nexit 0\n' >"$work/awk"
chmod +x "$work/awk"
PATH="$work:$PATH" sh "$script" room 1000 1000 900 1 >/dev/null &
role=$!
sleep 1
kill -TERM "$role"
status=0
wait "$role" || status=$?
[ "$status" != 0 ] || fail "the role room ended 0, a fit, after a TERM"
echo "the role room ended with exit $status after a TERM, not as a fit"
