#!/usr/bin/env bash
# Usage: tests/postgres/reader_keep_gives_up_past_its_bound.sh
# Needs kubectl and yq, and no cluster. Runs `reader.sh keep` against a pg_isready that never answers and a sleep that
# returns at once, and judges that it ends 0 after as many attempts as the script's wait_seconds, with one line on
# stderr that names the bound, and never reaches psql. The wait's bound is the one branch the cluster cells cannot
# arrange; the cells of the cluster job run every other branch of reader.sh against a real server.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/mounted"

# The ConfigMap's files as the container mounts them: the script beside its key connections.
cp "$repository_root/infrastructure/postgres/scripts/reader.sh" "$work/mounted/"
kubectl kustomize "$repository_root/infrastructure/postgres" |
  yq --no-doc 'select(.kind == "ConfigMap" and (.metadata.name | test("^postgres-reader-"))) | .data.connections' \
    >"$work/mounted/connections"
wait_seconds="$(sed -n 's/^wait_seconds=//p' "$work/mounted/reader.sh")"
[[ $wait_seconds =~ ^[1-9][0-9]*$ ]] || fail "reader.sh gives no wait_seconds as a whole number of seconds"

cat >"$work/bin/pg_isready" <<'FAKE'
#!/bin/sh
echo asked >>"$FAKE_CALLS/pg_isready"
exit 2
FAKE
cat >"$work/bin/sleep" <<'FAKE'
#!/bin/sh
exit 0
FAKE
cat >"$work/bin/psql" <<'FAKE'
#!/bin/sh
echo called >>"$FAKE_CALLS/psql"
FAKE
chmod +x "$work/bin/"*

status=0
FAKE_CALLS="$work" PGDATABASE=proof PATH="$work/bin:$PATH" sh "$work/mounted/reader.sh" keep 2>"$work/stderr" || status=$?
[ "$status" = 0 ] || fail "keep ended $status with no server, not 0"
[ "$(grep -c . "$work/pg_isready")" = "$wait_seconds" ] || fail "keep asked the server $(grep -c . "$work/pg_isready") times, not $wait_seconds"
[ ! -e "$work/psql" ] || fail "keep ran psql although no server answered"
[ "$(grep -c . "$work/stderr")" = 1 ] || fail "keep wrote $(grep -c . "$work/stderr") lines, not one: $(cat "$work/stderr")"
grep -qF "within $wait_seconds seconds" "$work/stderr" || fail "keep's line does not name its bound of $wait_seconds seconds: $(cat "$work/stderr")"
echo "keep asked $wait_seconds times, ended 0 and wrote: $(cat "$work/stderr")"
