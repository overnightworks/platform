#!/usr/bin/env bash
# parts_for_paths.sh selects core alone for a docs-only diff, the parts whose closure holds a changed layer, the parts a
# glob names, every part but the nightly-only ones for an unknown path, a zero base or a failing diff, and every part for
# --all; a nightly-only part is chosen by --all alone.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=fixture_layers.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixture_layers.sh"
selector="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/parts_for_paths.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
make_fixture "$scratch/tree"
cd "$scratch/tree"
git -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.invalid commit --quiet --message base

# expect_parts <name> <expected JSON> <selector arguments>
expect_parts() {
  local name="$1" expected="$2" actual
  shift 2
  actual="$("$selector" "$@" 2>/dev/null)" || fail "$name: the selector failed"
  [ "$actual" = "$expected" ] || fail "$name: the selector chose $actual, not $expected"
  echo "$name: $expected"
}
# expect_change <name> <expected JSON> <file>...: the files change in a commit on top of the base, and the selector reads that commit.
expect_change() {
  local name="$1" expected="$2" file
  shift 2
  for file in "$@"; do
    mkdir -p "$(dirname "$file")"
    echo "$name" >>"$file"
  done
  git add .
  git -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.invalid commit --quiet --message "$name"
  expect_parts "$name" "$expected" HEAD^ HEAD
}

every_part_but_the_nightly_only='["core","chain","single"]'
expect_parts "--all" '["core","chain","single","nightly"]' --all
expect_change "a docs-only diff" '["core"]' docs/guide.txt README.md
expect_change "a layer with a dependent" '["core","chain"]' base/file
expect_change "a layer without one" '["core","single"]' alone/file
expect_change "a glob of a part" '["core","chain"]' chain-cells/cell.sh
expect_change "a glob of the nightly-only part" '["core"]' nightly-cells/cell.sh
expect_change "a layer and a glob" '["core","chain","single"]' middle/file alone/file
expect_change "an unknown path" "$every_part_but_the_nightly_only" unclaimed.txt
expect_change "an unknown path beside a docs one" "$every_part_but_the_nightly_only" README.md unclaimed.txt
expect_change "the workflow itself" "$every_part_but_the_nightly_only" .github/workflows/ci.yml
expect_change "the parts file itself" "$every_part_but_the_nightly_only" tests/flux/parts.yaml
expect_parts "a zero base" "$every_part_but_the_nightly_only" 0000000000000000000000000000000000000000 HEAD
expect_parts "a base the repository lacks" "$every_part_but_the_nightly_only" 1111111111111111111111111111111111111111 HEAD
