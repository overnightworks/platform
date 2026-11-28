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

# keep_mise_directories: mise keeps its tools, trust, state and cache where they are, whichever HOME or XDG directory the
# cell replaces next; call it before the replacement. It exports the four directories and lists them as
# mise_dirs=(NAME=value ...) for a cell that runs a command under `env -i`.
keep_mise_directories() {
  export MISE_DATA_DIR="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
  export MISE_STATE_DIR="${MISE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mise}"
  export MISE_CACHE_DIR="${MISE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mise}"
  export MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}"
  mise_dirs=("MISE_DATA_DIR=${MISE_DATA_DIR}" "MISE_STATE_DIR=${MISE_STATE_DIR}" "MISE_CACHE_DIR=${MISE_CACHE_DIR}"
    "MISE_CONFIG_DIR=${MISE_CONFIG_DIR}")
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

# seconds_of_timespan <systemd time span>: the whole seconds `systemd-analyze timespan` reads it as.
seconds_of_timespan() { systemd-analyze timespan "$1" | awk '/^ *[^ ]+s: /{ print int($2 / 1000000) }'; }

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
