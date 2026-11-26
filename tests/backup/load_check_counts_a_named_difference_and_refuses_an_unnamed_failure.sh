#!/usr/bin/env bash
# Run the bucket check step of scripts/load_snapshot.sh, as the loader's rclone container runs it, against a fake rclone
# whose `check` ends with a chosen status and writes a chosen combined list: status 0 prints no difference, status 1
# with a list that names a difference prints its count, status 1 with a list that names none and status 2 or higher
# fail.
# Usage: mise exec -- tests/backup/load_check_counts_a_named_difference_and_refuses_an_unnamed_failure.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
mkdir "$work_directory/bin"

# The size function and the check body the Pod's rclone container runs, with the list in the work directory.
for block in size_function check_body; do
  awk "/^read -r -d '' $block <<'SCRIPT'/{f=1;next} f&&/^SCRIPT\$/{exit} f" "$repository_root/scripts/load_snapshot.sh"
done | sed "s#/tmp/check#$work_directory/list#g" >"$work_directory/check.sh"
[ -s "$work_directory/check.sh" ] || fail "scripts/load_snapshot.sh holds no check script"

cat >"$work_directory/bin/rclone" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  size) printf '{"count": 3,"bytes": 42}\n' ;;
  check)
    while [ "$#" -gt 0 ]; do [ "$1" != --combined ] || list="$2"; shift; done
    printf '%b' "$FAKE_LIST" >"$list"
    exit "$FAKE_STATUS" ;;
  *) echo "fake rclone: unexpected $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work_directory/bin/rclone"

# check_with <status> <list>: sets check_status and check_output.
check_status=0
check_output=
check_with() {
  check_status=0
  check_output="$(FAKE_STATUS="$1" FAKE_LIST="$2" BUCKET=bucket PATH="$work_directory/bin:$PATH" sh -c "$(cat "$work_directory/check.sh")")" ||
    check_status=$?
}

check_with 0 '= a\n= b\n'
{ [ "$check_status" = 0 ] && [ "$check_output" = "3 42 0" ]; } || fail "equal lists ended $check_status with '$check_output'"
echo "the check step prints 0 differing for a bucket that equals the scratch"

check_with 1 '= a\n* b\n- c\n'
{ [ "$check_status" = 0 ] && [ "$check_output" = "3 42 2" ]; } || fail "a list naming two differences ended $check_status with '$check_output'"
echo "the check step counts the differences a status 1 list names"

check_with 1 '= a\n= b\n'
[ "$check_status" != 0 ] || fail "status 1 with a list that names no difference ended 0 with '$check_output'"
echo "the check step fails for status 1 with a list that names no difference"

check_with 1 ''
[ "$check_status" != 0 ] || fail "status 1 with an empty list ended 0 with '$check_output'"
echo "the check step fails for status 1 with an empty list"

check_with 2 '= a\n* b\n'
[ "$check_status" != 0 ] || fail "status 2 ended 0 with '$check_output'"
echo "the check step fails for status 2 even where the list names a difference"
