#!/usr/bin/env bash
# Usage: tests/postgres/keep_runs_its_session_within_all_three_bounds.sh
# Needs no cluster. Runs `reader_role.sh keep`, which opens its session through the one owner keep_session.sh that
# app_role.sh keep shares, against a psql that records the options of its session, and judges that the session sets a
# lock_timeout, a statement_timeout and a transaction_timeout, each a whole number of seconds from 1 (0 switches a
# timeout off), so a lock that any session holds rolls the keep back within a bound.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/mounted"

# The ConfigMap's files as the container mounts them: the scripts beside their key connections.
cp "$repository_root"/infrastructure/postgres/scripts/*.sh "$work/mounted/"
echo 2 >"$work/mounted/connections"
cat >"$work/bin/psql" <<'FAKE'
#!/bin/sh
# The options span lines; unquoted, they print on one.
echo $PGOPTIONS >>"$FAKE_CALLS/session_options"
FAKE
chmod +x "$work/bin/psql"

status=0
FAKE_CALLS="$work" PGDATABASE=proof PATH="$work/bin:$PATH" sh "$work/mounted/reader_role.sh" keep 2>"$work/stderr" || status=$?
[ "$status" = 0 ] || fail "reader_role.sh keep ended $status against a psql that succeeds: $(cat "$work/stderr")"
[ "$(grep -c . "$work/session_options")" = 1 ] || fail "reader_role.sh keep opened $(grep -c . "$work/session_options") sessions, not one"
for bound in lock_timeout statement_timeout transaction_timeout; do
  grep -qE -- "-c $bound=[1-9][0-9]*s( |$)" "$work/session_options" ||
    fail "the session of reader_role.sh keep sets no $bound of whole seconds from 1: $(cat "$work/session_options")"
done
echo "the session of reader_role.sh keep sets lock_timeout, statement_timeout and transaction_timeout: $(tr '\n' ' ' <"$work/session_options")"
