#!/usr/bin/env bash
# Drive scripts/apply_opentofu.sh cloudflare against a fake mise and tofu under bash -x with a synthetic token file: the
# token is in no argv, no environment of a child and no trace, tofu receives only the file's path, and a missing, an
# empty, a blank or an unreadable file fails naming its path before tofu runs.
# Usage: tests/cloudflare/token_stays_out_of_argv_environment_and_trace.sh
# Proves docs/cloudflare-zone.md: the token path.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
real_mise="$(command -v mise)"
real_yq="$(cd "${repository_root}" && mise which yq)"
work_directory="$(mktemp -d)"
trap 'chmod -R u+rwX "${work_directory}"; rm -rf "${work_directory}"' EXIT
fake_bin="${work_directory}/bin"
records="${work_directory}/records"
mkdir "${fake_bin}" "${records}"
# The script is run from outside the repository, as an operator may.
cd "${work_directory}"

# Each fake appends its argv and its own environment to files of its name. The script runs under an environment built
# here from synthetic values only, so the recorded environments hold nothing of the caller's, and the token file's value
# is never exported. The real mise says where the root's files are.
cat >"${fake_bin}/mise" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RECORDS}/mise.argv"
env >>"${RECORDS}/mise.environment"
case "$*" in
  "install --quiet opentofu yq") ;;
  "which tofu") echo "${FAKE_BIN}/tofu" ;;
  "which yq") echo "${REAL_YQ}" ;;
  "run cloudflare:token-file") echo "${FAKE_TOKEN_FILE}" ;;
  "run opentofu:path "*) exec "${REAL_MISE}" "$@" ;;
  *) echo "fake mise: unexpected $*" >&2; exit 1 ;;
esac
FAKE
# The script runs tofu under env -i, so the fake finds the records directory beside its own directory.
cat >"${fake_bin}/tofu" <<'FAKE'
#!/usr/bin/env bash
records="$(cd "$(dirname "$0")/../records" && pwd)"
printf '%s\n' "$*" >>"${records}/tofu.argv"
env >>"${records}/tofu.environment"
case "$2" in
  init | plan) ;;
  show) echo '{"resource_changes":[{"address":"unchanged.thing","change":{"actions":["no-op"]}}]}' ;;
  *) echo "fake tofu: unexpected $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "${fake_bin}/mise" "${fake_bin}/tofu"
# The caller's environment stays out: the script gets these variables only. mise keeps its tools, trust and cache where
# they are, and a provider variable of the caller's kind is planted to show that the allowlist drops it.
ambient_value="ambient-value-of-the-callers-provider-variable"
FAKE_TOKEN_FILE="${work_directory}/token"
synthetic_environment=(env -i "PATH=${fake_bin}:${PATH}" "HOME=${work_directory}/home" MISE_DISABLE_TOOLS=gh,opentofu,tofu
  KUBECONFIG=/nonexistent "FAKE_BIN=${fake_bin}" "REAL_YQ=${real_yq}" "REAL_MISE=${real_mise}" "REPOSITORY_ROOT=${repository_root}"
  "RECORDS=${records}" "XDG_CACHE_HOME=${work_directory}/cache" "XDG_STATE_HOME=${work_directory}/state"
  "MISE_DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/mise" "MISE_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/mise"
  "MISE_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/mise" "MISE_CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/mise"
  "CLOUDFLARE_API_TOKEN=${ambient_value}")
mkdir "${work_directory}/home"

synthetic_token="synthetic-token-$$-${RANDOM}${RANDOM}"
printf '%s\n' "${synthetic_token}" >"${FAKE_TOKEN_FILE}"
chmod 600 "${FAKE_TOKEN_FILE}"

trace="${work_directory}/trace"
run_status=0
output="$("${synthetic_environment[@]}" "FAKE_TOKEN_FILE=${FAKE_TOKEN_FILE}" bash -x "${repository_root}/scripts/apply_opentofu.sh" cloudflare 2>"${trace}")" || run_status=$?
echo "a token file: status ${run_status}"
[ "${run_status}" -eq 0 ] || fail "a token file: status ${run_status}, not 0: ${output}; trace: $(tail -n 5 "${trace}")"

grep -qF -- "-chdir=${repository_root}/src/opentofu/cloudflare plan -input=false -detailed-exitcode -var=api_token_file=${FAKE_TOKEN_FILE} -out=" \
  "${records}/tofu.argv" || fail "tofu's plan is not given the token file's path as its one variable: $(cat "${records}/tofu.argv")"
for recorded in "${records}"/*.argv "${records}"/*.environment "${trace}"; do
  ! grep -qF -- "${synthetic_token}" "${recorded}" || fail "the token is in ${recorded##*/}"
done
grep -qF -- "${FAKE_TOKEN_FILE}" "${trace}" || fail "the trace does not name the token file, so it may not have recorded the run"
! grep -qF -- "${synthetic_token}" <<<"${output}" || fail "the token is in the command's output"
! grep -qF -- "${ambient_value}" "${records}/tofu.environment" || fail "the caller's provider variable reached tofu"

rm -rf "${records}"/*
chmod 600 "${FAKE_TOKEN_FILE}"
missing="${work_directory}/absent-token"
empty="${work_directory}/empty-token"
blank="${work_directory}/blank-token"
unreadable="${work_directory}/unreadable-token"
: >"${empty}"
printf ' \t\n\n' >"${blank}"
echo synthetic >"${unreadable}"
chmod 000 "${unreadable}"
cases=(missing empty blank)
# A superuser reads any file.
[ "$(id -u)" -eq 0 ] || cases+=(unreadable)
for case_name in "${cases[@]}"; do
  FAKE_TOKEN_FILE="${!case_name}"
  run_status=0
  output="$("${synthetic_environment[@]}" "FAKE_TOKEN_FILE=${FAKE_TOKEN_FILE}" "${repository_root}/scripts/apply_opentofu.sh" cloudflare 2>&1)" || run_status=$?
  echo "${case_name} token file: status ${run_status}"
  [ "${run_status}" -eq 1 ] || fail "${case_name} token file: status ${run_status}, not 1: ${output}"
  grep -qF -- "${FAKE_TOKEN_FILE}" <<<"${output}" || fail "${case_name} token file: the refusal does not name ${FAKE_TOKEN_FILE}: ${output}"
  [ ! -e "${records}/tofu.argv" ] || fail "${case_name} token file: tofu ran"
done
