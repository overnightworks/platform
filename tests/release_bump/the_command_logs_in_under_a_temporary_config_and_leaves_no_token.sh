#!/usr/bin/env bash
# Drive `mise run release:bump` against the fixture world: it logs in to the registry once, under a docker
# configuration directory of its own that is gone when the run ends, hands the token only through stdin, leaves docker's
# configuration of the caller empty and opens the pull request; run again it pushes nothing.
# Usage: mise exec -- tests/release_bump/the_command_logs_in_under_a_temporary_config_and_leaves_no_token.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/world.sh"

app_release 2026.11.24.1
registry_add ghcr.io/overnightworks/hopin 2026.11.24.1
cd "${checkout}"

log="$(mise run release:bump hopin 2>&1)" || fail "release:bump failed: ${log}"
grep -q 'opened\|pull/1' <<<"${log}" || fail "release:bump did not open the pull request: ${log}"
[ "$(calls "${work}/docker-calls" '^docker login')" -eq 1 ] || fail "release:bump did not log in once"
login_config="$(sed -n 's/^docker login .*\[config \(.*\)\]$/\1/p' "${work}/docker-calls")"
[ "${login_config}" != "${DOCKER_CONFIG}" ] && [ ! -e "${login_config}" ] || fail "the login's configuration ${login_config} outlived the run or is the caller's"
[ -z "$(ls -A "${DOCKER_CONFIG}")" ] || fail "release:bump wrote into the caller's docker configuration"
! grep -rq fixture-token "${work}/docker-calls" "${work}/gh-calls" || fail "the token reached an argument"
echo "release:bump logs in under a temporary configuration and leaves no token"

: >"${work}/gh-calls"
tip="$(git ls-remote origin refs/heads/release/hopin | cut -f1)"
log="$(mise run release:bump hopin 2>&1)" || fail "the repeated release:bump failed: ${log}"
[ "$(git ls-remote origin refs/heads/release/hopin | cut -f1)" = "${tip}" ] || fail "the repeated run pushed"
[ "$(calls "${work}/gh-calls" 'pr create')" -eq 0 ] || fail "the repeated run opened another pull request"
echo "release:bump again pushes nothing"

status=0
mise run release:bump 2>/dev/null || status=$?
[ "${status}" -ne 0 ] || fail "release:bump without an app did not fail"
echo "release:bump without an app is refused"
