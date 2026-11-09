#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

# appkit's release wheel is the source of the static files under infrastructure/legal/assets/appkit-<version>;
# a new release moves the URL and the digest here with the files.
wheel_url="https://github.com/overnightworks/design/releases/download/v0.15.0/overnightworks_appkit-0.15.0-py3-none-any.whl"
wheel_digest="710bed31c5b3fa693e401dfd77b6ac6305b91a1c16b2cc52836e05cd3b516ec2"
wheel_file="${wheel_url##*/}"
appkit_version="$(sed -n 's/^overnightworks_appkit-\([^-]*\)-.*\.whl$/\1/p' <<<"$wheel_file")"
[ -n "$appkit_version" ] || fail "the wheel file name '$wheel_file' holds no version"

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

curl --fail --silent --show-error --location --output "$workspace/$wheel_file" "$wheel_url" ||
  fail "fetching the appkit wheel $wheel_url failed"
[ "$(sha256sum <"$workspace/$wheel_file" | cut -d' ' -f1)" = "$wheel_digest" ] ||
  fail "the appkit wheel $wheel_url does not have the sha256 $wheel_digest"
mkdir "$workspace/wheel"
python3 -I -m zipfile -e "$workspace/$wheel_file" "$workspace/wheel" ||
  fail "unpacking the appkit wheel $wheel_file failed"
diff -r "$workspace/wheel/appkit/static" "infrastructure/legal/assets/appkit-$appkit_version" ||
  fail "infrastructure/legal/assets/appkit-$appkit_version differs from appkit/static in $wheel_file"
echo "infrastructure/legal/assets/appkit-$appkit_version equals appkit/static in the wheel $wheel_file"

[ "$(cd infrastructure/legal/assets && find . -mindepth 1 -maxdepth 1 | sort)" = "$(printf './appkit-%s\n./legal-2.css' "$appkit_version")" ] ||
  fail "infrastructure/legal/assets holds something besides legal-2.css and appkit-$appkit_version"
echo "infrastructure/legal/assets holds nothing else"
