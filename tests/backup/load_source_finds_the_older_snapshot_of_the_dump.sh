#!/usr/bin/env bash
# Run the source step of scripts/load_snapshot.sh against a fake restic that holds a newer staging snapshot of another
# dump and an older staging snapshot of the dump to load, the order of restore-a-database.md (fetch the dump, backup:now,
# load the fetched dump): the older snapshot is picked, and a dump no snapshot holds exits 3.
# Usage: mise exec -- tests/backup/load_source_finds_the_older_snapshot_of_the_dump.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
mkdir "$work_directory/bin" "$work_directory/restore"

# The script the Pod's source container runs, with its scratch directory in the work directory.
awk "/^read -r -d '' source_script <<'SCRIPT'/{f=1;next} f&&/^SCRIPT\$/{exit} f" "$repository_root/scripts/load_snapshot.sh" |
  sed "s#/restore#$work_directory/restore#g" >"$work_directory/source.sh"
[ -s "$work_directory/source.sh" ] || fail "scripts/load_snapshot.sh holds no source script"

cat >"$work_directory/bin/restic" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
  *" snapshots "*) printf '[{"id":"older","time":"2026-11-20T03:00:00Z"},{"id":"newer","time":"2026-11-26T03:00:00Z"}]' ;;
  *" dump older "*) printf 'dump\tolder-dump-sha\t10\nfile\t5\t1\tbucket/a\nfile\t7\t1\tfiles/x\n' ;;
  *" dump newer "*) printf 'dump\tnewer-dump-sha\t10\nfile\t5\t1\tbucket/a\nfile\t7\t1\tfiles/x\n' ;;
  *) echo "fake restic: unexpected $args" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work_directory/bin/restic"

# source_of <dump sha256>: sets source_status and source_output.
source_status=0
source_output=
source_of() {
  source_status=0
  source_output="$(PATH="$work_directory/bin:$PATH" sh -c "$(cat "$work_directory/source.sh")" source "$1")" || source_status=$?
}

source_of older-dump-sha
{ [ "$source_status" = 0 ] && [ "$(awk '$1 == "snapshot" { print $2 }' <<<"$source_output")" = older ]; } ||
  fail "the dump of the older snapshot ended $source_status with '$source_output'"
echo "the source step picks the older snapshot whose MANIFEST holds the dump, past a newer snapshot of another dump"

source_of newer-dump-sha
[ "$(awk '$1 == "snapshot" { print $2 }' <<<"$source_output")" = newer ] || fail "the newer dump was read as '$source_output'"

source_of no-snapshot-holds-this
[ "$source_status" = 3 ] || fail "a dump no snapshot holds ended $source_status, not 3"
echo "the source step exits 3 for a dump no snapshot holds"
