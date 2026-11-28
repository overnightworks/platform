#!/usr/bin/env bash
# Proves bootstrap:docker-group: the user joins docker once, and the run that added it stops until a new login.
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
apt-get install --yes --no-install-recommends sudo >/dev/null
getent group docker >/dev/null || fail "no group docker; the packages part comes first"
user=dockeruser
repository="$(mktemp -d)"
cleanup() {
  userdel --remove "$user" 2>/dev/null || true
  rm -rf "/etc/sudoers.d/$user" "$repository"
}
trap cleanup EXIT
useradd --create-home "$user"
echo "$user ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/$user"
chmod 0440 "/etc/sudoers.d/$user"
# The user runs the repository's task with a copy of mise's binary and of the checkout, neither of which sits under
# root's home.
cp -a . "$repository/platform"
install -m 0755 "$(command -v mise)" "$repository/mise"
chown -R "$user" "$repository"
chmod 0755 "$repository"
run_task() {
  runuser --login "$user" --command "cd '$repository/platform' && MISE_TASK_RUN_AUTO_INSTALL=0 '$repository/mise' trust --quiet && MISE_TASK_RUN_AUTO_INSTALL=0 '$repository/mise' run bootstrap:docker-group" 2>&1
}

status=0
first="$(run_task)" || status=$?
echo "$first"
[ "$status" -eq 1 ] || fail "the first run ended $status, not 1"
grep -qF "log in again" <<<"$first" || fail "the first run does not ask for a new login"
getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qxF "$user" || fail "$user is not in docker after the first run"

status=0
second="$(run_task)" || status=$?
echo "$second"
[ "$status" -eq 0 ] || fail "the run in a new login ended $status, not 0"
grep -qF "added" <<<"$second" && fail "the run in a new login added the user again"
[ "$(getent group docker | cut -d: -f4 | tr ',' '\n' | grep -cxF "$user")" -eq 1 ] || fail "$user is listed more than once"
echo "the first run added $user to docker and asked for a new login; the run in a new login changed nothing"
