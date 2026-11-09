#!/usr/bin/env bash
set -euo pipefail
# Serves the checked-out commit to Flux over read-only smart HTTP: source-controller fetches only refs/heads/*, so
# the merge commit of a pull request, which GitHub holds under refs/pull/<n>/merge, reaches it only from here.
# Expects CANDIDATE_REVISION, CANDIDATE_BRANCH, CANDIDATE_SOURCE_PORT, RUNNER_TEMP and GITHUB_ENV.
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
head_revision="$(git rev-parse HEAD)"
[ "$head_revision" = "$CANDIDATE_REVISION" ] || fail "the checkout is at $head_revision, not the candidate $CANDIDATE_REVISION"
echo "the checkout's HEAD equals the candidate $CANDIDATE_REVISION"

served="$RUNNER_TEMP/candidate-source"
mkdir -p "$served/cgi-bin"
git init --quiet --bare "$served/repository.git"
git -C "$served/repository.git" config http.receivepack false
git push --quiet "$served/repository.git" "${CANDIDATE_REVISION}:refs/heads/${CANDIDATE_BRANCH}"
git -C "$served/repository.git" symbolic-ref HEAD "refs/heads/${CANDIDATE_BRANCH}"
# CGIHTTPRequestHandler runs the script at the path it is asked for, so this one hands git http-backend its root.
cat > "$served/cgi-bin/git-http-backend" <<SCRIPT
#!/bin/sh
export GIT_PROJECT_ROOT="$served" GIT_HTTP_EXPORT_ALL=1
exec git http-backend
SCRIPT
chmod +x "$served/cgi-bin/git-http-backend"

# A new session, so that the step's end leaves the server running for the whole job.
setsid python3 -m http.server --cgi --bind 0.0.0.0 --directory "$served" "$CANDIDATE_SOURCE_PORT" \
  > "$RUNNER_TEMP/candidate-source.log" 2>&1 < /dev/null &
echo "$!" > "$RUNNER_TEMP/candidate-source.pid"

url="http://localhost:${CANDIDATE_SOURCE_PORT}/cgi-bin/git-http-backend/repository.git"
for _ in $(seq 30); do
  served_revision="$(git ls-remote "$url" "refs/heads/${CANDIDATE_BRANCH}" 2>/dev/null | cut -f1)" || true
  [ -z "$served_revision" ] || break
  sleep 1
done
[ "${served_revision:-}" = "$CANDIDATE_REVISION" ] ||
  fail "the served branch ${CANDIDATE_BRANCH} is at '${served_revision:-nothing}', not the candidate $CANDIDATE_REVISION"
# The cluster reaches the runner by the name k3d adds to its DNS.
echo "CANDIDATE_SOURCE_URL=http://host.k3d.internal:${CANDIDATE_SOURCE_PORT}/cgi-bin/git-http-backend/repository.git" >> "$GITHUB_ENV"
echo "the server (pid $(<"$RUNNER_TEMP/candidate-source.pid")) serves ${CANDIDATE_BRANCH} at the candidate"
