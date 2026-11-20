#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The bucket Component's rclone, as its container runs it, syncs a file into a destination too small for it: rclone exits
# non-zero and leaves no file at the final name and no .partial, so the step fails the Backup and the staging tree never
# holds half a copy. The control syncs the same file into a destination that fits. The image is the Component's own, read
# from its patch, in a throwaway container without network; it prints exit statuses and words, never a name.
component=infrastructure/postgres/backup/files/bucket/kustomization.yaml
export PATH="$HOME/.local/bin:$PATH"
image="$(mise exec -- yq '.patches[] | select(.target.kind == "PreBackupPod") | .patch' "$component" |
  mise exec -- yq '.[] | select(.op == "add" and .path == "/spec/pod/spec/containers/-") | .value.image')"
[ -n "$image" ] || fail "$component names no image for the container bucket"

# sync_into <destination megabytes>: prints "exit <status>", "final <name present: yes|no>", "partial <count>".
sync_into() {
  docker run --rm --network none --read-only --user 65534 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs "/dest:rw,size=$1m,mode=1777" --tmpfs /source:rw,size=8m,mode=1777 --tmpfs /tmp:rw,mode=1777 --env HOME=/tmp --entrypoint sh "$image" -c '
    dd if=/dev/urandom of=/source/object bs=1048576 count=2 2>/dev/null
    status=0
    rclone sync /source /dest/bucket --use-server-modtime >/dev/null 2>&1 || status=$?
    echo "exit $status"
    if [ -e /dest/bucket/object ]; then echo "final yes"; else echo "final no"; fi
    echo "partial $(find /dest -name "*.partial" | grep -c . || true)"'
}
full="$(sync_into 1)"
[ "$(sed -n 's/^exit //p' <<<"$full")" != 0 ] || fail "rclone synced a 2 MiB file into a 1 MiB destination with exit 0"
[ "$(sed -n 's/^final //p' <<<"$full")" = no ] || fail "a file is at its final name after the sync into a full destination"
[ "$(sed -n 's/^partial //p' <<<"$full")" = 0 ] || fail "a .partial is left after the sync into a full destination"
echo "rclone ended with exit $(sed -n 's/^exit //p' <<<"$full") on a full destination, with no file at its final name and no .partial"
fits="$(sync_into 8)"
[ "$(sed -n 's/^exit //p' <<<"$fits")" = 0 ] && [ "$(sed -n 's/^final //p' <<<"$fits")" = yes ] ||
  fail "the control sync into a destination that fits did not end with exit 0 and the file at its final name"
echo "the control sync into a destination that fits ended with exit 0 and the file at its final name"
