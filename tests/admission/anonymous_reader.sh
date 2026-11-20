# shellcheck shell=bash
# Sourced by the cells of tests/admission, after tests/failure.sh.

# anonymous_reader_is_refused <repository> <digest>: the registry gives an anonymous reader no manifest of the
# repository (ghcr.io/<owner>/<name>) at the digest (sha256:<hex>): it refuses the anonymous token, or issues one that
# does not read the manifest, each time with status 401 or 403. It fails when the reader gets the manifest or the registry
# answers another status (a rate limit or an outage proves nothing), and prints how the registry refused.
anonymous_reader_is_refused() {
  local path="${1#ghcr.io/}" response token_status token manifest_status
  response="$(curl --silent --write-out $'\n%{http_code}' "https://ghcr.io/token?scope=repository:$path:pull")" ||
    fail "the anonymous token request for $1 did not reach the registry"
  token_status="${response##*$'\n'}"
  case "$token_status" in
    401 | 403)
      echo "the registry refuses an anonymous token for $1 with status $token_status"
      return 0 ;;
    200) ;;
    *) fail "the registry answered the anonymous token request for $1 with status $token_status, neither a token nor a refusal" ;;
  esac
  token="$(yq -p json '.token' <<<"${response%$'\n'*}")"
  [ -n "$token" ] && [ "$token" != null ] || fail "the registry answered 200 to the anonymous token request for $1 without a token"
  manifest_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --header "Authorization: Bearer $token" \
    --header 'Accept: application/vnd.oci.image.index.v1+json' "https://ghcr.io/v2/$path/manifests/$2")" ||
    fail "the manifest request for $1@$2 did not reach the registry"
  case "$manifest_status" in
    401 | 403) ;;
    200) fail "an anonymous token reads $1's manifest, so Kyverno's credential would prove nothing" ;;
    *) fail "the manifest request for $1@$2 got status $manifest_status, neither the manifest nor a refusal" ;;
  esac
  echo "an anonymous token is issued for $1 and its manifest request is refused with status $manifest_status"
}
