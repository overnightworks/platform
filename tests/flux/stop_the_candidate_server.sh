#!/usr/bin/env bash
set -euo pipefail
# Ends the server by its own pid after printing what it served; a job that failed before it started has none.
pid_file="$RUNNER_TEMP/candidate-source.pid"
[ -f "$pid_file" ] || { echo "no candidate server was started"; exit 0; }
echo "requests the candidate server answered:"
sed 's/^/  /' "$RUNNER_TEMP/candidate-source.log"
kill "$(<"$pid_file")"
