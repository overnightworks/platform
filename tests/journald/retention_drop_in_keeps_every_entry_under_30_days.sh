#!/usr/bin/env bash
# Proves the host journal's bound of 29 days, under the 30 days the privacy texts promise.
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
apt-get install --yes --no-install-recommends systemd >/dev/null
source_file=host/journald/90-retention.conf
promised_seconds=$((29 * 24 * 3600))
target="$(mise exec -- yq -p toml -oy ".bootstrap.files | to_entries | .[] | select(.value.source == \"$source_file\") | .key" mise.toml)"
[ -n "$target" ] || fail "mise.toml declares no file with the source $source_file"

# The drop-in sits where systemd reads it and holds both keys.
root="$RUNNER_TEMP/journald-root"
mkdir -p "$root$(dirname "$target")"
cp "$source_file" "$root$target"
config="$(systemd-analyze cat-config --root="$root" systemd/journald.conf)"
grep -qxF "# $root$target" <<<"$config" || fail "cat-config does not list $target: $config"
value_of() { sed -n "s/^$1=//p" <<<"$config" | tail -n 1; }
seconds_of() { systemd-analyze timespan "$1" | awk '/^ *[^ ]+s: /{ print int($2 / 1000000) }'; }
retention_value="$(value_of MaxRetentionSec)"
[ -n "$retention_value" ] || fail "cat-config shows no MaxRetentionSec"
file_value="$(value_of MaxFileSec)"
[ -n "$file_value" ] || fail "cat-config shows no MaxFileSec"
retention_seconds="$(seconds_of "$retention_value")"
file_seconds="$(seconds_of "$file_value")"

# journald deletes a file once its oldest entry passes the retention, and a file spans MaxFileSec, so an entry
# is as old as both limits together when it goes.
[ "$retention_seconds" -gt 0 ] || fail "MaxRetentionSec is $retention_seconds seconds"
[ "$file_seconds" -gt 0 ] || fail "MaxFileSec is $file_seconds seconds"
[ $((retention_seconds + file_seconds)) -le "$promised_seconds" ] ||
  fail "the limits add up to $((retention_seconds + file_seconds)) seconds, over $promised_seconds"

# Every name the file's notification holds is a service mise is told to manage.
mapfile -t notified < <(mise exec -- yq -p toml -oy ".bootstrap.files[\"$target\"].notify[]" mise.toml)
[ "${#notified[@]}" -gt 0 ] || fail "the entry for $target notifies no service"
for name in "${notified[@]}"; do
  [ "$(mise exec -- yq -p toml -oy ".bootstrap.services | has(\"$name\")" mise.toml)" = true ] ||
    fail "$target notifies $name, which [bootstrap.services] does not declare"
done
echo "the drop-in at $target holds both limits, which add up to $((retention_seconds + file_seconds)) seconds," \
  "within $promised_seconds, and notifies only declared services: ${notified[*]}"
