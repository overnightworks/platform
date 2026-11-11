#!/usr/bin/env bash
# Drive `mise run cloudflare:token` and `mise run cloudflare:token-absent` against temporary XDG directories and
# synthetic values: the writer keeps the token at 0600 in a 0700 directory and prints only the path and refuses an empty
# value; the count check prints 0 over files without the token and fails with the count over a kept plan, a data file
# and a state file that hold it, those files written by scripts/apply_opentofu.sh under a fake mise and tofu.
# Usage: tests/cloudflare/token_writer_and_count_check.sh
# Proves docs/cloudflare-zone.md: the token path.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
real_mise="$(command -v mise)"
real_yq="$("${real_mise}" --cd "${repository_root}" which yq)"
work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT
fake_bin="${work_directory}/bin"
mkdir "${fake_bin}"

# mise keeps its tools, trust and cache where they are; only the tasks' XDG directories are temporary.
mise_dirs=("MISE_DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/mise" "MISE_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/mise"
  "MISE_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/mise" "MISE_CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/mise")
export XDG_CONFIG_HOME="${work_directory}/config" XDG_CACHE_HOME="${work_directory}/cache" XDG_STATE_HOME="${work_directory}/state"
run_task() {
  (cd "${repository_root}" && env "${mise_dirs[@]}" "${real_mise}" run "$@")
}

# writer <input> [<arguments>...]: sets writer_output, writer_error and writer_status.
writer() {
  local input="$1"
  writer_status=0
  writer_output="$(printf '%s' "${input}" | run_task cloudflare:token 2>"${work_directory}/writer_error")" || writer_status=$?
  writer_error="$(cat "${work_directory}/writer_error")"
}

synthetic_token="synthetic-token-$$-${RANDOM}${RANDOM}"
token_file="$(run_task cloudflare:token-file)"
[ ! -e "${token_file}" ] || fail "the token file exists before the writer ran: ${token_file}"

writer ""
echo "empty value: status ${writer_status}"
[ "${writer_status}" -ne 0 ] || fail "the writer accepted an empty value"
[ ! -e "${token_file}" ] || fail "the writer created the file for an empty value"
writer $'  \t \n'
[ "${writer_status}" -ne 0 ] || fail "the writer accepted a value of spaces"
[ ! -e "${token_file}" ] || fail "the writer created the file for a value of spaces"

writer "  ${synthetic_token}  "$'\n'
echo "token: status ${writer_status}"
[ "${writer_status}" -eq 0 ] || fail "the writer failed: ${writer_error}"
[ "${writer_output}" = "${token_file}" ] || fail "the writer printed more than the path: ${writer_output}"
! grep -qF -- "${synthetic_token}" <<<"${writer_output}${writer_error}" || fail "the writer printed the token"
[ "$(cat "${token_file}")" = "${synthetic_token}" ] || fail "the file holds more or less than the trimmed token"
[ "$(stat --format=%a "${token_file}")" = 600 ] || fail "the token file has mode $(stat --format=%a "${token_file}"), not 600"
[ "$(stat --format=%a "$(dirname "${token_file}")")" = 700 ] || fail "the token directory has mode $(stat --format=%a "$(dirname "${token_file}")"), not 700"
[ "$(find "$(dirname "${token_file}")" -mindepth 1 | wc -l)" -eq 1 ] || fail "the writer left a staging file beside the token"

writer ""
[ "${writer_status}" -ne 0 ] || fail "the writer accepted an empty value over a token"
[ "$(cat "${token_file}")" = "${synthetic_token}" ] || fail "a refused value changed the token file"
replacement="replacement-${synthetic_token}"
writer "${replacement}"
[ "${writer_status}" -eq 0 ] && [ "$(cat "${token_file}")" = "${replacement}" ] || fail "the writer did not replace the token"
printf '%s\n' "${synthetic_token}" >"${token_file}"

# count_check: sets count_output and count_status.
count_check() {
  count_status=0
  count_output="$(run_task cloudflare:token-absent 2>"${work_directory}/count_error")" || count_status=$?
}

# A plan, a data directory and a state file written where scripts/apply_opentofu.sh puts them, by its own run.
cat >"${fake_bin}/mise" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "install --quiet opentofu yq") ;;
  "which tofu") echo "${FAKE_BIN}/tofu" ;;
  "which yq") echo "${REAL_YQ}" ;;
  "run cloudflare:token-file") echo "${FAKE_TOKEN_FILE}" ;;
  *) echo "fake mise: unexpected $*" >&2; exit 1 ;;
esac
FAKE
# The fake tofu keeps what the case sets in a state file, a data file and a plan archive, as tofu does at the paths it is given.
cat >"${fake_bin}/tofu" <<FAKE
#!/usr/bin/env bash
case "\$2" in
  init)
    mkdir -p "\${TF_DATA_DIR}"
    cp '${work_directory}/in_data' "\${TF_DATA_DIR}/provider_cache"
    for argument in "\$@"; do
      case "\${argument}" in -backend-config=path=*)
        mkdir -p "\$(dirname "\${argument#-backend-config=path=}")"
        cp '${work_directory}/in_state' "\${argument#-backend-config=path=}" ;;
      esac
    done
    ;;
  plan)
    for argument in "\$@"; do
      case "\${argument}" in -out=*) cp '${work_directory}/in_plan.zip' "\${argument#-out=}" ;; esac
    done
    ;;
  show) echo '{"resource_changes":[]}' ;;
esac
FAKE
chmod +x "${fake_bin}/mise" "${fake_bin}/tofu"
write_plan() { # <member content>: a plan archive with a deflated member, as tofu writes one
  rm -f "${work_directory}/in_plan.zip"
  printf '%s\n' "$1" >"${work_directory}/tfplan"
  (cd "${work_directory}" && zip --quiet --compression-method deflate in_plan.zip tfplan)
}
run_apply_script() {
  PATH="${fake_bin}:${PATH}" FAKE_BIN="${fake_bin}" REAL_YQ="${real_yq}" FAKE_TOKEN_FILE="${token_file}" \
    "${repository_root}/scripts/apply_opentofu.sh" cloudflare >/dev/null
}

printf 'clean state\n' >"${work_directory}/in_state"
printf 'clean data\n' >"${work_directory}/in_data"
write_plan "clean plan, long enough to be deflated: $(printf 'a%.0s' {1..500})"
run_apply_script || fail "the script's run over clean files failed"
count_check
echo "clean files: status ${count_status}, count ${count_output}"
[ "${count_status}" -eq 0 ] && [ "${count_output}" = 0 ] || fail "clean files: status ${count_status}, count ${count_output}"

# Each place alone: the token in the plan's deflated member, in a data file, in the state.
for place in in_plan.zip in_data in_state; do
  printf 'clean state\n' >"${work_directory}/in_state"
  printf 'clean data\n' >"${work_directory}/in_data"
  write_plan "clean plan, long enough to be deflated: $(printf 'a%.0s' {1..500})"
  case "${place}" in
    in_plan.zip) write_plan "a plan holding ${synthetic_token} in its member" ;;
    in_data) printf 'a data file holding %s\n' "${synthetic_token}" >"${work_directory}/in_data" ;;
    in_state) printf 'a state holding %s\n' "${synthetic_token}" >"${work_directory}/in_state" ;;
  esac
  run_apply_script || fail "the script's run for ${place} failed"
  count_check
  echo "token in ${place}: status ${count_status}, count ${count_output}"
  [ "${count_status}" -ne 0 ] && [ "${count_output}" = 1 ] || fail "token in ${place}: status ${count_status}, count ${count_output}, not 1"
  ! grep -qF -- "${synthetic_token}" <<<"${count_output}$(cat "${work_directory}/count_error")" || fail "the count check printed the token"
done

# Without a token file or with an empty one nothing is counted, since no pattern would match nothing.
for broken in missing empty; do
  rm -f "${token_file}"
  [ "${broken}" = missing ] || : >"${token_file}"
  count_check
  echo "${broken} token file: status ${count_status}"
  [ "${count_status}" -ne 0 ] && [ -z "${count_output}" ] || fail "${broken} token file: status ${count_status}, output ${count_output}"
  grep -qF -- "${token_file}" "${work_directory}/count_error" || fail "${broken} token file: the refusal does not name ${token_file}"
done
