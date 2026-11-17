#!/usr/bin/env bash
# Drive the task `mise run backup:fetch` against a fake kubectl, for the outcome the cluster cannot arrange: a latest
# snapshot that is no custom-format dump ends the task non-zero, names the file and leaves no file behind, while a dump
# stays at mode 0600.
# Usage: mise exec -- tests/backup/backup_fetch_deletes_a_file_that_holds_no_custom_format_dump.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"

# The fake answers what the task reads; FAKE_DUMP is what the holder container prints for the file the snapshot holds.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"get cronjob restore-test"*)
    printf '%s' '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"volumes":[{"name":"restore"}],"initContainers":[{"image":"restic","securityContext":{}}]}}}}}}' ;;
  *"create --filename -"*) cat >/dev/null ;;
  *"get pod"*) printf Running ;;
  *" exec "*) printf '%s' "$FAKE_DUMP" ;;
  *"delete pod"*) ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake_bin/kubectl"

# fetch <dump content> <file>: sets task_status and task_output.
task_status=0
task_output=
fetch() {
  task_status=0
  task_output="$(cd "$repository_root" && PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl KUBECONFIG=/nonexistent FAKE_DUMP="$1" \
    mise run backup:fetch somewhere "$2" 2>&1)" || task_status=$?
}

not_a_dump="$work_directory/not_a_dump"
fetch "SQLite format 3" "$not_a_dump"
{ [ "$task_status" = 1 ] && [[ $task_output == *"$not_a_dump holds no custom-format dump; it is deleted"* ]]; } ||
  fail "a file that holds no dump ended $task_status with '$task_output'"
[ ! -e "$not_a_dump" ] || fail "the file that holds no dump was left behind"
echo "backup:fetch ends non-zero naming a file that holds no custom-format dump and deletes it"

a_dump="$work_directory/a_dump"
fetch "PGDMP and the rest" "$a_dump"
{ [ "$task_status" = 0 ] && [ "$(stat --format=%a "$a_dump")" = 600 ]; } ||
  fail "a custom-format dump ended $task_status with '$task_output', mode $(stat --format=%a "$a_dump" 2>&1)"
echo "backup:fetch keeps a custom-format dump at mode 0600"
