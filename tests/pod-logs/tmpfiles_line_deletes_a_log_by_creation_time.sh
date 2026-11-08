#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/failure.sh"
apt-get install --yes --no-install-recommends systemd >/dev/null
# The committed line with its age shortened to seconds; its type, path and kind of age stay as committed.
age_seconds=3
line="$(grep '^e ' host/pod-logs/pod-logs.conf)"
short_line="$(sed -E "s/b:[0-9a-z]+\$/b:${age_seconds}s/" <<<"$line")"
[ "$short_line" != "$line" ] || fail "the line '$line' sets no age by creation time"
root="$RUNNER_TEMP/pod-logs-root"
pods_dir="$root$(awk '{ print $2 }' <<<"$line")"
mkdir -p "$pods_dir/ns_old_1/app" "$root/etc/tmpfiles.d"
# The committed file's other lines stay as committed.
{ echo "$short_line"; grep '^r ' host/pod-logs/pod-logs.conf; } >"$root/etc/tmpfiles.d/pod-logs.conf"
echo first >"$pods_dir/ns_old_1/app/0.log"
[ "$(stat --format=%W "$pods_dir/ns_old_1/app/0.log")" -gt 0 ] || fail "$RUNNER_TEMP records no creation time"
sleep $((age_seconds + 2))
# Neither a write nor a read keeps the old file; the new pod's file is younger than the age.
echo appended >>"$pods_dir/ns_old_1/app/0.log"
cat "$pods_dir/ns_old_1/app/0.log" >/dev/null
mkdir -p "$pods_dir/ns_new_2/app"
echo first >"$pods_dir/ns_new_2/app/0.log"
touch "$pods_dir/ns_new_2/app/0.log.20261101-000000.gz" "$pods_dir/ns_new_2/app/0.log.20261101-000000.tmp"
# The flags are the service's own; only the root and the config path are the test tree's.
mapfile -t service_flags < <(sed -n 's/^ExecStart=[^ ]*//p' host/pod-logs/pod-logs-clean.service | tr ' ' '\n' |
  grep -- '^--')
[ "${#service_flags[@]}" -gt 0 ] || fail "pod-logs-clean.service's ExecStart holds no flag"
systemd-tmpfiles "${service_flags[@]}" --root="$root" "$root/etc/tmpfiles.d/pod-logs.conf"
[ ! -e "$pods_dir/ns_old_1" ] || fail "the clean kept $(find "$pods_dir/ns_old_1" | tr '\n' ' ')"
[ -f "$pods_dir/ns_new_2/app/0.log" ] || fail "the clean deleted the file younger than ${age_seconds}s"
[ "$(find "$pods_dir/ns_new_2" -type f | wc -l)" -eq 1 ] ||
  fail "the clean kept $(find "$pods_dir/ns_new_2" -type f | tr '\n' ' ')"
echo "the line at ${age_seconds}s deleted the older file after an append and a read, with its emptied" \
  "container and pod directories, and kept the newer file; the clean deleted the new pod's .gz and .tmp"
