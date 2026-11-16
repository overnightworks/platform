#!/usr/bin/env bash
# The part whose step runs the Grafana cell, which queries a stream Loki holds, applies alloy, the only component that
# ships pod lines to Loki.
set -euo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
workflow_file="${WORKFLOW_FILE:-.github/workflows/ci.yml}"
reader=grafana_answers_both_data_sources_without_state_and_only_gatus_reaches_it.sh
part="$(READER="$reader" yq '.jobs.cluster.steps[] | select(.run == "*" + strenv(READER)) | .if' "$workflow_file" | sed -n "s/^matrix.part == '\(.*\)'$/\1/p")"
[ -n "$part" ] || {
  echo "::error::no step of $workflow_file runs $reader under one part"
  exit 1
}
"$here/part_closure.sh" "$part" | grep -qxF alloy || {
  echo "::error::the part $part runs $reader, which reads Loki, and its closure lacks alloy"
  exit 1
}
echo "the part $part, which reads Loki's lines, applies alloy"
