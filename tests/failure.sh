# shellcheck shell=bash
# Sourced by the scripts under tests/.
fail() { echo "::error::$1"; exit 1; }

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
