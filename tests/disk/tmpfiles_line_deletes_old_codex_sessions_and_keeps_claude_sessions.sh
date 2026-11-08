#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
command -v systemd-tmpfiles >/dev/null || apt-get install --yes --no-install-recommends systemd >/dev/null
export PATH="$HOME/.local/bin:$PATH"
# The committed line with its age shortened to seconds; its type and path stay as committed.
age_seconds=3
line="$(grep '^e ' host/disk/user-tmpfiles.conf)"
short_line="$(sed -E "s/ [0-9a-z]+\$/ ${age_seconds}s/" <<<"$line")"
[ "$short_line" != "$line" ] || fail "the line '$line' sets no age"
test_home="$(mktemp -d)"
config="$test_home/disk.conf"
echo "$short_line" >"$config"
sessions_dir="$test_home$(awk '{ print $2 }' <<<"$line" | sed 's|^%h||')"
mkdir -p "$sessions_dir/2026/10/01" "$test_home/.claude/projects/p"
echo old >"$sessions_dir/2026/10/01/old.jsonl"
echo old >"$test_home/.claude/projects/p/old-session.jsonl"
sleep $((age_seconds + 2))
mkdir -p "$sessions_dir/2026/11/08"
echo new >"$sessions_dir/2026/11/08/new.jsonl"
# The flags are the service's own; only the configuration's path and the home directory are the test's.
exec_start="$(mise exec -- yq -p toml -oy '.bootstrap.linux.systemd.units.user-tmpfiles-clean.exec_start' mise.toml)"
mapfile -t service_flags < <(tr ' ' '\n' <<<"$exec_start" | grep -- '^--')
[ "${#service_flags[@]}" -gt 0 ] || fail "the service's ExecStart '$exec_start' holds no flag"
HOME="$test_home" systemd-tmpfiles "${service_flags[@]}" "$config"
[ ! -e "$sessions_dir/2026/10" ] || fail "the clean kept $(find "$sessions_dir/2026/10" | tr '\n' ' ')"
[ -f "$sessions_dir/2026/11/08/new.jsonl" ] || fail "the clean deleted the session younger than ${age_seconds}s"
[ -f "$test_home/.claude/projects/p/old-session.jsonl" ] || fail "the clean deleted a Claude session"
echo "the line at ${age_seconds}s deleted the older Codex session with its emptied directories and kept the newer one" \
  "and a Claude session of the older one's age"
