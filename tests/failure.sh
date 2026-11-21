# shellcheck shell=bash
# Sourced by the scripts under tests/.
fail() { echo "::error::$1"; exit 1; }

# expect_problem <expected text> <description of the change> <judgement command>...: the judgement, run on an input
# changed to break one rule, prints a `problem:` line that holds the text; else the script fails. The command's other
# output is not read.
expect_problem() {
  local expected="$1" description="$2" problems
  shift 2
  problems="$("$@" | grep '^problem: ' || true)"
  grep -qF -- "$expected" <<<"$problems" ||
    fail "the mutant '$description' made the judgement report '${problems:-nothing}', not '$expected'"
  echo "the mutant '$description' is red: ${problems%%$'\n'*}"
}

# until_true <seconds> <description> <command>...: the command passes within the time, tried every 5 seconds.
until_true() {
  local deadline=$((SECONDS + $1)) description="$2"
  shift 2
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "within the time: $description"
    sleep 5
  done
}

# A cell's exit trap deletes its objects with delete_object, which attempts every deletion and names the one that fails;
# end_deletions then keeps the cell's own failure status and else fails when a deletion did.
deletion_failures=0
delete_object() {
  if ! kubectl "$@"; then
    echo "::error::the deletion 'kubectl $*' failed"
    deletion_failures=$((deletion_failures + 1))
  fi
}
end_deletions() {
  local cell_status="$1"
  if [ "$cell_status" -ne 0 ]; then
    exit "$cell_status"
  fi
  if [ "$deletion_failures" -ne 0 ]; then
    exit 1
  fi
}
