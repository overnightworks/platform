#!/usr/bin/env bash
# Print GitHub's meta API reply from GITHUB_META_URL. GitHub answers an anonymous read with 403 once a runner address
# used up its hourly limit, so CI sets GITHUB_META_TOKEN; unset or empty, the read stays anonymous. The token reaches
# curl only through its stdin, and tracing ends before it is read.
{ set +x; } 2>/dev/null
set -euo pipefail

meta_url="${GITHUB_META_URL?}"
token="${GITHUB_META_TOKEN-}"
curl_flags=(--fail --silent --show-error --proto '=https' --tlsv1.2)

if [ -z "$token" ]; then
  exec curl "${curl_flags[@]}" "$meta_url"
fi
[[ $token =~ ^[A-Za-z0-9._~+/=-]+$ ]] || {
  echo "github_meta.sh: GITHUB_META_TOKEN holds a character outside the token alphabet" >&2
  exit 1
}
printf 'header = "Authorization: Bearer %s"\n' "$token" | curl "${curl_flags[@]}" --config - "$meta_url"
