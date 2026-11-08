#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
page_file="$LEGAL_LAYER_DIRECTORY/built/impressum.html"
traefik_url="http://traefik.traefik.svc:80"

applied_revision="$(kubectl -n flux-system get kustomization legal -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization legal applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n "$LEGAL_NAMESPACE" wait deployment/legal --for=condition=Available --timeout=3m
echo "the Kustomization legal applied the candidate, and the Deployment legal is Available"

# answer <name> <path>: a Pod in the tunnel's namespace asks Traefik's web port for the path with the host; sets body
# (its bytes, trailing newlines kept), code, header to the content-security-policy header and cache_control to the
# cache-control header. curl appends the trailer, which a shell variable keeps behind the body's last newline.
trailer_mark='@@trailer@@'
answer() {
  request_body "$TUNNEL_NAMESPACE" "$1" "$LEGAL_HOST" "$traefik_url$2" \
    --write-out "${trailer_mark}%{http_code}${trailer_mark}%header{content-security-policy}${trailer_mark}%header{cache-control}"
  cache_control="${status##*"$trailer_mark"}"
  local before_cache_control="${status%"$trailer_mark"*}"
  header="${before_cache_control##*"$trailer_mark"}"
  local before_header="${before_cache_control%"$trailer_mark"*}"
  code="${before_header##*"$trailer_mark"}"
  body="${before_header%"$trailer_mark"*}"
}

# Traefik answers 404 until it has read the Ingress, a moment after the Deployment is Available.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  answer "impressum-request-$attempt" /impressum
  [ "$code" != 404 ] && break
done
[ "$code" = 200 ] || fail "Traefik answered $code, not 200, for $LEGAL_HOST/impressum"
expected_sum="$(sha256sum <"$page_file")"
[ "$(printf '%s' "$body" | sha256sum)" = "$expected_sum" ] ||
  fail "the bytes of $LEGAL_HOST/impressum differ from $page_file"
echo "a Pod in $TUNNEL_NAMESPACE got 200 for $LEGAL_HOST/impressum, with the bytes of $page_file"

expected_policy="$(sed -n 's/^ *add_header Content-Security-Policy "\(.*\)" always;$/\1/p' "$LEGAL_LAYER_DIRECTORY/default.conf")"
[ -n "$expected_policy" ] || fail "$LEGAL_LAYER_DIRECTORY/default.conf sets no Content-Security-Policy"
[ "$header" = "$expected_policy" ] ||
  fail "the Content-Security-Policy of /impressum is '$header', not the one $LEGAL_LAYER_DIRECTORY/default.conf sets"
echo "its Content-Security-Policy is the one $LEGAL_LAYER_DIRECTORY/default.conf sets"

expected_cache_control="$(sed -n 's/^ *add_header Cache-Control "\(.*\)" always;$/\1/p' "$LEGAL_LAYER_DIRECTORY/default.conf")"
[ -n "$expected_cache_control" ] || fail "$LEGAL_LAYER_DIRECTORY/default.conf sets no Cache-Control"
[ "$cache_control" = "$expected_cache_control" ] ||
  fail "the Cache-Control of /impressum is '$cache_control', not the one $LEGAL_LAYER_DIRECTORY/default.conf sets"
echo "its Cache-Control is the one $LEGAL_LAYER_DIRECTORY/default.conf sets"

# The Ingress names the one path, so Traefik answers every other one with its own 404, which carries none of nginx's
# headers; nginx would answer with the policy.
for path in / /unlisted /impressum/unlisted; do
  answer "unlisted-request" "$path"
  [ "$code" = 404 ] || fail "Traefik answered $code, not 404, for $LEGAL_HOST$path"
  [ -z "$header" ] || fail "nginx answered $LEGAL_HOST$path, whose 404 Traefik must give"
  echo "Traefik answered 404 for $LEGAL_HOST$path"
done

# A Pod beside no route gets no answer from the Service: a refused connection (7) or no reply in time (28).
kubectl create namespace "$OTHER_NAMESPACE"
trap 'kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"' EXIT
request "$OTHER_NAMESPACE" denied-request "$LEGAL_HOST" "http://legal.$LEGAL_NAMESPACE.svc:8080/impressum"
[ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; } ||
  fail "a Pod in $OTHER_NAMESPACE got the status $status from the Service legal, curl exit code $exit_code"
echo "a Pod in $OTHER_NAMESPACE got no answer from the Service legal (curl exit code $exit_code)"
