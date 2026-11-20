#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The bucket step of stage_files.sh, as the PreBackupPod's container bucket runs it, compares the keys listed before the
# sync with the files of the copy by name: a key written to the bucket during the sync, which the copy holds beside the
# others, cannot make up for a listed key the copy lacks. rclone is a stand-in in a throwaway container without network
# whose sync drops one listed key without a message (as rclone does for a key with a `..` segment) and copies one key
# the listing did not hold; the control copies every listed key and the late one. The image is the Component's own, read
# from its patch. It prints exit statuses, never a name.
component=infrastructure/postgres/backup/files/bucket/kustomization.yaml
script="$PWD/infrastructure/postgres/backup/files/scripts/stage_files.sh"
export PATH="$HOME/.local/bin:$PATH"
image="$(mise exec -- yq '.patches[] | select(.target.kind == "PreBackupPod") | .patch' "$component" |
  mise exec -- yq '.[] | select(.op == "add" and .path == "/spec/pod/spec/containers/-") | .value.image')"
[ -n "$image" ] || fail "$component names no image for the container bucket"
[ -f "$script" ] || fail "$script is missing"

stand_in="$(
  cat <<'EOF'
#!/bin/sh
case "$1" in
  size) echo '{"count":3,"bytes":3}' ;;
  lsf)
    echo first
    echo second
    echo third
    ;;
  sync)
    echo first >"$3/first"
    echo late >"$3/late"
    [ "${DROP_ONE:-}" = yes ] || echo second >"$3/second"
    echo third >"$3/third"
    ;;
esac
EOF
)"

# step_exit <drop one: yes|no>: the exit status the bucket role records for its first step.
step_exit() {
  docker run --rm --network none --read-only --user 65534 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /scratch:rw,mode=1777 --tmpfs /staging:rw,mode=1777 --tmpfs /fake:rw,exec,mode=1777 \
    --volume "$script:/stage_files.sh:ro" --env STAND_IN="$stand_in" --env DROP_ONE="$1" --env BUCKET=stand-in \
    --entrypoint sh "$image" -c '
    printf "%s\n" "$STAND_IN" >/fake/rclone
    chmod +x /fake/rclone
    PATH="/fake:$PATH" sh /stage_files.sh bucket &
    : >/scratch/bucket-pre-sync.request
    tries=0
    until [ -e /scratch/bucket-pre-sync.exit ] || [ "$tries" -ge 30 ]; do tries=$((tries + 1)); sleep 1; done
    cat /scratch/bucket-pre-sync.exit
    kill "$!"'
}
[ "$(step_exit no)" = 0 ] || fail "the control, whose copy holds every listed key and a late one, did not end with exit 0"
echo "the control copy of every listed key and one written during the sync ended with exit 0"
dropped="$(step_exit yes)"
[ -n "$dropped" ] && [ "$dropped" != 0 ] || fail "a copy that dropped a listed key ended with exit '${dropped:-none}' because a late key made the file count equal"
echo "a copy that dropped a listed key and held a late key beside the others ended with exit $dropped"
