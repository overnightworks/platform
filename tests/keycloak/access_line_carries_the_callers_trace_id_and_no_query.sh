#!/usr/bin/env bash
# access_line_carries_the_callers_trace_id_and_no_query.sh: a request to Keycloak with a traceparent header and a query
# string leaves an access-log line whose method, path and status are in its message and whose mdc.traceId is the
# caller's trace id, and no line of Keycloak's log holds the query. Prints names and outcomes, never a log line.
set -euo pipefail
umask 077
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
namespace="$KEYCLOAK_NAMESPACE"
# shellcheck source=admin_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/admin_api.sh"

trace_id="$(openssl rand -hex 16)"
query_marker="query-$(openssl rand -hex 8)"
path="/realms/$realm/.well-known/openid-configuration"

status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --header "traceparent: 00-$trace_id-$(openssl rand -hex 8)-01" "$local_url$path?marker=$query_marker")"
[ "$status" = 200 ] || fail "discovery answered $status"

# Access lines are written when the response ends, so the line may follow the answer by a moment.
logged() { kubectl -n "$namespace" logs deployment/keycloak --since=10m; }
access_line_logged() {
  logged | jq --raw-input --exit-status --arg trace_id "$trace_id" --arg line "GET $path 200" \
    'fromjson? | select(.mdc.traceId? == $trace_id and .message == $line)' >/dev/null
}
until_true 30 "Keycloak logs the access line of the request with its trace id" access_line_logged
echo "the access line holds the method, the path and the status 200 beside mdc.traceId, which is the caller's"

if logged | grep --quiet --fixed-strings -- "$query_marker"; then
  fail "Keycloak's log holds the request's query string"
fi
echo "no line of Keycloak's log holds the query string"
