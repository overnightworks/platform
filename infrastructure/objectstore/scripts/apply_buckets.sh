#!/bin/sh
# Makes, for each namespace of /buckets/namespaces.txt, the bucket of that name and grants the key of the namespace's Secret
# object-store read and write on it, the key of its Secret object-store-backup, where one exists, read alone, and every other
# key nothing: the grants of this Job are the grants there are. The keys are imported as they stand, so no secret is made
# here. A second run changes nothing. A failure names the step, the namespace, a key ID or a status, never a secret or an
# answer's body.
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

# credential <namespace> <Secret>: sets key_id and secret from the key credentials of the namespace's Secret of that name.
credential() {
  encoded=$(kubectl --namespace "$1" get secret "$2" --output 'jsonpath={.data.credentials}' 2>/dev/null) ||
    fail "$1: the Secret $2 is unreadable"
  credentials=$(printf '%s' "$encoded" | base64 -d) || fail "$1: the key credentials of the Secret $2 is not base64"
  key_id=$(printf '%s\n' "$credentials" | sed -n 's/^aws_access_key_id *= *//p')
  secret=$(printf '%s\n' "$credentials" | sed -n 's/^aws_secret_access_key *= *//p')
  printf '%s' "$key_id" | grep -Eq '^GK[0-9a-f]{24}$' ||
    fail "$1: aws_access_key_id in the key credentials of the Secret $2 is not GK and 24 hex digits"
  printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$' ||
    fail "$1: aws_secret_access_key in the key credentials of the Secret $2 is not 64 hex digits"
}

# has_backup_key <namespace>: succeeds when the namespace holds the Secret object-store-backup, decided from the object itself.
has_backup_key() {
  found=$(kubectl --namespace "$1" get secret object-store-backup --output name --ignore-not-found 2>/dev/null) ||
    fail "$1: the Secret object-store-backup is unreadable"
  [ -n "$found" ]
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

# import_key <namespace> <name>: imports key_id and secret under the name if Garage does not hold the ID, and refuses a held ID
# with another secret.
import_key() {
  admin "$1: listing the keys" GET /v2/ListKeys
  if printf '%s' "$answer" | jq -e --arg id "$key_id" 'any(.[]; .id == $id)' >/dev/null; then
    admin "$1: reading key $key_id" GET "/v2/GetKeyInfo?id=$key_id&showSecretKey=true"
    stored=$(printf '%s' "$answer" | jq -r .secretAccessKey)
    [ "$stored" = "$secret" ] || fail "$1: Garage holds key $key_id with another secret; a changed secret takes a new key ID"
    return 0
  fi
  body=$(printf '{"accessKeyId":"%s","secretAccessKey":"%s","name":"%s"}' "$key_id" "$secret" "$2")
  admin "$1: importing key $key_id" POST /v2/ImportKey "a key ID Garage has held before takes no second import; a changed key takes a new key ID"
  echo "apply: key $key_id of $1 imported"
}

# grant <namespace> <rights to allow> <rights to deny>: the rights, as JSON members, that the key key_id gets and loses.
grant() {
  body=$(printf '{"bucketId":"%s","accessKeyId":"%s","permissions":{%s}}' "$bucket" "$key_id" "$2")
  admin "$1: allowing key $key_id" POST /v2/AllowBucketKey
  body=$(printf '{"bucketId":"%s","accessKeyId":"%s","permissions":{%s}}' "$bucket" "$key_id" "$3")
  admin "$1: denying key $key_id its other rights" POST /v2/DenyBucketKey
}

# deny_others <namespace> <app key ID> <backup key ID or empty>: every other key of the bucket loses every right.
deny_others() {
  admin "$1: reading the bucket" GET "/v2/GetBucketInfo?id=$bucket"
  others=$(printf '%s' "$answer" | jq -r --arg app "$2" --arg backup "$3" \
    '.keys[] | select(.accessKeyId != $app and .accessKeyId != $backup and (.permissions.read or .permissions.write or .permissions.owner)) | .accessKeyId')
  for other in $others; do
    body=$(printf '{"bucketId":"%s","accessKeyId":"%s","permissions":{"read":true,"write":true,"owner":true}}' "$bucket" "$other")
    admin "$1: denying key $other" POST /v2/DenyBucketKey
    echo "apply: key $other denied on bucket $1"
  done
}

wait_for_garage
while read -r namespace || [ -n "$namespace" ]; do
  credential "$namespace" object-store
  app_key_id=$key_id app_secret=$secret backup_key_id=""
  if has_backup_key "$namespace"; then
    credential "$namespace" object-store-backup
    [ "$key_id" != "$app_key_id" ] || fail "$namespace: the backup key equals the app key: the Secret object-store-backup holds the key of the Secret object-store"
    backup_key_id=$key_id backup_secret=$secret
  fi
  bucket_id "$namespace"
  key_id=$app_key_id secret=$app_secret
  import_key "$namespace" "$namespace"
  grant "$namespace" '"read":true,"write":true' '"owner":true'
  if [ -n "$backup_key_id" ]; then
    key_id=$backup_key_id secret=$backup_secret
    import_key "$namespace" "$namespace-backup"
    grant "$namespace" '"read":true' '"write":true,"owner":true'
  fi
  deny_others "$namespace" "$app_key_id" "$backup_key_id"
  echo "apply: bucket $namespace holds key $app_key_id"
  if [ -n "$backup_key_id" ]; then
    echo "apply: bucket $namespace holds backup key $backup_key_id read only"
  else
    echo "apply: bucket $namespace has no backup key granted"
  fi
done </buckets/namespaces.txt
