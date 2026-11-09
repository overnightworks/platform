#!/usr/bin/env bash
# remove_link_branches.sh: runs remove_link.sh against a fake ip for each branch of its logic and fails unless each ends
# as it must. The fake keeps its links in a file, so a delete changes what the next read shows; a failed delete still
# removes the link, so only the delete's own status can fail it; it ends 2, as ip does on the node.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
program="$(dirname "${BASH_SOURCE[0]}")/remove_link.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cat >"$scratch/ip" <<'FAKE'
#!/bin/sh
case "$*" in
  "-o link") [ -e "$FAKE_READ_FAILS" ] && exit 1; cat "$FAKE_LINKS" ;;
  "link delete eth0")
    [ -e "$FAKE_DELETE_KEEPS" ] || sed -i '/ eth0/d' "$FAKE_LINKS"
    if [ -e "$FAKE_DELETE_FAILS" ]; then exit 2; fi ;;
  *) echo "unexpected ip $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$scratch/ip"
lo='1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN'
eth0='2: eth0@if7: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP'
other='3: dummy0: <BROADCAST,NOARP> mtu 1500 qdisc noop state DOWN'

# run_case <name> <expected status: 0|nonzero, which is exactly 1> <links...>, with the FAKE_* markers the caller set.
run_case() {
  local name="$1" expected="$2" actual=0
  shift 2
  printf '%s\n' "$@" >"$scratch/links"
  FAKE_LINKS="$scratch/links" PATH="$scratch:$PATH" sh "$program" >/dev/null 2>"$scratch/stderr" || actual=$?
  if { [ "$expected" = 0 ] && [ "$actual" -ne 0 ]; } || { [ "$expected" = nonzero ] && [ "$actual" -ne 1 ]; }; then
    fail "remove_link.sh in case '$name' ended $actual, expected $expected"
  fi
  if [ "$expected" = 0 ] && [ "$(wc -l <"$scratch/links")" -ne 1 ]; then
    fail "remove_link.sh in case '$name' ended 0 with links left: $(cat "$scratch/links")"
  fi
  if [ -n "${expected_message:-}" ] && ! grep -qF "$expected_message" "$scratch/stderr"; then
    fail "remove_link.sh in case '$name' did not print '$expected_message': $(cat "$scratch/stderr")"
  fi
  echo "case '$name': ended $actual as expected"
}
export FAKE_READ_FAILS="$scratch/none" FAKE_DELETE_FAILS="$scratch/none" FAKE_DELETE_KEEPS="$scratch/none"
run_case "lo alone" 0 "$lo"
run_case "eth0 removed" 0 "$lo" "$eth0"
run_case "another link" nonzero "$lo" "$eth0" "$other"
run_case "another link without eth0" nonzero "$lo" "$other"
run_case "no lo" nonzero "$eth0"
touch "$scratch/yes"
FAKE_READ_FAILS="$scratch/yes" run_case "failed read" nonzero "$lo"
FAKE_DELETE_FAILS="$scratch/yes" expected_message="remove-link: the delete of eth0 failed" run_case "failed delete" nonzero "$lo" "$eth0"
FAKE_DELETE_KEEPS="$scratch/yes" run_case "eth0 still there after the delete" nonzero "$lo" "$eth0"
