#!/usr/bin/env bash
# Usage: tests/postgres/server_ready_gives_up_past_its_bound.sh
# Needs no cluster. Runs `server_ready.sh` against a pg_isready that never answers and a sleep that returns at once,
# and judges that it ends 1 after as many attempts as the script's wait_seconds, with one line on stderr that names the
# bound. The wait's bound is the one branch the cluster cells cannot arrange; the cells of the cluster job run every
# other branch of the scripts that follow the wait against a real server. The postStart hook of the StatefulSet then
# runs against the same silent server and must end 0 without either keep running.
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

# The hook enters the roles volume by its mount path and runs the two keeps there; here the volume holds the real wait
# and keeps that only record their run.
mount_path=/etc/postgres-roles
mkdir "$work/roles"
cp "$script" "$work/roles/"
for keep in app_role reader_role; do
  printf '#!/bin/sh\necho "%s $*" >>"$FAKE_CALLS/keeps"\n' "$keep" >"$work/roles/$keep.sh"
done
mapfile -d '' -t hook < <(yq -0 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "postgres")
  | .lifecycle.postStart.exec.command[]' "$repository_root/infrastructure/postgres/postgres.yaml")
[ "${#hook[@]}" -gt 0 ] || fail "the StatefulSet postgres declares no postStart command"
[[ ${hook[*]} == *"$mount_path"* ]] || fail "the postStart hook does not enter $mount_path"
hook=("${hook[@]//"$mount_path"/"$work/roles"}")
status=0
FAKE_CALLS="$work" PATH="$work/bin:$PATH" "${hook[@]}" >/dev/null 2>&1 || status=$?
[ "$status" = 0 ] || fail "the postStart hook ended $status with no server, not 0"
[ ! -e "$work/keeps" ] || fail "the postStart hook ran a keep with no server answering: $(cat "$work/keeps")"
echo "the postStart hook ended 0 with no server and ran neither keep"
