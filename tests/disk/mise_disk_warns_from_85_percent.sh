#!/usr/bin/env bash
# Proves docs/commands.md DISK-1, DISK-2.
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/home/.cache/uv"
head -c 1000000 /dev/zero >"$scratch/home/.cache/uv/blob"
# df answers for the home directory with the percentage the case sets, as `df -B1 --output=used,size,pcent` prints it.
cat >"$scratch/bin/df" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' '      Used       1B-blocks Use%' "5000000000 10000000000 ${FAKE_DF_PERCENT}%"
FAKE
chmod +x "$scratch/bin/df"
# mise keeps its tools where they are; only the task's $HOME is the scratch tree.
mise_dirs=("MISE_DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/mise" "MISE_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/mise"
  "MISE_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/mise" "MISE_CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/mise")
run_disk() {
  local fake_bin="$scratch/bin"
  [ -z "${2:-}" ] || fake_bin="$scratch/$2:$fake_bin"
  env "${mise_dirs[@]}" "PATH=$fake_bin:$PATH" "HOME=$scratch/home" "FAKE_DF_PERCENT=$1" DISK_DOCKER_TIMEOUT=2 \
    timeout --kill-after=5 60 mise run disk 2>&1
}
for percent in 84 85 100; do
  output="$(run_disk "$percent")" || fail "mise run disk failed at $percent %: $output"
  grep -qF 'cache/uv' <<<"$output" || fail "the table at $percent % names no cache/uv: $output"
  if [ "$percent" -ge 85 ]; then
    grep -q '^WARNING' <<<"$output" || fail "no warning at $percent %: $output"
  else
    ! grep -q '^WARNING' <<<"$output" || fail "a warning at $percent %: $output"
  fi
done

# A daemon that never answers costs one line, and the warning has been printed by then.
mkdir -p "$scratch/silent-docker"
printf '#!/usr/bin/env bash\nexec sleep 600\n' >"$scratch/silent-docker/docker"
chmod +x "$scratch/silent-docker/docker"
output="$(run_disk 90 silent-docker)" || fail "mise run disk failed or hung with a silent Docker daemon: $output"
grep -q '^WARNING' <<<"$output" || fail "no warning with a silent Docker daemon: $output"
grep -qF 'Docker did not answer within 2 s' <<<"$output" || fail "no line on the silent Docker daemon: $output"
grep -qF 'cache/uv' <<<"$output" || fail "no table with a silent Docker daemon: $output"

# A directory du cannot read marks its row incomplete and leaves the remainders unknown instead of a wrong number.
mkdir -p "$scratch/partial-du"
cat >"$scratch/partial-du/du" <<'FAKE'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in -*) continue ;; esac
  printf '1000\t%s\n' "$argument"
done
echo "du: cannot read directory '$HOME/.cache/uv/locked': Permission denied" >&2
exit 1
FAKE
chmod +x "$scratch/partial-du/du"
output="$(run_disk 50 partial-du)" || fail "mise run disk failed on a partial du: $output"
grep -F 'cache/uv' <<<"$output" | grep -qF 'incomplete' || fail "the unreadable directory's row is not marked incomplete: $output"
grep -F 'the rest of ~' <<<"$output" | grep -qE '^ *\? ' || fail "the rest of ~ is no unknown line: $output"
grep -F 'outside ~' <<<"$output" | grep -qE '^ *\? ' || fail "outside ~ is no unknown line: $output"
echo "mise run disk named its table, warned at 85 % and 100 % and not at 84 %, warned and named a silent Docker" \
  "daemon in one line, and marked an unreadable directory incomplete with unknown remainders"
