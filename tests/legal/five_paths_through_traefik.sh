#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"
layer="$LEGAL_LAYER_DIRECTORY"
traefik_url="http://traefik.traefik.svc:80"
asset_prefix="/_rechtliches/"
pages=(impressum datenschutz nutzungsbedingungen)

applied_revision="$(kubectl -n flux-system get kustomization legal -o jsonpath='{.status.lastAppliedRevision}')"
[ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
  fail "the Kustomization legal applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
kubectl -n "$LEGAL_NAMESPACE" wait deployment/legal --for=condition=Available --timeout=3m
echo "the Kustomization legal applied the candidate, and the Deployment legal is Available"

ready_pods=()
trap 'kubectl -n "$TUNNEL_NAMESPACE" delete pod --ignore-not-found --wait --timeout=2m "${ready_pods[@]}" asset-sweep' EXIT
# Traefik answers 404 until it has read the Ingress, a moment after the Deployment is Available.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  ready_pods+=("impressum-ready-$attempt")
  request "$TUNNEL_NAMESPACE" "impressum-ready-$attempt" "$LEGAL_HOST" "$traefik_url/impressum"
  [ "$status" != 404 ] && break
done
[ "$status" = 200 ] || fail "Traefik answered $status, not 200, for $LEGAL_HOST/impressum"

# conf_header <name>: the value of the add_header line for the header in default.conf.
conf_header() {
  local value
  value="$(sed -n "s/^ *add_header $1 \"\\(.*\\)\" always;\$/\\1/p" "$layer/default.conf")"
  [ -n "$value" ] || fail "$layer/default.conf sets no $1"
  printf '%s' "$value"
}
expected_policy="$(conf_header Content-Security-Policy)"
expected_content_type_options="$(conf_header X-Content-Type-Options)"
expected_referrer_policy="$(conf_header Referrer-Policy)"
expected_cache_control="$(conf_header Cache-Control)"

# The paths nginx answers 200 with the bytes of a committed file, and the checksum of each.
declare -A served_sum
for page in "${pages[@]}"; do
  served_sum["/$page"]="$(sha256sum <"$layer/built/$page.html" | cut -d' ' -f1)"
done
asset_directory="$(find "$layer/assets" -mindepth 1 -maxdepth 1 -type d -printf '%f')"
while IFS= read -r -d '' file; do
  relative="${file#"$layer"/assets/}"
  served_sum["$asset_prefix$relative"]="$(sha256sum <"$file" | cut -d' ' -f1)"
done < <(find "$layer/assets" -type f -print0)

# What a browser asks for must be served: every asset path the three built pages name and every url() in design.css.
references=()
while IFS= read -r reference; do references+=("$reference"); done < <(
  grep -oh "${asset_prefix}[^\"' )<>]*" "$layer"/built/*.html | sort -u)
while IFS= read -r font; do
  references+=("$asset_prefix$asset_directory/$font")
done < <(sed -n "s/.*url('\\([^']*\\)').*/\\1/p" "$layer/assets/$asset_directory/design.css" | sort -u)
[ "${#references[@]}" -gt 0 ] || fail "the built pages name no file under $asset_prefix"
for reference in "${references[@]}"; do
  [ -n "${served_sum[$reference]:-}" ] || fail "$reference is named by a built page or design.css and is no file under $layer/assets"
done
echo "the ${#references[@]} references of the pages and of design.css name files under $layer/assets"

# nginx's 404s, and the paths Traefik's own 404 and 400 answer (they reach no nginx location).
nginx_missing=(/favicon.ico "$asset_prefix" "$asset_prefix$asset_directory/" "$asset_prefix$asset_directory/fonts"
  "$asset_prefix$asset_directory/missing.css" "${asset_prefix}..data/legal-2.css" "$asset_prefix.hidden")
traefik_answers=(/ /unlisted /impressum/unlisted /Impressum "${asset_prefix}a%2Fb")

paths=("${!served_sum[@]}" "${nginx_missing[@]}" "${traefik_answers[@]}")
# One Pod asks every path and prints, for each, the path, the checksum of its body and its status and the four headers,
# so no body leaves the Pod.
sweep_script='set -eu
host="$1"; base="$2"; shift 2
for path in "$@"; do
  answer="$(curl --silent --max-time 10 --retry 5 --retry-connrefused --retry-delay 2 --path-as-is \
    --header "Host: $host" --output /tmp/body \
    --write-out "%{http_code}|%header{content-security-policy}|%header{x-content-type-options}|%header{referrer-policy}|%header{cache-control}" \
    "$base$path")"
  printf "%s|%s|%s\n" "$path" "$(sha256sum </tmp/body | cut -d" " -f1)" "$answer"
done'
client_pod_template="${CLIENT_POD//@IMAGE@/$CLIENT_IMAGE}"
sweep_pod="$(SWEEP_SCRIPT="$sweep_script" SWEEP_ARGUMENTS="$(printf '%s\n' sh "$LEGAL_HOST" "$traefik_url" "${paths[@]}")" \
  yq '.spec.containers[0].command = ["sh", "-c"]
    | .spec.containers[0].args = [strenv(SWEEP_SCRIPT)] + (strenv(SWEEP_ARGUMENTS) | split("\n"))' <<<"${client_pod_template//@NAME@/asset-sweep}")"
printf '%s\n' "$sweep_pod" | kubectl -n "$TUNNEL_NAMESPACE" create -f -
kubectl -n "$TUNNEL_NAMESPACE" wait pod/asset-sweep --timeout=3m \
  --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' || {
  kubectl -n "$TUNNEL_NAMESPACE" describe pod/asset-sweep
  fail "the client Pod asset-sweep did not run to its end"
}
[ "$(kubectl -n "$TUNNEL_NAMESPACE" get pod/asset-sweep -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')" = 0 ] ||
  fail "the client Pod asset-sweep failed: $(kubectl -n "$TUNNEL_NAMESPACE" logs pod/asset-sweep | tail -n 3)"

declare -A answer_sum answer_code answer_policy answer_content_type_options answer_referrer_policy answer_cache_control
while IFS='|' read -r path sum code policy content_type_options referrer_policy cache_control; do
  answer_sum["$path"]="$sum"
  answer_code["$path"]="$code"
  answer_policy["$path"]="$policy"
  answer_content_type_options["$path"]="$content_type_options"
  answer_referrer_policy["$path"]="$referrer_policy"
  answer_cache_control["$path"]="$cache_control"
done < <(kubectl -n "$TUNNEL_NAMESPACE" logs pod/asset-sweep)
for path in "${paths[@]}"; do
  [ -n "${answer_code[$path]:-}" ] || fail "the client Pod printed no answer for $path"
done

# An answer from nginx carries the four headers of default.conf, the 404s included.
nginx_headers_hold() {
  [ "${answer_policy[$1]}" = "$expected_policy" ] &&
    [ "${answer_content_type_options[$1]}" = "$expected_content_type_options" ] &&
    [ "${answer_referrer_policy[$1]}" = "$expected_referrer_policy" ] &&
    [ "${answer_cache_control[$1]}" = "$expected_cache_control" ]
}
for path in "${!served_sum[@]}"; do
  [ "${answer_code[$path]}" = 200 ] || fail "Traefik answered ${answer_code[$path]}, not 200, for $LEGAL_HOST$path"
  [ "${answer_sum[$path]}" = "${served_sum[$path]}" ] || fail "the bytes of $LEGAL_HOST$path differ from the committed file"
  nginx_headers_hold "$path" || fail "the headers of $LEGAL_HOST$path differ from the add_header lines of $layer/default.conf"
done
echo "a Pod in $TUNNEL_NAMESPACE got 200 for ${#served_sum[@]} paths of $LEGAL_HOST (${pages[*]} and every file under $asset_prefix), each with the committed bytes and default.conf's headers"
for path in "${nginx_missing[@]}"; do
  [ "${answer_code[$path]}" = 404 ] || fail "Traefik answered ${answer_code[$path]}, not 404, for $LEGAL_HOST$path"
  nginx_headers_hold "$path" || fail "the 404 for $LEGAL_HOST$path is not nginx's with the headers of $layer/default.conf"
  echo "nginx answered 404 with its headers for $LEGAL_HOST$path"
done
# The Ingress names five paths, so Traefik answers every other one with its own 404, which carries none of nginx's
# policy; a path with an encoded slash gets the entrypoint's 400.
for path in "${traefik_answers[@]}"; do
  expected_code=404
  [[ "$path" == *%2F* ]] && expected_code=400
  [ "${answer_code[$path]}" = "$expected_code" ] || fail "Traefik answered ${answer_code[$path]}, not $expected_code, for $LEGAL_HOST$path"
  [ -z "${answer_policy[$path]}" ] || fail "nginx answered $LEGAL_HOST$path, which Traefik must answer"
  echo "Traefik answered $expected_code for $LEGAL_HOST$path"
done

# A Pod beside no route gets no answer from the Service: a refused connection (7) or no reply in time (28).
kubectl create namespace "$OTHER_NAMESPACE"
trap 'kubectl delete namespace --ignore-not-found --wait --timeout=2m "$OTHER_NAMESPACE"; kubectl -n "$TUNNEL_NAMESPACE" delete pod --ignore-not-found --wait --timeout=2m "${ready_pods[@]}" asset-sweep' EXIT
request "$OTHER_NAMESPACE" denied-request "$LEGAL_HOST" "http://legal.$LEGAL_NAMESPACE.svc:8080/impressum"
[ "$status" = 000 ] && { [ "$exit_code" = 7 ] || [ "$exit_code" = 28 ]; } ||
  fail "a Pod in $OTHER_NAMESPACE got the status $status from the Service legal, curl exit code $exit_code"
echo "a Pod in $OTHER_NAMESPACE got no answer from the Service legal (curl exit code $exit_code)"
