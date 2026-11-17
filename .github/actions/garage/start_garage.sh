#!/bin/sh
# Starts Garage as infrastructure/objectstore runs it, from the files of the commit this action was fetched at: the image
# of garage.yaml and the whole of garage.toml, so a changed pin or setting there changes this with it. The one key and the
# admin token are made here, masked before they are written anywhere, and live only in this job. A failure names the step
# and a status, never a secret or an answer's body. Needs docker, curl, jq and openssl, which a GitHub runner has.
set -eu
umask 077

fail() {
  echo "::error::garage: $1" >&2
  exit 1
}

repository=$(cd "$(dirname "$0")/../../.." && pwd)
objectstore=$repository/infrastructure/objectstore
: "${BUCKET:?}"
printf '%s' "$BUCKET" | grep -Eq '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' || fail "the bucket name $BUCKET is not 3 to 63 of a-z, 0-9 and -"

image=$(sed -n 's/^ *image: *\(docker\.io\/dxflrs\/garage:[^ ]*\) *$/\1/p' "$objectstore/garage.yaml")
[ "$(printf '%s\n' "$image" | wc -l)" = 1 ] && [ -n "$image" ] || fail "infrastructure/objectstore/garage.yaml does not hold exactly one Garage image"
region=$(sed -n 's/^s3_region *= *"\(.*\)"$/\1/p' "$objectstore/garage.toml")
[ -n "$region" ] || fail "infrastructure/objectstore/garage.toml holds no s3_region"

key_id=GK$(openssl rand -hex 12)
secret=$(openssl rand -hex 32)
admin_token=$(openssl rand -hex 32)
rpc_secret=$(openssl rand -hex 32)
for value in "$key_id" "$secret" "$admin_token" "$rpc_secret"; do echo "::add-mask::$value"; done

credentials_file=$RUNNER_TEMP/garage-credentials
printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$key_id" "$secret" >"$credentials_file"
printf 'Authorization: Bearer %s\n' "$admin_token" >"$RUNNER_TEMP/garage-admin-header"

# The secrets reach the container through a file of this job, so no argument of docker or garage holds one.
printf 'GARAGE_RPC_SECRET=%s\nGARAGE_ADMIN_TOKEN=%s\n' "$rpc_secret" "$admin_token" >"$RUNNER_TEMP/garage-env"
docker run --detach --name garage --publish 127.0.0.1:3900:3900 --publish 127.0.0.1:3903:3903 \
  --env GARAGE_CONFIG_FILE=/etc/garage/garage.toml --env-file "$RUNNER_TEMP/garage-env" \
  --volume "$objectstore/garage.toml:/etc/garage/garage.toml:ro" \
  "$image" /garage server --single-node >/dev/null || fail "docker did not start $image"

admin=http://127.0.0.1:3903
deadline=$(($(date +%s) + 60))
until curl --silent --fail --max-time 5 --output /dev/null "$admin/health"; do
  [ "$(date +%s)" -lt "$deadline" ] || {
    docker logs garage >&2 || true
    fail "Garage was not healthy within 60 seconds"
  }
  sleep 1
done

# admin <step> <path> <json>: the body reaches curl through stdin.
admin() {
  step=$1
  path=$2
  body=$3
  status=$(printf '%s' "$body" | curl --silent --max-time 30 --output "$RUNNER_TEMP/garage-answer" --write-out '%{http_code}' \
    --request POST --header @"$RUNNER_TEMP/garage-admin-header" --header 'Content-Type: application/json' \
    --data-binary @- "$admin$path") || fail "$step: Garage did not answer"
  [ "$status" = 200 ] || fail "$step: Garage answered $status"
}

admin "creating the bucket" /v2/CreateBucket "$(jq -nc --arg alias "$BUCKET" '{globalAlias: $alias}')"
bucket_id=$(jq -r .id "$RUNNER_TEMP/garage-answer")
admin "importing the key" /v2/ImportKey "$(jq -nc --arg id "$key_id" --arg secret "$secret" '{accessKeyId: $id, secretAccessKey: $secret, name: "ci"}')"
admin "allowing the key" /v2/AllowBucketKey "$(jq -nc --arg bucket "$bucket_id" --arg id "$key_id" \
  '{bucketId: $bucket, accessKeyId: $id, permissions: {read: true, write: true}}')"
rm -f "$RUNNER_TEMP/garage-answer" "$RUNNER_TEMP/garage-env" "$RUNNER_TEMP/garage-admin-header"

endpoint=http://127.0.0.1:3900
{
  echo "AWS_ENDPOINT_URL_S3=$endpoint"
  echo "AWS_DEFAULT_REGION=$region"
  echo "AWS_SHARED_CREDENTIALS_FILE=$credentials_file"
} >>"$GITHUB_ENV"
{
  echo "bucket=$BUCKET"
  echo "endpoint=$endpoint"
  echo "credentials-file=$credentials_file"
} >>"$GITHUB_OUTPUT"
echo "garage: bucket $BUCKET at $endpoint in region $region, image $image"
