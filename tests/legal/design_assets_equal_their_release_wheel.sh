#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

# design's release wheel is the source of the static files under infrastructure/design/design-<version>;
# a new release moves the URL and the digest here with the files.
wheel_url="https://github.com/overnightworks/design/releases/download/v0.18.0/overnightworks_design-0.18.0-py3-none-any.whl"
wheel_digest="f5e24751382b987e948b355e4a7494c579b2751b620e46c02bdafe5c44544261"
wheel_file="${wheel_url##*/}"
design_version="$(sed -n 's/^overnightworks_design-\([^-]*\)-.*\.whl$/\1/p' <<<"$wheel_file")"
[ -n "$design_version" ] || fail "the wheel file name '$wheel_file' holds no version"

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

curl --fail --silent --show-error --location --output "$workspace/$wheel_file" "$wheel_url" ||
  fail "fetching the design wheel $wheel_url failed"
[ "$(sha256sum <"$workspace/$wheel_file" | cut -d' ' -f1)" = "$wheel_digest" ] ||
  fail "the design wheel $wheel_url does not have the sha256 $wheel_digest"
mkdir "$workspace/wheel"
python3 -I -m zipfile -e "$workspace/$wheel_file" "$workspace/wheel" ||
  fail "unpacking the design wheel $wheel_file failed"
diff -r "$workspace/wheel/design/static" "infrastructure/design/design-$design_version" ||
  fail "infrastructure/design/design-$design_version differs from design/static in $wheel_file"
echo "infrastructure/design/design-$design_version equals design/static in the wheel $wheel_file"

[ "$(cd infrastructure/design && find . -mindepth 1 -maxdepth 1 | sort)" = "$(printf './design-%s\n./kustomization.yaml' "$design_version")" ] ||
  fail "infrastructure/design holds something besides kustomization.yaml and design-$design_version"
echo "infrastructure/design holds nothing else"

[ "$(cd infrastructure/legal/assets && find . -mindepth 1 -maxdepth 1 | sort)" = "./legal-2.css" ] ||
  fail "infrastructure/legal/assets holds something besides legal-2.css"
echo "infrastructure/legal/assets holds nothing else"
