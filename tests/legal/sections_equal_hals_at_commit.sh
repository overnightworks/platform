#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_url="https://github.com/overnightworks/hal"
# The commit of hal whose legal/sections stand byte for byte under infrastructure/legal/sections; move it when
# hal changes legal/sections before it leaves.
hal_commit="a5c2342722266240a363a2c4e5016ba889ce3c1a"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

git -C "$workspace" init --quiet hal
git -C "$workspace/hal" fetch --quiet --depth 1 "$repository_url" "$hal_commit" &&
  git -C "$workspace/hal" -c advice.detachedHead=false checkout --quiet FETCH_HEAD ||
  fail "fetching $repository_url at the commit $hal_commit failed, so hal's legal sections could not be read"

[ -d "$workspace/hal/legal/sections" ] || fail "hal at $hal_commit holds no legal/sections"
diff -r "$workspace/hal/legal/sections" infrastructure/legal/sections ||
  fail "infrastructure/legal/sections differs from hal's legal/sections at $hal_commit"
echo "infrastructure/legal/sections equals hal's legal/sections at $hal_commit"
