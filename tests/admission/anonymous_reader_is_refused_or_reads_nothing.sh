#!/usr/bin/env bash
# Drive anonymous_reader_is_refused against a fake curl: the registry refuses the token request, issues a token and
# refuses the manifest, issues a token and answers the manifest, answers a status that is neither a refusal nor the
# manifest (a rate limit, an outage) and cannot be reached. The manifest is requested by the
# full digest, sha256: prefix included.
# Usage: tests/admission/anonymous_reader_is_refused_or_reads_nothing.sh
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=anonymous_reader.sh
source "$(dirname "${BASH_SOURCE[0]}")/anonymous_reader.sh"

requests="$(mktemp)"
trap 'rm -f "$requests"' EXIT
digest="sha256:$(printf '%064d' 7)"
# curl prints the token reply and its status, or the manifest's status alone, as the helper asks for them.
curl() {
  local url="${*: -1}"
  echo "$url" >>"$requests"
  case "$url" in
    */token?*) [ "$fake_token_status" != unreachable ] || return 6
      [ "$fake_token_status" = 200 ] && printf '{"token":"anonymous"}\n200' || printf '{"errors":[{"code":"DENIED"}]}\n%s' "$fake_token_status" ;;
    *) printf '%s' "$fake_manifest_status" ;;
  esac
}

# run_case <token status> <manifest status> <expected exit status> <expected text>
run_case() {
  local output status=0
  fake_token_status="$1" fake_manifest_status="$2"
  : >"$requests"
  output="$(anonymous_reader_is_refused ghcr.io/owner/app "$digest" 2>&1)" || status=$?
  [ "$status" = "$3" ] || fail "token $1 and manifest $2 exit with $status, not $3: $output"
  [[ $output == *"$4"* ]] || fail "token $1 and manifest $2 print '$output', not '$4'"
  echo "token $1 and manifest $2: exit $status, $output"
}
run_case 403 200 0 'refuses an anonymous token for ghcr.io/owner/app with status 403'
run_case 200 401 0 'manifest request is refused with status 401'
grep -qx "https://ghcr.io/v2/owner/app/manifests/$digest" "$requests" || fail "the manifest was not requested by the full digest: $(cat "$requests")"
run_case 200 200 1 "an anonymous token reads ghcr.io/owner/app's manifest"
run_case 429 200 1 'with status 429, neither a token nor a refusal'
run_case 503 200 1 'with status 503, neither a token nor a refusal'
run_case 200 429 1 'got status 429, neither the manifest nor a refusal'
run_case 200 500 1 'got status 500, neither the manifest nor a refusal'
run_case unreachable 200 1 'did not reach the registry'
