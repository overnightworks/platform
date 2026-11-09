#!/usr/bin/env bash
# Drive scripts/apply_github_settings.sh against a fake mise, tofu and gh on plans that delete, replace, forget or
# change nothing: a delete or replacement fails naming its address and applies nothing, a forget passes.
# Usage: tests/github/plan_with_a_delete_is_refused.sh
# Proves docs/github-settings.md GH-1, GH-5, GH-6.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Resolved before the fakes: the script reads the plan with the locked yq.
real_yq="$(cd "${repository_root}" && mise which yq)"
work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT
fake_bin="${work_directory}/bin"
mkdir "${fake_bin}"

# The fake mise installs nothing and names the fake tofu and the real yq.
cat >"${fake_bin}/mise" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "install --quiet opentofu yq") ;;
  "which tofu") echo "${FAKE_BIN}/tofu" ;;
  "which yq") echo "${REAL_YQ}" ;;
  *) echo "fake mise: unexpected $*" >&2; exit 1 ;;
esac
FAKE
# The script runs tofu under env -i, so the fake reads the plan's status and JSON and records an apply in files.
cat >"${fake_bin}/tofu" <<FAKE
#!/usr/bin/env bash
case "\$2" in
  init) ;;
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
export FAKE_BIN="${fake_bin}" REAL_YQ="${real_yq}"
apply_marker="${work_directory}/applied"
export XDG_CACHE_HOME="${work_directory}/cache" XDG_STATE_HOME="${work_directory}/state"

plan_json() {
  local address_and_actions
  address_and_actions=""
  [ "$#" -eq 0 ] || address_and_actions="$(printf '{"address":"%s","change":{"actions":%s}},' "$@")"
  printf '{"resource_changes":[%s{"address":"unchanged.thing","change":{"actions":["no-op"]}}]}' "${address_and_actions}"
}

# A checkout whose HEAD is its origin/main and clean, so --apply gets past its own guards to the plan.
apply_checkout="${work_directory}/checkout"
mkdir -p "${apply_checkout}/scripts" "${apply_checkout}/src/opentofu/github"
cp "${repository_root}/scripts/apply_github_settings.sh" "${apply_checkout}/scripts/"
touch "${apply_checkout}/src/opentofu/github/main.tf"
git -C "${apply_checkout}" init --quiet --initial-branch=main
git -C "${apply_checkout}" add .
git -C "${apply_checkout}" -c user.name=test -c user.email=test@example.invalid commit --quiet --message test
git clone --quiet --bare "${apply_checkout}" "${work_directory}/origin.git"
git -C "${apply_checkout}" remote add origin "${work_directory}/origin.git"

# run_script <case name> <plan status> <plan json> <arguments...>: sets output and script_status.
run_script() {
  local case_name="$1" script="${repository_root}/scripts/apply_github_settings.sh"
  printf '%s' "$2" >"${work_directory}/plan_status"
  printf '%s' "$3" >"${work_directory}/plan.json"
  shift 3
  [ "$*" != --apply ] || script="${apply_checkout}/scripts/apply_github_settings.sh"
  rm -f "${apply_marker}"
  script_status=0
  output="$("${script}" "$@" 2>&1)" || script_status=$?
  echo "${case_name}: status ${script_status}"
}
expect_refused() {
  local case_name="$1" named="$2"
  [ "${script_status}" -eq 1 ] || fail "${case_name}: status ${script_status}, not 1: ${output}"
  grep -q -- "${named}" <<<"${output}" || fail "${case_name}: the refusal does not name ${named}: ${output}"
  [ ! -e "${apply_marker}" ] || fail "${case_name}: apply ran"
}

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
