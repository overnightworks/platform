#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The bucket role of stage_files.sh, as the seed runs it, in the PreBackupPod's own rclone image against an S3 source
# (rclone serve s3 in a container of the same image on a throwaway network): a staged tree of 2 MiB replaced by 2 MiB under
# another name in a staging volume of 3 MiB is synced, which needs the old file gone before the new one is written. The role
# ends with exit 0 once its pre-sync is done. The image is read from the Component's patch. It prints exit statuses and
# words, never a name.
component=infrastructure/postgres/backup/files/bucket/kustomization.yaml
scripts="${SCRIPTS:-$PWD/infrastructure/postgres/backup/files/scripts}"
export PATH="$HOME/.local/bin:$PATH"
image="$(mise exec -- yq '.patches[] | select(.target.kind == "PreBackupPod") | .patch' "$component" |
  mise exec -- yq '.[] | select(.op == "add" and .path == "/spec/pod/spec/containers/-") | .value.image')"
[ -n "$image" ] || fail "$component names no image for the container bucket"
network="bucket-role-$$"
source_container="bucket-role-source-$$"
cleanup() {
  docker rm -f "$source_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
key=AKIAEXAMPLEKEY0001
secret=secretsecretsecret0001

docker network create "$network" >/dev/null
docker run -d --rm --network "$network" --name "$source_container" --entrypoint sh "$image" -c '
  mkdir -p /srv/b && dd if=/dev/urandom of=/srv/b/object bs=1048576 count=2 2>/dev/null
  exec rclone serve s3 /srv --auth-key '"$key,$secret"' --addr :8080' >/dev/null
until_true 30 "the S3 source answers" docker run --rm --network "$network" --entrypoint sh "$image" -c \
  "RCLONE_S3_PROVIDER=Other RCLONE_S3_ENV_AUTH=true RCLONE_S3_ENDPOINT=http://$source_container:8080 RCLONE_S3_REGION=garage AWS_ACCESS_KEY_ID=$key AWS_SECRET_ACCESS_KEY=$secret rclone lsf :s3:b >/dev/null 2>&1"
out="$(docker run --rm --network "$network" --user 65534 --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /staging:rw,size=3m,mode=1777 --tmpfs /scratch:rw,mode=1777 --tmpfs /tmp:rw,mode=1777 --volume "$scripts:/etc/stage:ro" \
  --env STAGE_SEED=1 --env HOME=/tmp --env RCLONE_CACHE_DIR=/tmp/rclone --env BUCKET=b --env RCLONE_S3_PROVIDER=Other \
  --env RCLONE_S3_ENV_AUTH=true --env "RCLONE_S3_ENDPOINT=http://$source_container:8080" --env RCLONE_S3_REGION=garage \
  --env RCLONE_S3_FORCE_PATH_STYLE=true --env "AWS_ACCESS_KEY_ID=$key" --env "AWS_SECRET_ACCESS_KEY=$secret" --entrypoint sh "$image" -c '
  mkdir -p /staging/bucket && dd if=/dev/urandom of=/staging/bucket/previous bs=1048576 count=2 2>/dev/null
  echo 0 >/scratch/bucket-size.exit
  : >/scratch/bucket-pre-sync.request
  status=0; timeout -s KILL 30 sh /etc/stage/stage_files.sh bucket || status=$?
  echo "role $status"; echo "exit $(cat /scratch/bucket-pre-sync.exit 2>/dev/null || echo none)"
  if [ -e /staging/bucket/object ]; then echo "final yes"; else echo "final no"; fi
  if [ -e /staging/bucket/previous ]; then echo "previous yes"; else echo "previous no"; fi')"
line() { sed -n "s/^$1 //p" <<<"$out"; }
[ "$(line role)" = 0 ] && [ "$(line exit)" = 0 ] && [ "$(line final)" = yes ] && [ "$(line previous)" = no ] ||
  fail "the bucket role did not replace a 2 MiB file by another in a 3 MiB staging volume: '$(tr '\n' ' ' <<<"$out")'"
echo "the bucket role replaced a 2 MiB file by another in a 3 MiB staging volume: exit 0, the new name there, the old one gone"
