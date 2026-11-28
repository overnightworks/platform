#!/usr/bin/env bash
# Proves that the bootstrap's packages part installs what mise.toml declares for Docker, from nothing and again.
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
mapfile -t packages < <(mise exec -- yq -p toml -oy '.bootstrap.packages | keys | .[] | select(test("^apt:")) | sub("^apt:"; "")' mise.toml)
[ "${#packages[@]}" -gt 0 ] || fail "mise.toml declares no apt package"

scripts/bootstrap_pc.sh --only packages --yes
for package in "${packages[@]}"; do
  [ "$(dpkg-query --show --showformat '${db:Status-Abbrev}' "$package")" = "ii " ] ||
    fail "the packages part left $package not installed"
done
docker --version
docker compose version
docker buildx version
getent group docker || fail "no group docker after the packages part"

scripts/bootstrap_pc.sh --only packages --yes
mise bootstrap packages status --missing || fail "a second run left a package differing from mise.toml"
echo "the packages part installed ${packages[*]}, whose clients run, with the group docker, and a second run left no difference"
