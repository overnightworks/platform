#!/bin/sh
# Makes, for each namespace of /buckets/namespaces.txt, the bucket of that name and grants the key of the namespace's Secret
# object-store read and write on it, and every other key nothing: the grants of this Job are the grants there are. The key
# is imported as it stands, so no secret is made here. A second run changes nothing. A failure names the step, the
# namespace, a key ID or a status, never a secret or an answer's body.
set -eu
umask 077

garage=http://garage:3903
newline='
'

fail() {
  echo "apply: $1" >&2
  exit 1
}

# The header stands in a memory-backed file of this pod, so the token is in no argument.
printf 'Authorization: Bearer %s\n' "$(cat /run/secrets/garage/admin_token)" >/tmp/admin-header

# admin <step> <GET|POST> <path> [<hint>]: sets status and answer. A POST sends body, which stands in a variable so that no
# pipe puts this function into a subshell, and reaches curl through stdin, so that no argument holds a secret.
admin() {
  step=$1 method=$2 path=$3 hint=${4-}
  if [ "$method" = POST ]; then set -- --data-binary @-; else set --; fi
  response=$(printf '%s' "${body-}" | curl --silent --max-time 30 --request "$method" --header @/tmp/admin-header \
    --header 'Content-Type: application/json' --write-out "${newline}%{http_code}" "$@" "$garage$path") ||
    fail "$step: Garage did not answer"
  status=${response##*"$newline"}
  answer=${response%"$newline"*}
  [ "$status" = 200 ] || fail "$step: Garage answered $status${hint:+; $hint}"
}

wait_for_garage() {
  deadline=$(($(date +%s) + 300))
  until curl --silent --fail --max-time 5 --output /dev/null "$garage/health"; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "Garage was not healthy within 300 seconds"
    sleep 2
  done
}

# credential <namespace>: sets key_id and secret from the namespace's Secret object-store.
credential() {
  encoded=$(kubectl --namespace "$1" get secret object-store --output 'jsonpath={.data.credentials}' 2>/dev/null) ||
    fail "$1: the Secret object-store is unreadable"
  credentials=$(printf '%s' "$encoded" | base64 -d) || fail "$1: the key credentials of the Secret object-store is not base64"
  key_id=$(printf '%s\n' "$credentials" | sed -n 's/^aws_access_key_id *= *//p')
  secret=$(printf '%s\n' "$credentials" | sed -n 's/^aws_secret_access_key *= *//p')
  printf '%s' "$key_id" | grep -Eq '^GK[0-9a-f]{24}$' ||
    fail "$1: aws_access_key_id in the key credentials of the Secret object-store is not GK and 24 hex digits"
  printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$' ||
    fail "$1: aws_secret_access_key in the key credentials of the Secret object-store is not 64 hex digits"
}

# bucket_id <namespace>: makes the bucket if no global alias of that name exists, and sets bucket.
bucket_id() {
  admin "$1: listing the buckets" GET /v2/ListBuckets
  bucket=$(printf '%s' "$answer" | jq -r --arg alias "$1" '.[] | select(.globalAliases | index($alias)) | .id')
  [ -n "$bucket" ] && return 0
  body=$(printf '{"globalAlias":"%s"}' "$1")
  admin "$1: creating the bucket" POST /v2/CreateBucket
  bucket=$(printf '%s' "$answer" | jq -r .id)
  echo "apply: bucket $1 created"
}

# import_key <namespace>: imports the key if Garage does not hold its ID, and refuses a held ID with another secret.
import_key() {
  admin "$1: listing the keys" GET /v2/ListKeys
  if printf '%s' "$answer" | jq -e --arg id "$key_id" 'any(.[]; .id == $id)' >/dev/null; then
    admin "$1: reading key $key_id" GET "/v2/GetKeyInfo?id=$key_id&showSecretKey=true"
    stored=$(printf '%s' "$answer" | jq -r .secretAccessKey)
    [ "$stored" = "$secret" ] || fail "$1: Garage holds key $key_id with another secret; a changed secret takes a new key ID"
    return 0
  fi
  body=$(printf '{"accessKeyId":"%s","secretAccessKey":"%s","name":"%s"}' "$key_id" "$secret" "$1")
  admin "$1: importing key $key_id" POST /v2/ImportKey "a key ID Garage has held before takes no second import; a changed key takes a new key ID"
  echo "apply: key $key_id of $1 imported"
}

# grant <namespace>: read and write for the key, no ownership, and nothing for any other key of the bucket.
grant() {
  body=$(printf '{"bucketId":"%s","accessKeyId":"%s","permissions":{"read":true,"write":true}}' "$bucket" "$key_id")
  admin "$1: allowing key $key_id" POST /v2/AllowBucketKey
  body=$(printf '{"bucketId":"%s","accessKeyId":"%s","permissions":{"owner":true}}' "$bucket" "$key_id")
  admin "$1: denying ownership to key $key_id" POST /v2/DenyBucketKey
  admin "$1: reading the bucket" GET "/v2/GetBucketInfo?id=$bucket"
  others=$(printf '%s' "$answer" | jq -r --arg id "$key_id" \
    '.keys[] | select(.accessKeyId != $id and (.permissions.read or .permissions.write or .permissions.owner)) | .accessKeyId')
  for other in $others; do
    body=$(printf '{"bucketId":"%s","accessKeyId":"%s","permissions":{"read":true,"write":true,"owner":true}}' "$bucket" "$other")
    admin "$1: denying key $other" POST /v2/DenyBucketKey
    echo "apply: key $other denied on bucket $1"
  done
}

wait_for_garage
while read -r namespace || [ -n "$namespace" ]; do
  credential "$namespace"
  bucket_id "$namespace"
  import_key "$namespace"
  grant "$namespace"
  echo "apply: bucket $namespace holds key $key_id"
done </buckets/namespaces.txt
