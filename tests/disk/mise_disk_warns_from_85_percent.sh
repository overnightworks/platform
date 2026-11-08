#!/usr/bin/env bash
set -eo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
export PATH="$HOME/.local/bin:$PATH"
scratch="$(mktemp -d)"
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
  env "${mise_dirs[@]}" "PATH=$scratch/bin:$PATH" "HOME=$scratch/home" "FAKE_DF_PERCENT=$1" mise run disk 2>&1
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
echo "mise run disk named its table and warned at 85 % and 100 % and not at 84 %"
