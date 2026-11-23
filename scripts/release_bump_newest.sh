#!/usr/bin/env bash
# The one order of an app's releases: read release versions, one per line, from stdin and print the newest, or nothing
# when there are none.
# Usage: printf '%s\n' <version>... | scripts/release_bump_newest.sh
set -euo pipefail

[ "$#" -eq 0 ] || { echo "usage: release_bump_newest.sh (versions on stdin)" >&2; exit 2; }
sort -V | tail -1
