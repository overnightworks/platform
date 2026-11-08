#!/usr/bin/env bash
# Name every Secret whose annotation platform.hallucinai.de/expires-on (YYYY-MM-DD) lies within 30 days or in the past,
# and every one whose date does not parse. The query selects metadata columns only, so no Secret's data is read, and
# the output holds only namespaces, names and dates. `mise run check:secrets-expiry` runs it.
set -euo pipefail

warning_days=30
today="$(date +%F)"

breaches=0
breach() {
  echo "check-secrets-expiry: $1" >&2
  breaches=$((breaches + 1))
}

if ! listing="$(kubectl get secrets --all-namespaces --no-headers \
  --output 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,EXPIRES:.metadata.annotations.platform\.hallucinai\.de/expires-on')"; then
  echo "check-secrets-expiry: listing the Secrets failed, so no expiry is checked" >&2
  exit 1
fi

while read -r namespace name expires_on; do
  [ -n "$name" ] && [ "$expires_on" != "<none>" ] || continue
  if ! [[ $expires_on =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
    [ "$(date --utc --date="$expires_on" +%F 2>/dev/null)" != "$expires_on" ]; then
    breach "$namespace/$name has an expiry that is no YYYY-MM-DD date"
    continue
  fi
  days_left=$((($(date --utc --date="$expires_on" +%s) - $(date --utc --date="$today" +%s)) / 86400))
  if [ "$days_left" -lt 0 ]; then
    breach "$namespace/$name expired on $expires_on"
  elif [ "$days_left" -le "$warning_days" ]; then
    breach "$namespace/$name expires on $expires_on"
  fi
done <<<"$listing"

if [ "$breaches" -gt 0 ]; then
  echo "check-secrets-expiry: $breaches Secret(s) expire within $warning_days days or are past" >&2
  exit 1
fi
echo "check-secrets-expiry: no Secret expires within $warning_days days"
