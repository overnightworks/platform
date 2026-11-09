#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_url="https://github.com/overnightworks/hal"
# The commit of hal whose legal/sections, stylesheet, headers and appkit pin stand byte for byte under
# infrastructure/legal; move it when hal changes any of them before it leaves.
hal_commit="ed6de88ec768e62439c775b8d96ad4aad437fab7"
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

[ -f "$workspace/hal/legal/assets/legal-2.css" ] || fail "hal at $hal_commit holds no legal/assets/legal-2.css"
cmp "$workspace/hal/legal/assets/legal-2.css" infrastructure/legal/assets/legal-2.css ||
  fail "infrastructure/legal/assets/legal-2.css differs from hal's legal/assets/legal-2.css at $hal_commit"
echo "infrastructure/legal/assets/legal-2.css equals hal's legal/assets/legal-2.css at $hal_commit"

header_lines() { grep -E '^[[:space:]]*add_header ' "$1" | sed -E 's/^[[:space:]]+//'; }
[ -n "$(header_lines infrastructure/legal/default.conf)" ] || fail "infrastructure/legal/default.conf sets no header"
diff <(header_lines "$workspace/hal/legal/nginx/default.conf") <(header_lines infrastructure/legal/default.conf) ||
  fail "the add_header lines of infrastructure/legal/default.conf differ from hal's legal/nginx/default.conf at $hal_commit"
echo "the add_header lines of infrastructure/legal/default.conf equal hal's at $hal_commit"

# appkit's release wheel is the source of the static files hal's apply step writes; hal pins its URL and digest.
appkit_pin="$(sed -n 's/^[[:space:]]*"overnightworks-appkit @ \(.*\)",\{0,1\}$/\1/p' "$workspace/hal/pyproject.toml")"
[ -n "$appkit_pin" ] || fail "hal's pyproject.toml at $hal_commit pins no overnightworks-appkit wheel"
wheel_url="${appkit_pin%%#sha256=*}"
wheel_digest="${appkit_pin##*#sha256=}"
[ "$wheel_url" != "$appkit_pin" ] && [ -n "$wheel_digest" ] || fail "hal's appkit pin '$appkit_pin' carries no #sha256="
wheel_file="${wheel_url##*/}"
appkit_version="$(sed -n 's/^overnightworks_appkit-\([^-]*\)-.*\.whl$/\1/p' <<<"$wheel_file")"
[ -n "$appkit_version" ] || fail "the wheel file name '$wheel_file' holds no version"

curl --fail --silent --show-error --location --output "$workspace/$wheel_file" "$wheel_url" ||
  fail "fetching the appkit wheel $wheel_url failed"
[ "$(sha256sum <"$workspace/$wheel_file" | cut -d' ' -f1)" = "$wheel_digest" ] ||
  fail "the appkit wheel $wheel_url does not have the sha256 hal pins"
mkdir "$workspace/wheel"
python3 -I -m zipfile -e "$workspace/$wheel_file" "$workspace/wheel" ||
  fail "unpacking the appkit wheel $wheel_file failed"
diff -r "$workspace/wheel/appkit/static" "infrastructure/legal/assets/appkit-$appkit_version" ||
  fail "infrastructure/legal/assets/appkit-$appkit_version differs from appkit/static in $wheel_file"
echo "infrastructure/legal/assets/appkit-$appkit_version equals appkit/static in the wheel hal pins"

[ "$(cd infrastructure/legal/assets && find . -mindepth 1 -maxdepth 1 | sort)" = "$(printf './appkit-%s\n./legal-2.css' "$appkit_version")" ] ||
  fail "infrastructure/legal/assets holds something besides legal-2.css and appkit-$appkit_version"
echo "infrastructure/legal/assets holds nothing else"
