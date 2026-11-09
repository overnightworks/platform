#!/usr/bin/env bash
# Proves docs/operations.md OPS-11.
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
unit=.bootstrap.linux.systemd.units.trash-prune
exec_start="$(mise exec -- yq -p toml -oy "$unit.exec_start" mise.toml)"
exec_start_pre="$(mise exec -- yq -p toml -oy "$unit.exec_start_pre[0]" mise.toml)"
# The unit's own arguments and pre-command with systemd's %h and the cell's home directory; the binary is the locked one.
test_home="$(mktemp -d)"
trap 'rm -rf "$test_home"' EXIT
read -r -a service_args <<<"${exec_start//%h/$test_home}"
read -r -a pre_args <<<"${exec_start_pre//%h/$test_home}"
[ "${service_args[1]}" = prune ] || fail "the service's ExecStart '$exec_start' does not run gtrash prune"
gtrash_bin="$(mise exec -- which gtrash)"
trash="$test_home/.local/share/Trash"
trashed_on() { # name, days ago
  printf '[Trash Info]\nPath=/work/%s\nDeletionDate=%s\n' "$1" "$(date -d "$2 days ago" +%Y-%m-%dT%H:%M:%S)" \
    >"$trash/info/$1.trashinfo"
}
run_service() { (cd "$test_home" && HOME="$test_home" "${pre_args[@]}" && HOME="$test_home" "$gtrash_bin" "${service_args[@]:1}" </dev/null); }

run_service >/dev/null || fail "the unit failed with no Trash directory"
[ -d "$trash" ] || fail "the unit left no Trash directory behind"
run_service >/dev/null || fail "the unit failed on an empty Trash"

mkdir -p "$trash/files" "$trash/info" "$trash/files/yesterday"
echo old >"$trash/files/month_old"
trashed_on month_old 31
echo kept >"$trash/files/yesterday/notes"
touch -d 2020-01-01 "$trash/files/yesterday/notes" "$trash/files/yesterday"
trashed_on yesterday 1
echo new >"$trash/files/no_info_new"
echo old >"$trash/files/no_info_2020"
touch -d 2020-01-01 "$trash/files/no_info_2020"
run_service >/dev/null || fail "the unit failed on a Trash with old and new entries"
[ ! -e "$trash/files/month_old" ] || fail "the entry deleted 31 days ago is still in files/"
[ ! -e "$trash/info/month_old.trashinfo" ] || fail "the entry deleted 31 days ago left its .trashinfo"
[ -f "$trash/files/yesterday/notes" ] || fail "the directory deleted yesterday lost its file with the 2020 timestamp"
[ -f "$trash/info/yesterday.trashinfo" ] || fail "the directory deleted yesterday lost its .trashinfo"
[ -f "$trash/files/no_info_new" ] || fail "the entry without a .trashinfo and a new timestamp was deleted"
[ -f "$trash/files/no_info_2020" ] || fail "the entry without a .trashinfo and a 2020 timestamp was deleted"
echo "the unit's gtrash deleted the entry trashed 31 days ago with its .trashinfo, kept the directory trashed yesterday" \
  "with its 2020 files and both entries without a .trashinfo, and passed on a missing and an empty Trash"
