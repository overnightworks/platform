#!/usr/bin/env bash
# remove_link_branches.sh: runs remove_link.sh in the shell the init container runs it in, the busybox of PROBE_IMAGE in a
# throwaway container without network, against a fake ip for each branch of its logic, and fails unless each ends as it
# must. The fake is a shell function, since busybox prefers its own applet to a file on PATH. It keeps its links in a
# file, so a delete changes what the next read shows; a failed delete still removes the link, so only the delete's own
# status can fail it; its failing reads and deletes end 2, as ip does on the node. Needs docker and PROBE_IMAGE, which
# defaults to the one of the cluster job.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
program="$(cat "$(dirname "${BASH_SOURCE[0]}")/remove_link.sh")"
PROBE_IMAGE="${PROBE_IMAGE:-$(yq '.jobs.cluster.env.PROBE_IMAGE' "$(dirname "${BASH_SOURCE[0]}")/../../.github/workflows/ci.yml")}"
container="remove-link-probe-$$"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
fake_ip='ip() {
  case "$*" in
    "-o link")
      case "$FAKE_READ" in
        fails) return 2 ;;
        empty) return 0 ;;
        partial) head -n 1 /tmp/links; return 2 ;;
      esac
      cat /tmp/links ;;
    "link delete eth0")
      [ "$FAKE_DELETE" = keeps ] || sed -i "/ eth0/d" /tmp/links
      [ "$FAKE_DELETE" != fails ] || return 2 ;;
    *) echo "unexpected ip $*" >&2; return 2 ;;
  esac
}'
lo='1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN'
eth0='2: eth0@if7: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP'
other='3: dummy0: <BROADCAST,NOARP> mtu 1500 qdisc noop state DOWN'

# run_case <name> <expected: 0|nonzero, which is exactly 1> <links...>, with FAKE_READ (ok|fails|empty|partial) and
# FAKE_DELETE (ok|fails|keeps) as the caller set them; expected_message, when set, must appear on stderr.
run_case() {
  local name="$1" expected="$2" actual=0 output
  shift 2
  output="$(docker run --rm --network none --memory 128m --read-only --tmpfs /tmp --name "$container" \
    -e FAKE_READ="${FAKE_READ:-ok}" -e FAKE_DELETE="${FAKE_DELETE:-ok}" -e FAKE_LINKS="$(printf '%s\n' "$@")" \
    -e FAKE_IP="$fake_ip" -e PROGRAM="$program" "$PROBE_IMAGE" sh -c '
      printf "%s\n" "$FAKE_LINKS" >/tmp/links
      status=0
      sh -c "$FAKE_IP
$PROGRAM" || status=$?
      echo "links-left=$(wc -l </tmp/links)"
      exit "$status"' 2>&1)" || actual=$?
  if { [ "$expected" = 0 ] && [ "$actual" -ne 0 ]; } || { [ "$expected" = nonzero ] && [ "$actual" -ne 1 ]; }; then
    fail "remove_link.sh in case '$name' ended $actual, expected $expected: $output"
  fi
  if [ "$expected" = 0 ] && [ "$(tail -n 1 <<<"$output")" != links-left=1 ]; then
    fail "remove_link.sh in case '$name' ended 0 with links left: $output"
  fi
  if [ -n "${expected_message:-}" ] && ! grep -qF "$expected_message" <<<"$output"; then
    fail "remove_link.sh in case '$name' did not print '$expected_message': $output"
  fi
  echo "case '$name': ended $actual as expected"
}
run_case "lo alone" 0 "$lo"
run_case "eth0 removed" 0 "$lo" "$eth0"
run_case "another link" nonzero "$lo" "$eth0" "$other"
run_case "another link without eth0" nonzero "$lo" "$other"
run_case "no lo" nonzero "$eth0"
FAKE_READ=fails expected_message="remove-link: the read of the links failed" run_case "failed read" nonzero "$lo"
FAKE_READ=partial expected_message="remove-link: the read of the links failed" run_case "read that prints lo, then fails" nonzero "$lo" "$eth0"
FAKE_READ=empty run_case "empty read" nonzero "$lo"
FAKE_DELETE=fails expected_message="remove-link: the delete of eth0 failed" run_case "failed delete" nonzero "$lo" "$eth0"
FAKE_DELETE=keeps run_case "eth0 still there after the delete" nonzero "$lo" "$eth0"
