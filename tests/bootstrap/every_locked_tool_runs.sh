#!/usr/bin/env bash
set -eo pipefail
export PATH="$HOME/.local/bin:$PATH"
missing="$(mise ls --current --missing)"
[ -z "$missing" ] || { echo "::error::tools missing: $missing"; exit 1; }
# Every executable of every locked tool must start, so a tool added to mise.toml is covered without an edit here.
bin_paths="$(mise bin-paths)"
[ -n "$bin_paths" ] || { echo "::error::mise bin-paths printed no tool path"; exit 1; }
for bin_path in $bin_paths; do
  binaries="$(find -L "$bin_path" -maxdepth 1 -type f -executable)"
  [ -n "$binaries" ] || { echo "::error::no executable in $bin_path"; exit 1; }
  for binary in $binaries; do
    echo "$binary"
    "$binary" --help >/dev/null || { echo "::error::$binary does not run"; exit 1; }
  done
done
