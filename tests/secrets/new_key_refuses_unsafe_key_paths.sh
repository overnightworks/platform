#!/usr/bin/env bash
# Proves docs/commands.md NEWKEY-1, NEWKEY-2.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# A key file under the runner's temp directory, so no real key and no home directory is touched.
proof_dir="$RUNNER_TEMP/new-key"
key_dir="$proof_dir/age"
mkdir -p "$key_dir"
export SOPS_AGE_KEY_FILE="$key_dir/keys.txt"
check_refuses() {
  local status=0
  mise run secrets:new-key 2>"$proof_dir/stderr" || status=$?
  cat "$proof_dir/stderr"
  [ "$status" != 0 ] || fail "secrets:new-key succeeded with $1"
  grep --quiet --fixed-strings -- "$2" "$proof_dir/stderr" || fail "secrets:new-key did not name $2 with $1"
  [ ! -e "$SOPS_AGE_KEY_FILE" ] || fail "secrets:new-key wrote $SOPS_AGE_KEY_FILE with $1"
  echo "refused, naming $2, and wrote no key file: $1"
}
chmod 755 "$key_dir"
check_refuses "the key directory at mode 755" "mode 755"
chmod 700 "$key_dir"
touch "$SOPS_AGE_KEY_FILE.drill"
check_refuses "a drill file beside the key file" "$SOPS_AGE_KEY_FILE.drill"
rm "$SOPS_AGE_KEY_FILE.drill"
touch "$proof_dir/blocker"
SOPS_AGE_KEY_FILE="$proof_dir/blocker/age/keys.txt" \
  check_refuses "a regular file where the key directory would be" "secrets:new-key: $proof_dir/blocker is no directory"
# The key directory a symlink names is judged by its target, so a link to a 700 directory is accepted.
mkdir -m 700 "$proof_dir/target"
ln -s target "$proof_dir/link"
SOPS_AGE_KEY_FILE="$proof_dir/link/keys.txt" mise run secrets:new-key
[ "$(stat --format=%a "$proof_dir/target/keys.txt")" = 600 ] ||
  fail "secrets:new-key did not create the key at mode 600 in the symlink's target"
