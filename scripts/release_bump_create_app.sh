#!/usr/bin/env bash
# Create the release App through GitHub's manifest flow and store only its private key as the environment secret of
# release-bump on platform, so the key passes no disk, terminal or agent: the listener serves one page on 127.0.0.1, the
# operator clicks "Create GitHub App" there, and the listener hands the answer's key to `gh secret set`'s stdin.
# Usage: scripts/release_bump_create_app.sh <name>   (the App's name, unique on GitHub: lowercase letters, digits, hyphens)
# Exit: 0 the key is stored; non-zero it is not. A failure after the page was served may have left the App on GitHub, so
# it prints where to delete it (docs/runbooks/create-or-replace-the-release-app.md).
set -euo pipefail

repository=overnightworks/platform
environment=release-bump
secret=RELEASE_BUMP_APP_PRIVATE_KEY
# Below the hour for which GitHub keeps the code the redirect carries.
deadline_seconds=1800
scripts_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
listener_script="${scripts_directory}/release_bump_create_app_listener.py"
# shellcheck source=gh_login_environment.sh
source "${scripts_directory}/gh_login_environment.sh"

fail() {
  echo "release_bump_create_app: $1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "usage: scripts/release_bump_create_app.sh <name>"
name="$1"
[[ "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#name}" -le 34 ] ||
  fail "the name is no slug: lowercase letters, digits and hyphens, at most 34 characters"
settings_page="https://github.com/organizations/${repository%/*}/settings/apps/${name}"
installation_page="https://github.com/apps/${name}/installations/new"

# The reads, the listener and with it the store run as the keyring's login alone, so a GH_TOKEN of the caller's shell
# cannot pass the checks below and leave the store to another login.
gh_login=("${clean_environment[@]}")
append_gh_login_variables gh_login
environment_path="repos/${repository}/environments/${environment}"
environment_json="$("${gh_login[@]}" gh api "${environment_path}")" || fail "the environment ${environment} of ${repository} is unreadable"
[ "$(yq --input-format json '.deployment_branch_policy.custom_branch_policies == true and .deployment_branch_policy.protected_branches == false' <<<"${environment_json}")" = true ] ||
  fail "the environment ${environment} is not in custom branch policy mode"
policies_json="$("${gh_login[@]}" gh api "${environment_path}/deployment-branch-policies")" || fail "the branch policies of ${environment} are unreadable"
[ "$(yq --input-format json '(.branch_policies | length) == 1 and .branch_policies[0].type == "branch" and .branch_policies[0].name == "main"' <<<"${policies_json}")" = true ] ||
  fail "the environment ${environment} must admit exactly one branch policy, the branch main"
"${gh_login[@]}" gh api "${environment_path}/secrets/public-key" >/dev/null ||
  fail "the gh login cannot store a secret on ${environment}; run gh auth login with a login that can"

stored=false
recover() {
  [ "${stored}" = false ] || return 0
  kill "${listener_pid:-}" 2>/dev/null || true
  echo "release_bump_create_app: the key is not reported stored; GitHub may have made the App" >&2
  echo "${settings_page}" >&2
  echo "if it exists, delete it and rerun with a new name" >&2
}

coproc listener { exec "${gh_login[@]}" python3 -I "${listener_script}" "${name}" "${deadline_seconds}" "${repository}" "${environment}" "${secret}"; }
# bash unsets listener_PID once the listener has exited, which a refusal does at once.
listener_pid=$!
IFS= read -r -u "${listener[0]}" page_url || fail "the listener did not serve a page"
trap recover EXIT
trap 'exit 130' INT TERM
echo "Serving ${page_url}; click \"Create GitHub App\" there. Opening it in your browser."
xdg-open "${page_url}" >/dev/null 2>&1 || echo "No browser opened: open ${page_url} yourself."

status=0
wait "${listener_pid}" || status=$?
[ "${status}" -eq 0 ] || exit "${status}"
stored=true
xdg-open "${installation_page}" >/dev/null 2>&1 || true
echo "The key of the App ${name} is stored as ${secret} on the environment ${environment} of ${repository}."
echo "Install the App only on platform: ${installation_page}"
