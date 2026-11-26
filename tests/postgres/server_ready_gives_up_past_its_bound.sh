#!/usr/bin/env bash
# Usage: tests/postgres/server_ready_gives_up_past_its_bound.sh
# Needs no cluster. Runs `server_ready.sh` against a pg_isready that never answers and a sleep that returns at once,
# and judges that it ends 1 after as many attempts as the script's wait_seconds, with one line on stderr that names the
# bound. The wait's bound is the one branch the cluster cells cannot arrange; the cells of the cluster job run every
# other branch of the scripts that follow the wait against a real server.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

script="$repository_root/infrastructure/postgres/scripts/server_ready.sh"
wait_seconds="$(sed -n 's/^wait_seconds=//p' "$script")"
[[ $wait_seconds =~ ^[1-9][0-9]*$ ]] || fail "server_ready.sh gives no wait_seconds as a whole number of seconds"

cat >"$work/bin/pg_isready" <<'FAKE'
#!/bin/sh
echo asked >>"$FAKE_CALLS/pg_isready"
exit 2
FAKE
cat >"$work/bin/sleep" <<'FAKE'
#!/bin/sh
exit 0
FAKE
chmod +x "$work/bin/"*

status=0
FAKE_CALLS="$work" PATH="$work/bin:$PATH" sh "$script" 2>"$work/stderr" || status=$?
[ "$status" = 1 ] || fail "server_ready.sh ended $status with no server, not 1"
[ "$(grep -c . "$work/pg_isready")" = "$wait_seconds" ] || fail "server_ready.sh asked the server $(grep -c . "$work/pg_isready") times, not $wait_seconds"
[ "$(grep -c . "$work/stderr")" = 1 ] || fail "server_ready.sh wrote $(grep -c . "$work/stderr") lines, not one: $(cat "$work/stderr")"
grep -qF "within $wait_seconds seconds" "$work/stderr" || fail "server_ready.sh's line does not name its bound of $wait_seconds seconds: $(cat "$work/stderr")"
echo "server_ready.sh asked $wait_seconds times, ended 1 and wrote: $(cat "$work/stderr")"
