#!/usr/bin/env bash
# Drive scripts/check_renovate_report.sh on a copy of itself beside a small fixture tree and hand-written reports.
# Usage: tests/renovate/report_check_names_each_missing_pin.sh
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT
tree="${work_directory}/tree"

digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"
digest_c="sha256:$(printf 'c%.0s' {1..64})"
digest_d="sha256:$(printf 'd%.0s' {1..64})"

mkdir -p "${tree}/scripts" "${tree}/infrastructure/one" "${tree}/infrastructure/two" "${tree}/.github/workflows"
cp "${repository_root}/scripts/check_renovate_report.sh" "${tree}/scripts/"
# One digest stands in two files, and a rendered.yaml holds a digest no pin owns.
echo "image: registry.example/one:1.0@${digest_a}" >"${tree}/infrastructure/one/one.yaml"
echo "image: registry.example/shared:1.0@${digest_b}" >"${tree}/infrastructure/one/shared.yaml"
echo "image: registry.example/shared:1.0@${digest_b}" >"${tree}/infrastructure/two/shared.yaml"
echo "image: registry.example/rendered:1.0@${digest_c}" >"${tree}/infrastructure/two/rendered.yaml"
printf 'K3S_VERSION = "v1.2.3+k3s1"\nrender chart oci://registry.example/chart:2.0@%s\n' "${digest_d}" >"${tree}/mise.toml"
echo "RENOVATE_IMAGE: registry.example/renovate:3.0@${digest_a}" >"${tree}/.github/workflows/renovate.yml"

# report <dependency>...: a file report whose dependencies are the given packageFile, value, skipReason triples.
report() {
  local file value skip dependencies=()
  while [ $# -gt 0 ]; do
    file="$1" value="$2" skip="$3"
    shift 3
    dependencies+=("{\"packageFile\": \"${file}\", \"deps\": [{\"currentDigest\": \"${value}\", \"currentValue\": \"${value}\", \"skipReason\": \"${skip}\"}]}")
  done
  local joined
  joined="$(IFS=,; echo "${dependencies[*]:-}")"
  echo "{\"repositories\": {\"owner/repo\": {\"packageFiles\": {\"regex\": [${joined}]}}}}"
}
complete_report() {
  report infrastructure/one/one.yaml "${digest_a}" "" infrastructure/one/shared.yaml "${digest_b}" "" \
    infrastructure/two/shared.yaml "${digest_b}" "" mise.toml "v1.2.3+k3s1" "" mise.toml "${digest_d}" "" \
    .github/workflows/renovate.yml "${digest_a}" ""
}

check() { "${tree}/scripts/check_renovate_report.sh" "$@" 2>&1; }
expect_fail() {
  local case_name="$1" needle="$2" output
  shift 2
  if output="$(check "$@")"; then fail "the check passed ${case_name}: ${output}"; fi
  grep -qF -- "${needle}" <<<"${output}" || fail "the check failed ${case_name} without naming ${needle}: ${output}"
  echo "ok: ${case_name} fails naming ${needle}"
}

expect_fail "without a report" "is missing or empty" "${work_directory}/absent.json"
report >"${work_directory}/none.json"
expect_fail "on a report with no dependency" "holds no dependency" "${work_directory}/none.json"
complete_report >"${work_directory}/complete.json"
output="$(check "${work_directory}/complete.json")" || fail "the complete report failed: ${output}"
echo "ok: the complete report passes"

# A digest in two files is two pairs: the report that holds it for one file lacks the other.
report infrastructure/one/one.yaml "${digest_a}" "" infrastructure/one/shared.yaml "${digest_b}" "" \
  mise.toml "v1.2.3+k3s1" "" mise.toml "${digest_d}" "" .github/workflows/renovate.yml "${digest_a}" "" >"${work_directory}/one-file.json"
expect_fail "when one file of a shared digest is absent" "infrastructure/two/shared.yaml ${digest_b}" "${work_directory}/one-file.json"
report infrastructure/one/one.yaml "${digest_a}" "" infrastructure/one/shared.yaml "${digest_b}" "" \
  infrastructure/two/shared.yaml "${digest_b}" "" mise.toml "${digest_d}" "" .github/workflows/renovate.yml "${digest_a}" "" >"${work_directory}/no-k3s.json"
expect_fail "when K3S_VERSION is absent" "mise.toml v1.2.3+k3s1" "${work_directory}/no-k3s.json"
report infrastructure/one/one.yaml "${digest_a}" "" infrastructure/one/shared.yaml "${digest_b}" "" \
  infrastructure/two/shared.yaml "${digest_b}" "" mise.toml "v1.2.3+k3s1" "" mise.toml "${digest_d}" "" >"${work_directory}/no-image.json"
expect_fail "when the workflow's own image is absent" ".github/workflows/renovate.yml ${digest_a}" "${work_directory}/no-image.json"
report infrastructure/one/one.yaml "${digest_a}" "" infrastructure/one/shared.yaml "${digest_b}" "" \
  infrastructure/two/shared.yaml "${digest_b}" "" mise.toml "v1.2.3+k3s1" "" mise.toml "${digest_d}" "no-version" \
  .github/workflows/renovate.yml "${digest_a}" "" >"${work_directory}/skipped.json"
expect_fail "when a pin is skipped" "mise.toml ${digest_d} (skipReason: no-version)" "${work_directory}/skipped.json"
