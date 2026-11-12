#!/usr/bin/env bash
# Request the zone's public edge from outside and print one line per check: every denied path of a host is refused with
# 403 and Cloudflare's ray header, also in another case, with an encoded slash and with a doubled slash; the apex and www
# redirect to the sign-in host; the apex's legal pages and every host's health path answer 200; the HSTS header stands
# once. The hosts come from the tunnel's lines and the paths from src/opentofu/cloudflare/zone.yaml, the files the root
# reads, so no list is restated here. The probe sends no credential and its lines hold no timing or id, so a run before
# and a run after an apply are equal when the edge is.
# Usage: scripts/cloudflare_edge_probe.sh
# Exit: 0 every check holds, 1 a check misses (its line starts with MISS) or a declaration cannot be read.
# EDGE_PROBE_LOOPBACK_PORT sends plain HTTP to that port of this machine instead of https to the public edge, for tests.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tunnel_lines="${repository_root}/infrastructure/cloudflared/config.yaml"
zone_facts="${repository_root}/src/opentofu/cloudflare/zone.yaml"
REQUEST_TIMEOUT_SECONDS=20

fail() {
  echo "cloudflare_edge_probe: $1" >&2
  exit 1
}
for tool in curl yq; do
  command -v "${tool}" >/dev/null || fail "${tool} is not installed"
done

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
headers="${scratch}/headers"
misses=0

# request <host> <path>: sets status ("000" when nothing answered) and leaves the response headers in ${headers}. The
# path is sent as written: curl does not merge slashes or decode anything.
request() {
  local host="$1" path="$2" scheme=https target=()
  if [ -n "${EDGE_PROBE_LOOPBACK_PORT:-}" ]; then
    scheme=http
    target=(--connect-to "${host}:80:127.0.0.1:${EDGE_PROBE_LOOPBACK_PORT}")
  fi
  : >"${headers}"
  status="$(curl --silent --path-as-is --max-time "${REQUEST_TIMEOUT_SECONDS}" --output /dev/null --dump-header "${headers}" \
    --write-out '%{http_code}' "${target[@]}" "${scheme}://${host}${path}")" || status=000
}
header_values() {
  # Header names are case-insensitive; curl keeps the carriage return.
  { grep -i "^$1:" "${headers}" || true; } | sed 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//'
}
header_count() {
  { grep -ci "^$1:" "${headers}" || true; }
}

# verdict <check> <observed> <expected>: one line per check, the observation after "got" on a miss.
verdict() {
  if [ "$2" = "$3" ]; then
    echo "ok $1: $2"
  else
    echo "MISS $1: got $2"
    misses=$((misses + 1))
  fi
}

# fact <host> <yq expression over zone.yaml, which names the host as strenv(HOST)>
fact() {
  HOST="$1" yq --exit-status "$2" "${zone_facts}" 2>/dev/null
}

check_deny() {
  local host="$1" path="$2" variant observed rest="${2#/}"
  local variants=(
    "exact:${path}"
    "case:${path^^}"
    "encoded-slash:/%2F${rest//\//%2F}"
    "doubled-slash:${path//\//\/\/}"
  )
  for variant in "${variants[@]}"; do
    request "${host}" "${variant#*:}"
    observed="${status} no cf-ray"
    if [ "$(header_count cf-ray)" -ge 1 ]; then observed="${status} cf-ray"; fi
    verdict "deny ${host} ${path} ${variant%%:*}" "${observed}" "403 cf-ray"
  done
}

check_redirect() {
  local host="$1" location
  request "${host}" /
  location="$(header_values location | head -n 1)"
  verdict "redirect ${host} /" "${status}${location:+ ${location}}" "302 ${redirect_target}"
}

# check_page <host> <kind> <path>
check_page() {
  request "$1" "$3"
  verdict "$2 $1 $3" "${status}" 200
}

tunnel_hosts="$(yq --exit-status '.ingress[] | select(has("hostname")) | .hostname' "${tunnel_lines}")" ||
  fail "no host in ${tunnel_lines}"
redirect_hosts="$(yq --exit-status '.redirect.hostnames[]' "${zone_facts}")" || fail "no redirect.hostnames in ${zone_facts}"
redirect_target="$(yq --exit-status '.redirect.target' "${zone_facts}")" || fail "no redirect.target in ${zone_facts}"
served_pages="$(yq --exit-status '.redirect.serve.pages[]' "${zone_facts}")" || fail "no redirect.serve.pages in ${zone_facts}"

while IFS= read -r host; do
  if ! fact "${host}" '.hosts[strenv(HOST)]' >/dev/null; then
    echo "MISS facts ${host}: no entry in zone.yaml"
    misses=$((misses + 1))
    continue
  fi
  if ! health_path="$(fact "${host}" '.hosts[strenv(HOST)].health_path')"; then
    echo "MISS facts ${host}: no health_path in zone.yaml"
    misses=$((misses + 1))
    continue
  fi
  while IFS= read -r denied_path; do
    [ -z "${denied_path}" ] || check_deny "${host}" "${denied_path}"
  done < <(fact "${host}" '.hosts[strenv(HOST)].denied_paths[]' || true)
  if grep -qxF -- "${host}" <<<"${redirect_hosts}"; then
    while IFS= read -r page; do
      check_page "${host}" legal "${page}"
    done <<<"${served_pages}"
  fi
  check_page "${host}" health "${health_path}"
  verdict "hsts ${host}" "$(header_count strict-transport-security)" 1
done <<<"${tunnel_hosts}"

while IFS= read -r host; do
  check_redirect "${host}"
done <<<"${redirect_hosts}"

[ "${misses}" -eq 0 ]
