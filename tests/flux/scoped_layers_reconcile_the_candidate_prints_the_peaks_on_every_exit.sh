#!/usr/bin/env bash
# Drive scoped_layers_reconcile_the_candidate.sh against fake kubectl and vmstat, first on PATH: whichever of the three
# waits fails, the step prints the peaks of the runner's wait, exits with that wait's status and leaves no sampler; when
# all pass it prints the peaks once and exits 0.
# Usage: mise exec -- tests/flux/scoped_layers_reconcile_the_candidate_prints_the_peaks_on_every_exit.sh
set -euo pipefail

# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
reconcile="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scoped_layers_reconcile_the_candidate.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"

cat >"$scratch/bin/vmstat" <<'FAKE'
#!/usr/bin/env bash
echo "$$" >"$FAKE_DIR/sampler-pid"
echo "procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----"
echo "r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st"
echo "7  1      0 900000  10000 500000    0    0     0     0  100  200 30 10 55  4  1"
exec sleep 600
FAKE
cat >"$scratch/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *" wait "*|"wait "*)
    calls="$(($(cat "$FAKE_DIR/waits" 2>/dev/null || echo 0) + 1))"
    echo "$calls" >"$FAKE_DIR/waits"
    [ "$calls" -ne "$FAKE_FAILING_WAIT" ] || exit 7 ;;
  *"-o yaml") ;;
  *lastAppliedRevision*) echo "flux-system@sha1:$CANDIDATE_REVISION" ;;
  *artifact.revision*) echo "$CANDIDATE_BRANCH@sha1:$CANDIDATE_REVISION" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/vmstat" "$scratch/bin/kubectl"

# case id, the wait that fails (0: none), the status the step ends with
for case_row in "first-wait-fails 1 7" "last-wait-fails 3 7" "all-waits-pass 0 0"; do
  read -r case_id failing_wait expected_status <<<"$case_row"
  export FAKE_DIR="$scratch/$case_id" FAKE_FAILING_WAIT="$failing_wait"
  mkdir "$FAKE_DIR"
  status=0
  PATH="$scratch/bin:$PATH" RUNNER_TEMP="$FAKE_DIR" CANDIDATE_BRANCH=candidate CANDIDATE_REVISION=abc123 \
    "$reconcile" >"$FAKE_DIR/out" 2>&1 || status=$?
  [ "$status" -eq "$expected_status" ] || fail "$case_id: the step ended with $status, not $expected_status"
  [ "$(grep -c '^peaks of the wait: r 7, b 1' "$FAKE_DIR/out")" -eq 1 ] ||
    fail "$case_id: the output does not hold the peaks line exactly once"
  ! kill -0 "$(cat "$FAKE_DIR/sampler-pid")" 2>/dev/null || fail "$case_id: the sampler still runs"
done
echo "ok: the peaks print once on every exit of the step, the status stays the wait's and no sampler is left"
