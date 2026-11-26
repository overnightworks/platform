#!/usr/bin/env bash
# Proves that the file the bootstrap writes to the path dockerd reads is a configuration dockerd accepts.
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
source_file=host/docker/daemon.json
target="$(mise exec -- yq -p toml -oy ".bootstrap.files | to_entries | .[] | select(.value.source == \"$source_file\") | .key" mise.toml)"
[ -n "$target" ] || fail "mise.toml declares no file with the source $source_file"

# dockerd reads its default path only when no flag names another file.
default_path="$(dockerd --help | tr '\n' ' ' | sed -nE 's/.*--config-file string +Daemon configuration file +\(default +"([^"]+)"\).*/\1/p')"
[ "$default_path" = "$target" ] || fail "dockerd reads '$default_path' by default, mise.toml writes $target"

dockerd --validate --config-file "$source_file" || fail "dockerd refuses $source_file"
echo "$target is the file dockerd reads by default, and dockerd --validate accepts $source_file"
