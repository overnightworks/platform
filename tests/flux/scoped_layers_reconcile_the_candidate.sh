#!/usr/bin/env bash
# Run in every part: the root and every layer of the part's closure (tests/flux/part_closure.sh) are Ready and applied
# the candidate commit. A layer outside the closure was deleted from the root's patches and never exists.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
step_started_at="$(date +%s)"
# What the runner does during the wait, in every part: a stall of the node shows as run queue, I/O wait, steal or swap.
runner_samples="$RUNNER_TEMP/runner-vmstat.log"
LC_ALL=C vmstat -n -t -w 10 >"$runner_samples" &
sampler_pid=$!
ready_times_printed=false
# Prints once, on the first of: the end of the waits or any exit, so a timed-out early wait still reports its stall.
print_ready_times_once() {
  "$ready_times_printed" && return 0
  ready_times_printed=true
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  "$(dirname "${BASH_SOURCE[0]}")/print_ready_times.sh" "$step_started_at" "$runner_samples"
}
trap print_ready_times_once EXIT
kubectl -n flux-system wait gitrepository/flux-system --for=condition=Ready --timeout=3m
kubectl -n flux-system wait kustomization/flux-system --for=condition=Ready --timeout=5m
wait_status=0
# songmaker's scoring worker pulls a 4 GB image while the other legs pull from GHCR at the same time; its layer took
# up to 333 s on main, so 6 minutes left too little margin.
kubectl wait kustomizations.kustomize.toolkit.fluxcd.io --all --all-namespaces --for=condition=Ready --timeout=10m ||
  wait_status=$?
print_ready_times_once
[ "$wait_status" -eq 0 ] || exit "$wait_status"
kubectl -n flux-system get gitrepository flux-system -o yaml

source_revision="$(kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}')"
applied_revision="$(kubectl -n flux-system get kustomization flux-system -o jsonpath='{.status.lastAppliedRevision}')"
[ "$source_revision" = "${CANDIDATE_BRANCH}@sha1:${CANDIDATE_REVISION}" ] ||
  fail "the artifact revision '$source_revision' is not ${CANDIDATE_BRANCH}@sha1:${CANDIDATE_REVISION}"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "revision '$applied_revision' is not the candidate $CANDIDATE_REVISION"
echo "candidate revision:                   $CANDIDATE_REVISION"
echo "GitRepository artifact revision:      $source_revision"
echo "Kustomization lastAppliedRevision:    $applied_revision"

