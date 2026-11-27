#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The staging syncs fail whole and free first. The bucket Component's rclone, as its container runs it, syncs a file into a
# destination too small for it: rclone exits non-zero and leaves no file at the final name and no .partial, so the step fails
# the Backup and the staging tree never holds half a copy; the control syncs the same file into a destination that fits.
# A tree of 2 MiB replaced by 2 MiB under other names in a volume of 3 MiB syncs, which needs the old files gone first:
# rclone's row pins that its sync deletes before it transfers, and the copy role's row that rsync does not delete after it
# (it cannot tell --delete-before from --delete-during, whose generator also frees a directory ahead of its receiver). The
# copy role also ends by itself with exit 0 once its pre-sync is done in a seed, and once the stager has written /scratch/end.
# The images are the PreBackupPod's own, read from their manifests, in throwaway containers without network; they print exit
# statuses and words, never a name.
files_component=infrastructure/postgres/backup/files
export PATH="$HOME/.local/bin:$PATH"
image="$(mise exec -- yq '.patches[] | select(.target.kind == "PreBackupPod") | .patch' "$files_component/bucket/kustomization.yaml" |
  mise exec -- yq '.[] | select(.op == "add" and .path == "/spec/pod/spec/containers/-") | .value.image')"
[ -n "$image" ] || fail "$files_component/bucket/kustomization.yaml names no image for the container bucket"
rsync_image="$(mise exec -- yq 'select(.kind == "PreBackupPod") | .spec.pod.spec.containers[] | select(.name == "copy") | .image' "$files_component/files.yaml")"
[ -n "$rsync_image" ] || fail "$files_component/files.yaml names no image for the container copy"
stage_scripts="$PWD/$files_component/scripts"

# sync_into <destination megabytes> <old megabytes>: the destination holds a file of the old size under another name first;
# prints "exit <status>", "final <name present: yes|no>", "previous <old name present: yes|no>", "partial <count>".
sync_into() {
  docker run --rm --network none --read-only --user 65534 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs "/dest:rw,size=$1m,mode=1777" --tmpfs /source:rw,size=8m,mode=1777 --tmpfs /tmp:rw,mode=1777 --env HOME=/tmp --entrypoint sh "$image" -c '
    dd if=/dev/urandom of=/source/object bs=1048576 count=2 2>/dev/null
    mkdir /dest/bucket
    [ '"$2"' = 0 ] || dd if=/dev/urandom of=/dest/bucket/previous bs=1048576 count='"$2"' 2>/dev/null
    status=0
    rclone sync /source /dest/bucket --use-server-modtime --delete-before >/dev/null 2>&1 || status=$?
    echo "exit $status"
    if [ -e /dest/bucket/object ]; then echo "final yes"; else echo "final no"; fi
    if [ -e /dest/bucket/previous ]; then echo "previous yes"; else echo "previous no"; fi
    echo "partial $(find /dest -name "*.partial" | grep -c . || true)"'
}

# copy_into <staging megabytes> <old megabytes> <requests>: the copy role in seed mode, after the shell commands <requests> have
# written to /scratch, with a claim whose file lies beside the directory of the old file; prints "role <its exit status>"
# (not 137, the status of a role that timeout killed after 15 seconds: it ended by itself), "exit <pre-sync's exit status>", "final", "previous" and "partial" as sync_into does.
copy_into() {
  docker run --rm --network none --read-only --user 65534 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs "/staging:rw,size=$1m,mode=1777" --tmpfs /scratch:rw,mode=1777 --tmpfs /source:rw,size=8m,mode=1777 \
    --volume "$stage_scripts:/etc/stage:ro" --env STAGE_SEED=1 --entrypoint sh "$rsync_image" -c '
    mkdir -p /source/a /source/z /staging/files/z
    dd if=/dev/urandom of=/source/a/object bs=1048576 count=2 2>/dev/null
    : >/source/z/kept
    dd if=/dev/urandom of=/staging/files/z/previous bs=1048576 count='"$2"' 2>/dev/null
    '"$3"'
    status=0
    timeout -s KILL 15 sh /etc/stage/stage_files.sh copy || status=$?
    echo "role $status"
    echo "exit $(cat /scratch/pre-sync.exit 2>/dev/null || echo none)"
    if [ -e /staging/files/a/object ]; then echo "final yes"; else echo "final no"; fi
    if [ -e /staging/files/z/previous ]; then echo "previous yes"; else echo "previous no"; fi
    echo "partial 0"'
}

# line <output> <key>: the line's value.
line() { sed -n "s/^$2 //p" <<<"$1"; }

full="$(sync_into 1 0)"
[ "$(line "$full" exit)" != 0 ] || fail "rclone synced a 2 MiB file into a 1 MiB destination with exit 0"
[ "$(line "$full" final)" = no ] || fail "a file is at its final name after the sync into a full destination"
[ "$(line "$full" partial)" = 0 ] || fail "a .partial is left after the sync into a full destination"
echo "rclone ended with exit $(line "$full" exit) on a full destination, with no file at its final name and no .partial"
fits="$(sync_into 8 0)"
[ "$(line "$fits" exit)" = 0 ] && [ "$(line "$fits" final)" = yes ] ||
  fail "the control sync into a destination that fits did not end with exit 0 and the file at its final name"
echo "the control sync into a destination that fits ended with exit 0 and the file at its final name"
replaced="$(sync_into 3 2)"
[ "$(line "$replaced" exit)" = 0 ] && [ "$(line "$replaced" final)" = yes ] && [ "$(line "$replaced" previous)" = no ] ||
  fail "rclone did not replace a 2 MiB file by another in a 3 MiB destination: '$(tr '\n' ' ' <<<"$replaced")'"
echo "rclone replaced a 2 MiB file by another in a 3 MiB destination: exit 0, the new name there, the old one gone"
copied="$(copy_into 3 2 ': >/scratch/claim-size.request; : >/scratch/pre-sync.request')"
[ "$(line "$copied" role)" = 0 ] && [ "$(line "$copied" exit)" = 0 ] && [ "$(line "$copied" final)" = yes ] && [ "$(line "$copied" previous)" = no ] ||
  fail "the copy role did not end by itself with its pre-sync replacing a 2 MiB file by another in a 3 MiB staging volume: '$(tr '\n' ' ' <<<"$copied")'"
echo "the copy role replaced a 2 MiB file by another in a 3 MiB staging volume and ended by itself with exit 0: the new name there, the old one gone"
ended="$(copy_into 3 2 ': >/scratch/end')"
[ "$(line "$ended" role)" = 0 ] && [ "$(line "$ended" exit)" = none ] && [ "$(line "$ended" final)" = no ] ||
  fail "the copy role did not end with exit 0, unasked, once the stager had written /scratch/end: '$(tr '\n' ' ' <<<"$ended")'"
echo "the copy role ended with exit 0, without syncing, once the stager had written /scratch/end"
