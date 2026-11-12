#!/usr/bin/env bash
# Plan the OpenTofu root src/opentofu/<root> declares, or with --apply also apply that plan: the GitHub settings with the
# operator's gh login, the Cloudflare zone's lookups with the token file `mise run cloudflare:token` wrote.
# Usage: scripts/apply_opentofu.sh <github|cloudflare> [--apply] [--allow-ruleset-update]
# Exit: 0 no change, 2 changes planned (without --apply), 1 failure, which includes a plan that deletes an object (a
# deliberate removal is a `removed` block with destroy = false, which plans a forget) and, for cloudflare, a plan that
# scripts/cloudflare_adoption_check.sh refuses: the adoption of the zone that is more than its imports and the content
# of www, and a later update of a ruleset unless --allow-ruleset-update names it for a reviewed change. A plan-only run
# works on any commit and writes no state; --apply runs only at a clean origin/main.
set -euo pipefail

LOCK_WAIT_SECONDS=30

usage="usage: scripts/apply_opentofu.sh <github|cloudflare> [--apply] [--allow-ruleset-update]"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "apply_opentofu: $1" >&2
  exit 1
}

[ "$#" -ge 1 ] || fail "${usage}"
root="$1"
shift
case "${root}" in
  github | cloudflare) ;;
  *) fail "${usage}" ;;
esac
apply=false
allow_ruleset_update=false
for flag in "$@"; do
  case "${flag}:${root}" in
    --apply:*) apply=true ;;
    --allow-ruleset-update:cloudflare) allow_ruleset_update=true ;;
    *) fail "${usage}" ;;
  esac
done

root_directory="${repository_root}/src/opentofu/${root}"
# Before the first mise call: mise.toml decides the paths below, so a changed one is refused before any of them is used.
if [ "${apply}" = true ]; then
  git -C "${repository_root}" fetch --quiet origin main
  [ "$(git -C "${repository_root}" rev-parse HEAD)" = "$(git -C "${repository_root}" rev-parse origin/main)" ] ||
    fail "--apply runs only when HEAD is origin/main"
  # An ignored file counts too: tofu reads every .tf and auto-loaded .tfvars file in the root. The Cloudflare root also
  # reads the tunnel's lines, which name the zone's records.
  [ -z "$(git -C "${repository_root}" status --porcelain --untracked-files=all --ignored=matching -- src/opentofu infrastructure/cloudflared/config.yaml mise.toml scripts/apply_opentofu.sh scripts/cloudflare_adoption_check.sh)" ] ||
    fail "--apply runs only with src/opentofu/, the tunnel's lines, mise.toml and the scripts unchanged"
fi

# mise looks its tasks up from the current directory, so every mise call runs inside the repository.
cd "${repository_root}"
# mise's hidden task opentofu:path owns these paths, which cloudflare:token-absent reads too.
state_file="$(mise run opentofu:path "${root}" state)"
cache_directory="$(mise run opentofu:path "${root}" cache)"
kept_plan="$(mise run opentofu:path "${root}" plan)"
data_directory="$(mise run opentofu:path "${root}" data)"

umask 077
mkdir -p "${cache_directory}"
chmod 700 "${cache_directory}"
# Every child inherits the descriptor, so the lock lives until the last tofu of this run has exited.
exec {lock_descriptor}>"${cache_directory}/lock"
flock --wait "${LOCK_WAIT_SECONDS}" "${lock_descriptor}" ||
  fail "another run holds the lock ${cache_directory}/lock; waited ${LOCK_WAIT_SECONDS} seconds"

# Not under the cache directory: tofu's plugin sockets live here, and a socket path is limited to 108 bytes.
private_temporary="$(mktemp -d -t apply_opentofu.XXXXXX)"
plan_file="$(mktemp "${cache_directory}/plan.XXXXXX")"
trap 'rm -rf "${private_temporary}" "${plan_file}"' EXIT

# The allowlist keeps the caller's tokens, provider settings and TF_* variables away from gh and tofu.
child_environment=(env -i "PATH=${PATH}" "HOME=${HOME}" "LANG=${LANG:-C.UTF-8}" "TMPDIR=${private_temporary}"
  TF_INPUT=0 TF_IN_AUTOMATION=1 TF_CLI_CONFIG_FILE=/dev/null "TF_DATA_DIR=${data_directory}")

mise install --quiet opentofu yq
tofu="$(mise which tofu)"
yq="$(mise which yq)"

# The one difference between the roots is how the provider gets its credential.
plan_variables=()
case "${root}" in
  github)
    for gh_login_variable in XDG_CONFIG_HOME GH_CONFIG_DIR; do
      if [ -n "${!gh_login_variable:-}" ]; then
        child_environment+=("${gh_login_variable}=${!gh_login_variable}")
      fi
    done
    # The provider falls back to anonymous access when gh gives it no token, so the login is checked first.
    login="$("${child_environment[@]}" gh api --hostname github.com user --jq .login)" || login=""
    [ -n "${login}" ] || fail "gh produced no login under the command's environment; run gh auth login"
    echo "apply_opentofu: planning github as ${login}"
    ;;
  cloudflare)
    # The provider reads the file itself; this command checks it and passes on only its path.
    token_file="$(mise run cloudflare:token-file)"
    [ -f "${token_file}" ] && [ -r "${token_file}" ] && grep -q '[^[:space:]]' "${token_file}" ||
      fail "the token file ${token_file} is missing, unreadable or without a value; run mise run cloudflare:token"
    plan_variables=("-var=api_token_file=${token_file}")
    echo "apply_opentofu: planning cloudflare with the token file ${token_file}"
    ;;
esac

run_tofu() {
  "${child_environment[@]}" "${tofu}" -chdir="${root_directory}" "$@"
}

mkdir -p "$(dirname "${state_file}")"
run_tofu init -input=false -lockfile=readonly -backend-config="path=${state_file}" >/dev/null
plan_status=0
run_tofu plan -input=false -detailed-exitcode "${plan_variables[@]}" -out="${plan_file}" || plan_status=$?
[ "${plan_status}" -eq 0 ] || [ "${plan_status}" -eq 2 ] || fail "the plan failed with status ${plan_status}"

# An object's state may lack skip_destroy (an import does not write it), so only the plan shows whether a removal
# destroys; `delete` is also half of a replacement, in either order, and `forget` is the removal that keeps the object.
plan_json="$(run_tofu show -json "${plan_file}")" || fail "the plan could not be read"
planned_deletions="$("${yq}" --input-format json --output-format tsv '.resource_changes[] | select(.change.actions[] == "delete") | .address' <<<"${plan_json}")" ||
  fail "the plan could not be read"
if [ -n "${planned_deletions}" ]; then
  echo "apply_opentofu: the plan deletes or replaces these objects; nothing was applied:" >&2
  while IFS= read -r address; do
    echo "  ${address}" >&2
  done <<<"${planned_deletions}"
  fail "a deliberate removal is a removed block with lifecycle { destroy = false }"
fi

if [ "${root}" = cloudflare ]; then
  guard_arguments=()
  if [ "${allow_ruleset_update}" = true ]; then
    guard_arguments+=(--allow-ruleset-update)
  fi
  "${repository_root}/scripts/cloudflare_adoption_check.sh" "${guard_arguments[@]}" <<<"${plan_json}" ||
    fail "the Cloudflare plan guard refused the plan; nothing was applied"
fi

if [ "${apply}" = true ] && [ "${plan_status}" -eq 2 ]; then
  run_tofu apply -input=false "${plan_file}"
  plan_status=0
fi
mv -f "${plan_file}" "${kept_plan}"
exit "${plan_status}"
