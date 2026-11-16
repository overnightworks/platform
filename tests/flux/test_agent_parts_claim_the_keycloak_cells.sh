#!/usr/bin/env bash
# Every part that runs the P2 cells for the test agents (the keys of TEST_AGENTS_BY_PART in the workflow) claims the
# directory of those cells in PARTS_FILE, so a changed cell selects it.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PARTS_FILE="${PARTS_FILE:-$(dirname "${BASH_SOURCE[0]}")/parts.yaml}"
workflow="${WORKFLOW_FILE:-.github/workflows/ci.yml}"
cells_glob='tests/keycloak/*'

mapfile -t agent_parts < <(yq '.jobs.cluster.env.TEST_AGENTS_BY_PART | fromjson | keys | .[]' "$workflow")
[ "${#agent_parts[@]}" -gt 0 ] || fail "$workflow names no part with test agents"
for part in "${agent_parts[@]}"; do
  PART="$part" yq -e '.[strenv(PART)].paths | contains(["'"$cells_glob"'"])' "$PARTS_FILE" >/dev/null ||
    fail "the part $part runs the test agents' cells but its paths in $PARTS_FILE omit $cells_glob"
done
echo "${#agent_parts[@]} parts with test agents claim $cells_glob"
