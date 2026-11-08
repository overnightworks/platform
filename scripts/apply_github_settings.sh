#!/usr/bin/env bash
# Plan the GitHub settings src/opentofu/github declares, or with --apply also apply that plan, with the operator's gh login.
# Usage: scripts/apply_github_settings.sh [--apply]
# Exit: 0 no change, 2 changes planned (without --apply), 1 failure, which includes a plan that deletes an object (a
# deliberate removal is a `removed` block with destroy = false, which plans a forget). A plan-only run works on any
# commit and writes no state; --apply runs only at a clean origin/main.
set -euo pipefail

LOCK_WAIT_SECONDS=30

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root_directory="${repository_root}/src/opentofu/github"
state_file="${XDG_STATE_HOME:-${HOME}/.local/state}/platform/opentofu/github.tfstate"
cache_directory="${XDG_CACHE_HOME:-${HOME}/.cache}/platform/opentofu/github"
kept_plan="${cache_directory}/last.tfplan"

fail() {
  echo "apply_github_settings: $1" >&2
  exit 1
}

case "$*" in
  "") apply=false ;;
  --apply) apply=true ;;
  *) fail "usage: scripts/apply_github_settings.sh [--apply]" ;;
esac

umask 077
mkdir -p "${cache_directory}"
chmod 700 "${cache_directory}"
# Every child inherits the descriptor, so the lock lives until the last tofu of this run has exited.
exec {lock_descriptor}>"${cache_directory}/lock"
flock --wait "${LOCK_WAIT_SECONDS}" "${lock_descriptor}" ||
  fail "another run holds the lock ${cache_directory}/lock; waited ${LOCK_WAIT_SECONDS} seconds"

if [ "${apply}" = true ]; then
  git -C "${repository_root}" fetch --quiet origin main
  [ "$(git -C "${repository_root}" rev-parse HEAD)" = "$(git -C "${repository_root}" rev-parse origin/main)" ] ||
    fail "--apply runs only when HEAD is origin/main"
  # An ignored file counts too: tofu reads every .tf and auto-loaded .tfvars file in the root.
  [ -z "$(git -C "${repository_root}" status --porcelain --untracked-files=all --ignored=matching -- src/opentofu scripts/apply_github_settings.sh)" ] ||
    fail "--apply runs only with src/opentofu/ and this script unchanged"
fi

# Not under the cache directory: tofu's plugin sockets live here, and a socket path is limited to 108 bytes.
private_temporary="$(mktemp -d -t apply_github_settings.XXXXXX)"
plan_file="$(mktemp "${cache_directory}/plan.XXXXXX")"
trap 'rm -rf "${private_temporary}" "${plan_file}"' EXIT

# The allowlist keeps the caller's tokens, provider settings and TF_* variables away from gh and tofu.
child_environment=(env -i "PATH=${PATH}" "HOME=${HOME}" "LANG=${LANG:-C.UTF-8}" "TMPDIR=${private_temporary}"
  TF_INPUT=0 TF_IN_AUTOMATION=1 TF_CLI_CONFIG_FILE=/dev/null "TF_DATA_DIR=${cache_directory}/data")
for gh_login_variable in XDG_CONFIG_HOME GH_CONFIG_DIR; do
  if [ -n "${!gh_login_variable:-}" ]; then
    child_environment+=("${gh_login_variable}=${!gh_login_variable}")
  fi
done

# The provider falls back to anonymous access when gh gives it no token, so the login is checked first.
login="$("${child_environment[@]}" gh api --hostname github.com user --jq .login)" || login=""
[ -n "${login}" ] || fail "gh produced no login under the command's environment; run gh auth login"
echo "apply_github_settings: planning as ${login}"

cd "${repository_root}"
mise install --quiet opentofu yq
tofu="$(mise which tofu)"
yq="$(mise which yq)"

run_tofu() {
  "${child_environment[@]}" "${tofu}" -chdir="${root_directory}" "$@"
}

mkdir -p "$(dirname "${state_file}")"
run_tofu init -input=false -lockfile=readonly -backend-config="path=${state_file}" >/dev/null
plan_status=0
run_tofu plan -input=false -detailed-exitcode -out="${plan_file}" || plan_status=$?
[ "${plan_status}" -eq 0 ] || [ "${plan_status}" -eq 2 ] || fail "the plan failed with status ${plan_status}"

# An object's state may lack skip_destroy (an import does not write it), so only the plan shows whether a removal
# destroys; `delete` is also half of a replacement, in either order, and `forget` is the removal that keeps the object.
planned_deletions="$(run_tofu show -json "${plan_file}" |
  "${yq}" --input-format json --output-format tsv '.resource_changes[] | select(.change.actions[] == "delete") | .address')" ||
  fail "the plan could not be read"
if [ -n "${planned_deletions}" ]; then
  echo "apply_github_settings: the plan deletes or replaces these objects; nothing was applied:" >&2
  echo "${planned_deletions}" | sed 's/^/  /' >&2
  fail "a deliberate removal is a removed block with lifecycle { destroy = false }"
fi

if [ "${apply}" = true ] && [ "${plan_status}" -eq 2 ]; then
  run_tofu apply -input=false "${plan_file}"
  plan_status=0
fi
mv -f "${plan_file}" "${kept_plan}"
exit "${plan_status}"
