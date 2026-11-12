#!/usr/bin/env bash
# Drive scripts/cloudflare_edge_probe.sh against a fake edge on loopback, started and ended here, that answers as the
# declared edge should from the same two files the probe reads: a healthy edge passes with one line per check and prints
# the same twice; each miss (a deny path open in its exact, case, encoded-slash or doubled-slash form, a 403 without
# Cloudflare's ray header, a redirect that does not happen or goes elsewhere, a legal page or a health path that does not
# answer, an HSTS header twice or not at all, a host without facts, an edge that does not answer) fails the run and is
# named on its own line.
# Usage: tests/cloudflare/edge_probe_reports_each_miss_of_the_edge_and_prints_the_same_before_and_after.sh
# Proves docs/cloudflare-zone.md: the edge probe.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${tests_directory}/../.." && pwd)"
# The probe and the test read the declarations with the locked yq.
PATH="$(dirname "$(cd "${repository_root}" && mise which yq)"):${PATH}"
work_directory="$(mktemp -d)"
server_pid=""
stop_server() {
  if [ -n "${server_pid}" ]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
    server_pid=""
  fi
}
trap 'stop_server; rm -rf "${work_directory}"' EXIT

# The probe finds its two declarations beside itself, as in the repository.
checkout="${work_directory}/checkout"
mkdir -p "${checkout}/scripts" "${checkout}/infrastructure/cloudflared" "${checkout}/src/opentofu/cloudflare"
cp "${repository_root}/scripts/cloudflare_edge_probe.sh" "${checkout}/scripts/"
cp "${tests_directory}/fixtures/edge/config.yaml" "${checkout}/infrastructure/cloudflared/config.yaml"
cp "${tests_directory}/fixtures/edge/zone.yaml" "${checkout}/src/opentofu/cloudflare/zone.yaml"

# start_edge <overrides json>: sets edge_port.
start_edge() {
  printf '%s' "$1" >"${work_directory}/overrides.json"
  # The fake edge reads the declarations the probe reads, as JSON.
  yq --output-format json . "${checkout}/infrastructure/cloudflared/config.yaml" >"${work_directory}/tunnel_lines.json"
  yq --output-format json . "${checkout}/src/opentofu/cloudflare/zone.yaml" >"${work_directory}/zone.json"
  coproc python3 -I "${tests_directory}/fake_edge.py" "${work_directory}/tunnel_lines.json" "${work_directory}/zone.json" "${work_directory}/overrides.json"
  server_pid="${COPROC_PID}"
  read -r -u "${COPROC[0]}" edge_port
}

# probe: sets probe_output and probe_status.
probe() {
  probe_status=0
  probe_output="$(EDGE_PROBE_LOOPBACK_PORT="${edge_port}" "${checkout}/scripts/cloudflare_edge_probe.sh" 2>&1)" || probe_status=$?
}

# case_of <name> <overrides json> <status> <line the output holds>...
case_of() {
  local name="$1" overrides="$2" expected_status="$3" line
  shift 3
  start_edge "${overrides}"
  probe
  stop_server
  echo "${name}: status ${probe_status}"
  [ "${probe_status}" -eq "${expected_status}" ] || fail "${name}: status ${probe_status}, not ${expected_status}: ${probe_output}"
  for line in "$@"; do
    grep -qxF -- "${line}" <<<"${probe_output}" || fail "${name}: the output has no line '${line}': ${probe_output}"
  done
  if [ "${expected_status}" -eq 0 ]; then
    ! grep -q '^MISS' <<<"${probe_output}" || fail "${name}: a passing run has a miss: ${probe_output}"
  fi
}

# A healthy edge: every check has a line of its own, from the declarations alone.
healthy_lines=(
  "ok deny app.example.test /hook/logout exact: 403 cf-ray"
  "ok deny app.example.test /hook/logout case: 403 cf-ray"
  "ok deny app.example.test /hook/logout encoded-slash: 403 cf-ray"
  "ok deny app.example.test /hook/logout doubled-slash: 403 cf-ray"
  "ok deny app.example.test /metrics exact: 403 cf-ray"
  "ok deny app.example.test /metrics doubled-slash: 403 cf-ray"
  "ok redirect example.test /: 302 https://auth.example.test/"
  "ok redirect www.example.test /: 302 https://auth.example.test/"
  "ok legal example.test /legal: 200"
  "ok legal example.test /terms: 200"
  "ok health example.test /legal: 200"
  "ok health auth.example.test /realms/synthetic/.well-known/openid-configuration: 200"
  "ok health app.example.test /health: 200"
  "ok hsts app.example.test: 1"
)
case_of "healthy edge" '[]' 0 "${healthy_lines[@]}"
healthy_output="${probe_output}"
case_of "healthy edge again" '[]' 0
[ "${probe_output}" = "${healthy_output}" ] || fail "two runs against a healthy edge print different output"
[ "$(wc -l <<<"${healthy_output}")" -eq "$(grep -c '^ok ' <<<"${healthy_output}")" ] || fail "the output holds a line that is no check"

# Each miss is named on its own line, and every other check still passes.
case_of "a deny path open in its exact form" '[{"host":"app.example.test","path":"/hook/logout","status":200}]' 1 \
  "MISS deny app.example.test /hook/logout exact: got 200 cf-ray" "ok deny app.example.test /hook/logout case: 403 cf-ray"
case_of "a deny path open in another case" '[{"host":"app.example.test","path":"/HOOK/LOGOUT","status":200}]' 1 \
  "MISS deny app.example.test /hook/logout case: got 200 cf-ray"
case_of "a deny path open with an encoded slash" '[{"host":"app.example.test","path":"/%2Fhook%2Flogout","status":200}]' 1 \
  "MISS deny app.example.test /hook/logout encoded-slash: got 200 cf-ray"
case_of "a deny path open with a doubled slash" '[{"host":"app.example.test","path":"//hook//logout","status":200}]' 1 \
  "MISS deny app.example.test /hook/logout doubled-slash: got 200 cf-ray"
case_of "a refusal that does not come from Cloudflare" '[{"host":"app.example.test","path":"/metrics","ray":false}]' 1 \
  "MISS deny app.example.test /metrics exact: got 403 no cf-ray"
case_of "an apex that does not redirect" '[{"host":"example.test","path":"/","status":200,"location":null}]' 1 \
  "MISS redirect example.test /: got 200"
case_of "a www that redirects elsewhere" '[{"host":"www.example.test","path":"/","location":"https://elsewhere.test/"}]' 1 \
  "MISS redirect www.example.test /: got 302 https://elsewhere.test/"
case_of "a legal page that does not answer" '[{"host":"example.test","path":"/terms","status":404}]' 1 \
  "MISS legal example.test /terms: got 404"
case_of "a health path that does not answer" '[{"host":"app.example.test","path":"/health","status":500}]' 1 \
  "MISS health app.example.test /health: got 500"
case_of "an HSTS header twice" '[{"host":"auth.example.test","path":"/realms/synthetic/.well-known/openid-configuration","hsts":2}]' 1 \
  "MISS hsts auth.example.test: got 2"
case_of "an HSTS header missing" '[{"host":"auth.example.test","path":"/realms/synthetic/.well-known/openid-configuration","hsts":0}]' 1 \
  "MISS hsts auth.example.test: got 0"

# A host of the tunnel's lines with no facts, and a host and a deny path added to the declarations, which the probe reads.
cp "${checkout}/src/opentofu/cloudflare/zone.yaml" "${work_directory}/zone.yaml"
yq --inplace 'del(.hosts["app.example.test"])' "${checkout}/src/opentofu/cloudflare/zone.yaml"
case_of "a host without facts" '[]' 1 "MISS facts app.example.test: no entry in zone.yaml"
cp "${work_directory}/zone.yaml" "${checkout}/src/opentofu/cloudflare/zone.yaml"
yq --inplace '.hosts["auth.example.test"].denied_paths = ["/admin"]' "${checkout}/src/opentofu/cloudflare/zone.yaml"
case_of "a deny path added to the declarations" '[]' 0 "ok deny auth.example.test /admin exact: 403 cf-ray" "ok deny auth.example.test /admin encoded-slash: 403 cf-ray"
cp "${work_directory}/zone.yaml" "${checkout}/src/opentofu/cloudflare/zone.yaml"

# An edge that does not answer fails every check of the run and names them.
edge_port=1
probe
echo "no edge: status ${probe_status}"
[ "${probe_status}" -eq 1 ] || fail "no edge: status ${probe_status}, not 1: ${probe_output}"
grep -qxF "MISS health app.example.test /health: got 000" <<<"${probe_output}" || fail "no edge: the miss is not named: ${probe_output}"

# The repository's own declarations satisfy the probe: every host of the tunnel's lines has its facts.
checkout="${repository_root}"
case_of "the repository's own declarations" '[]' 0
