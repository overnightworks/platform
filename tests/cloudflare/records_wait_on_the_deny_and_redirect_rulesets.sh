#!/usr/bin/env bash
# The dependency graph of the Cloudflare root holds an edge from every DNS record to the deny ruleset and to the apex
# redirect ruleset, so that no record is created before the rules that keep protected paths off the public edge. A mocked
# test cannot see an explicit dependency; the graph can.
# Usage: tests/cloudflare/records_wait_on_the_deny_and_redirect_rulesets.sh
# Proves docs/cloudflare-zone.md: the records wait on the rulesets.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../src/opentofu/cloudflare" && pwd)"
TF_DATA_DIR="$(mktemp -d)"
export TF_DATA_DIR
trap 'rm -rf "${TF_DATA_DIR}"' EXIT

tofu -chdir="${root}" init -input=false -lockfile=readonly >/dev/null || fail "init of the Cloudflare root failed"
graph="$(tofu -chdir="${root}" graph)" || fail "the graph of the Cloudflare root could not be drawn"

for ruleset in deny_public apex_redirect; do
  edge="\"[root] cloudflare_dns_record.host (expand)\" -> \"[root] cloudflare_ruleset.${ruleset} (expand)\""
  grep -qF "${edge}" <<<"${graph}" || fail "the records do not wait on cloudflare_ruleset.${ruleset}"
done
