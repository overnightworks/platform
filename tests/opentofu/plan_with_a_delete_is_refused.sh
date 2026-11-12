#!/usr/bin/env bash
# Drive scripts/apply_opentofu.sh for each root against a fake mise, tofu and gh on plans that delete, replace, forget
# or change nothing: a delete or replacement fails naming its address and applies nothing, a forget passes, and each
# root keeps its own state file and cache directory. For the Cloudflare root it also drives the plan guard through the
# script: a first plan that is more than the imports and the content of www is refused and applies nothing, one that is
# not passes, and an update of a ruleset is refused unless --allow-ruleset-update names it, a delete never passing.
# Usage: tests/opentofu/plan_with_a_delete_is_refused.sh
# Proves docs/github-settings.md GH-5, GH-6.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Resolved before the fakes: the script reads the plan with the locked yq.
real_mise="$(command -v mise)"
real_yq="$(cd "${repository_root}" && mise which yq)"
# mise keeps its tools, trust and cache where they are; only the tasks' XDG directories are temporary.
export MISE_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mise" MISE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mise"
export MISE_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mise" MISE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mise"
work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT
fake_bin="${work_directory}/bin"
mkdir "${fake_bin}"
# The script is run from outside the repository, as an operator may.
cd "${work_directory}"

# The fake mise installs nothing, names the fake tofu, the real yq and the token file of the case, and lets the real mise
# say where the root's files are.
cat >"${fake_bin}/mise" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "install --quiet opentofu yq") ;;
  "which tofu") echo "${FAKE_BIN}/tofu" ;;
  "which yq") echo "${REAL_YQ}" ;;
  "run cloudflare:token-file") echo "${FAKE_TOKEN_FILE}" ;;
  "run opentofu:path "*) exec "${REAL_MISE}" "$@" ;;
  *) echo "fake mise: unexpected $*" >&2; exit 1 ;;
esac
FAKE
# The script runs tofu under env -i, so the fake reads the plan's status and JSON and records an apply in files.
cat >"${fake_bin}/tofu" <<FAKE
#!/usr/bin/env bash
case "\$2" in
  init) printf '%s\\n' "\${*:2}" >>'${work_directory}/init_arguments' ;;
  plan) exit "\$(cat '${work_directory}/plan_status')" ;;
  show) cat '${work_directory}/plan.json' ;;
  apply) echo applied >>'${work_directory}/applied' ;;
  *) echo "fake tofu: unexpected \$*" >&2; exit 1 ;;
esac
FAKE
cat >"${fake_bin}/gh" <<'FAKE'
#!/usr/bin/env bash
echo tester
FAKE
chmod +x "${fake_bin}/mise" "${fake_bin}/tofu" "${fake_bin}/gh"
# mise's locked tools and the operator's login must not answer instead of the fakes.
export PATH="${fake_bin}:${PATH}" MISE_DISABLE_TOOLS=gh,opentofu,tofu KUBECONFIG=/nonexistent
export FAKE_BIN="${fake_bin}" REAL_YQ="${real_yq}" REAL_MISE="${real_mise}" REPOSITORY_ROOT="${repository_root}"
apply_marker="${work_directory}/applied"
export XDG_CACHE_HOME="${work_directory}/cache" XDG_STATE_HOME="${work_directory}/state"
# The Cloudflare root's credential step passes on an existing token file with a value and never passes it on.
export FAKE_TOKEN_FILE="${work_directory}/token"
echo synthetic-token >"${FAKE_TOKEN_FILE}"

plan_json() {
  local address_and_actions
  address_and_actions=""
  [ "$#" -eq 0 ] || address_and_actions="$(printf '{"address":"%s","change":{"actions":%s}},' "$@")"
  printf '{"resource_changes":[%s{"address":"unchanged.thing","change":{"actions":["no-op"]}}]}' "${address_and_actions}"
}

# A checkout whose HEAD is its origin/main and clean, so --apply gets past its own guards to the plan.
apply_checkout="${work_directory}/checkout"
mkdir -p "${apply_checkout}/scripts" "${apply_checkout}/src/opentofu/github" "${apply_checkout}/src/opentofu/cloudflare" "${apply_checkout}/infrastructure/cloudflared"
cp "${repository_root}/scripts/apply_opentofu.sh" "${repository_root}/scripts/cloudflare_adoption_check.sh" "${apply_checkout}/scripts/"
cp "${repository_root}/mise.toml" "${repository_root}/mise.lock" "${apply_checkout}/"
export MISE_TRUSTED_CONFIG_PATHS="${apply_checkout}"
touch "${apply_checkout}/src/opentofu/github/main.tf" "${apply_checkout}/src/opentofu/cloudflare/main.tf" "${apply_checkout}/infrastructure/cloudflared/config.yaml"
git -C "${apply_checkout}" init --quiet --initial-branch=main
git -C "${apply_checkout}" add .
git -C "${apply_checkout}" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.invalid commit --quiet --message test
git clone --quiet --bare "${apply_checkout}" "${work_directory}/origin.git"
git -C "${apply_checkout}" remote add origin "${work_directory}/origin.git"

# run_script <case name> <plan status> <plan json> <arguments...>: runs the root of the loop; sets output and script_status.
run_script() {
  local case_name="$1" script="${repository_root}/scripts/apply_opentofu.sh"
  printf '%s' "$2" >"${work_directory}/plan_status"
  printf '%s' "$3" >"${work_directory}/plan.json"
  shift 3
  case " $* " in *" --apply "*) script="${apply_checkout}/scripts/apply_opentofu.sh" ;; esac
  rm -f "${apply_marker}"
  script_status=0
  output="$("${script}" "${root}" "$@" 2>&1)" || script_status=$?
  echo "${root} ${case_name}: status ${script_status}"
}
expect_refused() {
  local case_name="$1" named="$2"
  [ "${script_status}" -eq 1 ] || fail "${case_name}: status ${script_status}, not 1: ${output}"
  grep -q -- "${named}" <<<"${output}" || fail "${case_name}: the refusal does not name ${named}: ${output}"
  [ ! -e "${apply_marker}" ] || fail "${case_name}: apply ran"
}

for root in github cloudflare; do
  deleting="$(plan_json a.deleted '["delete"]')"
  run_script "plan with a delete" 2 "${deleting}"
  expect_refused "plan with a delete" a.deleted

  run_script "plan with a delete under --apply" 2 "${deleting}" --apply
  expect_refused "plan with a delete under --apply" a.deleted

  run_script "plan with a forget under --apply" 2 "$(plan_json d.forgotten '["forget"]')" --apply
  [ "${script_status}" -eq 0 ] || fail "plan with a forget under --apply: status ${script_status}, not 0: ${output}"
  [ -e "${apply_marker}" ] || fail "plan with a forget under --apply: apply did not run"

  run_script "plan with a create-before-delete replacement" 2 "$(plan_json b.replaced '["create","delete"]')"
  expect_refused "plan with a create-before-delete replacement" b.replaced

  run_script "plan with a delete-before-create replacement" 2 "$(plan_json c.replaced '["delete","create"]')"
  expect_refused "plan with a delete-before-create replacement" c.replaced

  run_script "plan with a forget" 2 "$(plan_json d.forgotten '["forget"]')"
  [ "${script_status}" -eq 2 ] || fail "plan with a forget: status ${script_status}, not 2: ${output}"

  run_script "plan with no change" 0 "$(plan_json)"
  [ "${script_status}" -eq 0 ] || fail "plan with no change: status ${script_status}, not 0: ${output}"

  # --apply refuses off origin/main and with an unreviewed file in the roots or the host file, and applies nothing.
  git -C "${apply_checkout}" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.invalid commit --quiet --allow-empty --message ahead
  run_script "--apply ahead of origin/main" 2 "$(plan_json d.forgotten '["forget"]')" --apply
  expect_refused "--apply ahead of origin/main" "HEAD is origin/main"
  git -C "${apply_checkout}" reset --quiet --hard origin/main

  echo unreviewed >"${apply_checkout}/src/opentofu/${root}/unreviewed.auto.tfvars"
  run_script "--apply with an untracked file in the roots" 2 "$(plan_json d.forgotten '["forget"]')" --apply
  expect_refused "--apply with an untracked file in the roots" "unchanged"
  rm "${apply_checkout}/src/opentofu/${root}/unreviewed.auto.tfvars"

  # mise.toml decides where the state, the cache and the lock live, so an edit of it is unreviewed too.
  echo "# unreviewed" >>"${apply_checkout}/mise.toml"
  run_script "--apply with a changed mise.toml" 2 "$(plan_json d.forgotten '["forget"]')" --apply
  expect_refused "--apply with a changed mise.toml" "unchanged"
  git -C "${apply_checkout}" checkout --quiet -- mise.toml

  # The Cloudflare root reads the tunnel's lines for its records, so an edit of them is unreviewed too.
  echo "# unreviewed" >>"${apply_checkout}/infrastructure/cloudflared/config.yaml"
  run_script "--apply with a changed host file" 2 "$(plan_json d.forgotten '["forget"]')" --apply
  expect_refused "--apply with a changed host file" "unchanged"
  git -C "${apply_checkout}" checkout --quiet -- infrastructure/cloudflared/config.yaml

  # The refusal comes before any path from mise.toml is used: an edit that moves the cache to a new place leaves that place unmade.
  hijacked_cache="${work_directory}/hijacked/${root}"
  sed -i "s|^cache_directory=.*|cache_directory=\"${hijacked_cache}\"|" "${apply_checkout}/mise.toml"
  run_script "--apply with a mise.toml that moves the cache" 2 "$(plan_json d.forgotten '["forget"]')" --apply
  expect_refused "--apply with a mise.toml that moves the cache" "unchanged"
  [ ! -e "${work_directory}/hijacked" ] || fail "--apply with a mise.toml that moves the cache: the moved path was used"
  git -C "${apply_checkout}" checkout --quiet -- mise.toml

  # Each root has its own state file and its own cache directory with its own lock.
  grep -qxF -- "init -input=false -lockfile=readonly -backend-config=path=${XDG_STATE_HOME}/platform/opentofu/${root}.tfstate" \
    "${work_directory}/init_arguments" || fail "${root}: init names no state file of this root"
  [ -e "${XDG_CACHE_HOME}/platform/opentofu/${root}/lock" ] || fail "${root}: no lock in the root's own cache directory"
done

# The flag names a Cloudflare ruleset, so the GitHub root refuses it.
usage_refusals=("" "other" "cloudflare extra" "--apply" "github --allow-ruleset-update")
for arguments in "${usage_refusals[@]}"; do
  usage_status=0
  # shellcheck disable=SC2086 # the words are the arguments under test
  usage_output="$("${repository_root}/scripts/apply_opentofu.sh" ${arguments} 2>&1)" || usage_status=$?
  echo "usage with '${arguments}': status ${usage_status}"
  [ "${usage_status}" -eq 1 ] || fail "usage with '${arguments}': status ${usage_status}, not 1: ${usage_output}"
  grep -q "usage: scripts/apply_opentofu.sh <github|cloudflare> \\[--apply\\] \\[--allow-ruleset-update\\]" <<<"${usage_output}" ||
    fail "usage with '${arguments}': no usage line: ${usage_output}"
done

# The Cloudflare root's plans: the guard's own cases are tests/cloudflare/adoption_plan_is_exactly_the_imports_and_at_most_the_www_content.sh.
root=cloudflare
adoption_plan="${repository_root}/tests/cloudflare/fixtures/adoption_plan.json"
adopted_plan="$(jq -c '.resource_changes |= map(.change.importing = null)' "${adoption_plan}")"
ruleset_update_plan() {
  jq -c --arg ruleset "$1" '(.resource_changes[] | select(.address == $ruleset) | .change.actions) = ["update"]' <<<"${adopted_plan}"
}
created_record_plan="$(jq -c '(.resource_changes[] | select(.index == "a.example.test") | .change) |= (.actions = ["create"] | .importing = null)' "${adoption_plan}")"

run_script "adoption plan with a created record" 2 "${created_record_plan}"
expect_refused "adoption plan with a created record" 'a.example.test"\] create'
run_script "adoption plan with a created record under --apply" 2 "${created_record_plan}" --apply
expect_refused "adoption plan with a created record under --apply" 'a.example.test"\] create'

run_script "adoption plan of imports" 2 "$(jq -c . "${adoption_plan}")"
[ "${script_status}" -eq 2 ] || fail "adoption plan of imports: status ${script_status}, not 2: ${output}"
grep -q "8 imports" <<<"${output}" || fail "adoption plan of imports: the counts are not printed: ${output}"
run_script "adoption plan of imports under --apply" 2 "$(jq -c . "${adoption_plan}")" --apply
[ "${script_status}" -eq 0 ] || fail "adoption plan of imports under --apply: status ${script_status}, not 0: ${output}"
[ -e "${apply_marker}" ] || fail "adoption plan of imports under --apply: apply did not run"

for ruleset in cloudflare_ruleset.deny_public cloudflare_ruleset.client_address; do
  ruleset_update="$(ruleset_update_plan "${ruleset}")"
  run_script "update of ${ruleset} without the flag" 2 "${ruleset_update}"
  expect_refused "update of ${ruleset} without the flag" "--allow-ruleset-update"
  grep -qF -- "${ruleset} update" <<<"${output}" || fail "update of ${ruleset} without the flag: the refusal does not name it: ${output}"
  run_script "update of ${ruleset} without the flag under --apply" 2 "${ruleset_update}" --apply
  expect_refused "update of ${ruleset} without the flag under --apply" "--allow-ruleset-update"
  run_script "update of ${ruleset} with the flag" 2 "${ruleset_update}" --allow-ruleset-update
  [ "${script_status}" -eq 2 ] || fail "update of ${ruleset} with the flag: status ${script_status}, not 2: ${output}"
  run_script "update of ${ruleset} with the flag under --apply" 2 "${ruleset_update}" --apply --allow-ruleset-update
  [ "${script_status}" -eq 0 ] || fail "update of ${ruleset} with the flag under --apply: status ${script_status}, not 0: ${output}"
  [ -e "${apply_marker}" ] || fail "update of ${ruleset} with the flag under --apply: apply did not run"
done

# A plan that tofu shows as nothing cannot be read, so it is refused whatever it is for and nothing is applied.
for blank_root in github cloudflare; do
  root="${blank_root}"
  run_script "plan that shows as nothing" 2 ""
  expect_refused "plan that shows as nothing" "could not be read"
  run_script "plan that shows as nothing under --apply" 2 "" --apply
  expect_refused "plan that shows as nothing under --apply" "could not be read"
done
root=cloudflare

# A half-finished adoption keeps the adoption's rules: a created record beside imports is refused.
half_finished_created_plan="$(jq -c '.resource_changes |= map(if .type == "cloudflare_ruleset" then . else .change.importing = null end)
  | (.resource_changes[] | select(.index == "a.example.test") | .change.actions) = ["create"]' "${adoption_plan}")"
run_script "half-finished adoption with a created record under --apply" 2 "${half_finished_created_plan}" --apply
expect_refused "half-finished adoption with a created record under --apply" 'a.example.test"\] create'

# The flag allows no delete.
deleting_ruleset_plan="$(jq -c '(.resource_changes[] | select(.address == "cloudflare_ruleset.deny_public") | .change.actions) = ["delete", "create"]' <<<"${adopted_plan}")"
run_script "ruleset replacement with the flag" 2 "${deleting_ruleset_plan}" --allow-ruleset-update
expect_refused "ruleset replacement with the flag" "cloudflare_ruleset.deny_public"
