#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The role room of stage_files.sh never reads a signal as a fit: a TERM that reaches it while its awk runs ends it non-zero
# at once, where the roles that serve a step end 0 on a TERM. awk is a stand-in that outlasts the signal.
script="$PWD/infrastructure/postgres/backup/files/scripts/stage_files.sh"
[ -f "$script" ] || fail "$script is missing"
work="$(mktemp -d)"
cleanup() {
  [ ! -s "$work/awk.pid" ] || kill "$(cat "$work/awk.pid")" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
# The stand-in records its pid and signals that the role has reached it, so the TERM never comes before the role's reset.
printf '#!/bin/sh\necho $$ >"%s/awk.pid"\n: >"%s/started"\nexec sleep 3\n' "$work" "$work" >"$work/awk"
chmod +x "$work/awk"
PATH="$work:$PATH" sh "$script" room 1000 1000 900 1 >/dev/null &
role=$!
tries=0
until [ -e "$work/started" ] || [ "$tries" -ge 100 ]; do tries=$((tries + 1)); sleep 0.1; done
[ -e "$work/started" ] || fail "the role room never ran its awk"
kill -TERM "$role"
status=0
wait "$role" || status=$?
[ "$status" != 0 ] || fail "the role room ended 0, a fit, after a TERM"
echo "the role room ended with exit $status after a TERM, not as a fit"
