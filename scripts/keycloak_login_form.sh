# shellcheck shell=bash
# shellcheck disable=SC2154 # cookie_jar and fail belong to the sourcing script.
# Sourced by the scripts that sign a person in through Keycloak's login page the way a browser does, with curl: `mise run
# live:check` against the public hostnames and the k3d cells against the port-forward. The caller sets cookie_jar, the
# file curl keeps its cookies in, and defines fail (which ends the caller).

# form_action <page file>: the first form's action path, which names the public hostname that a k3d runner cannot reach.
form_action() {
  grep -o '<form[^>]*action="[^"]*"' "$1" | head -n 1 | sed -n 's/.*action="\([^"]*\)".*/\1/p' | sed 's/&amp;/\&/g; s#^https\?://[^/]*##'
}
# curl_url <url>: a curl option file on stdout, so a URL that carries a session code stays out of the arguments.
curl_url() { printf 'url = "%s"\n' "$1"; }
# post_form <page file> <origin> <curl argument>...: posts to the page's form at the origin; prints the status and the
# redirect address. A password goes in as `--data-urlencode password@-` on stdin.
post_form() {
  local action origin="$2"
  action="$(form_action "$1")"
  [ -n "$action" ] || fail "the sign-in page holds no form"
  shift 2
  curl --silent --show-error --max-time 30 --output /dev/null --write-out '%{http_code} %{redirect_url}' --cookie-jar "$cookie_jar" \
    --cookie "$cookie_jar" "$@" --config <(curl_url "$origin$action")
}
