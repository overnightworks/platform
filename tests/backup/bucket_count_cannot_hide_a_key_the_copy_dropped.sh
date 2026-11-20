#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The bucket step of stage_files.sh, as the PreBackupPod's container bucket runs it, compares the keys listed before the
# sync with the files of the copy by name: a key written to the bucket during the sync, which the copy holds beside the
# others, cannot make up for a listed key the copy lacks. rclone is a stand-in in a throwaway container without network
# whose sync drops one listed key without a message (as rclone does for a key with a `..` segment) and copies one key
# the listing did not hold; the control copies every listed key and the late one. A key with a newline, which rclone
# lists with the newline shown as the symbol U+240A and writes as a file whose name holds the newline, matches no listed
# line: the step ends 0 so the manifest refuses it with its own message, while two equal lines of a key that is no file
# with a newline end the step with an error. A listed key that left the bucket while the sync ran, which the second
# listing no longer holds, does not fail the step; when that second listing fails, the step fails. The image is the
# Component's own, read from its patch. It prints exit statuses, never a name.
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
    case "${SCENARIO:-}" in
      newline) printf 'same\342\220\212same\n' ;;
      twice) printf 'same\nsame\n' ;;
      deleted | listing-fails)
        if [ -e /fake/listed ]; then
          [ "$SCENARIO" = listing-fails ] && exit 1
          printf 'first\nthird\n'
        else
          : >/fake/listed
          printf 'first\nsecond\nthird\n'
        fi
        ;;
      *) printf 'first\nsecond\nthird\n' ;;
    esac
    ;;
  sync)
    case "${SCENARIO:-}" in
      newline) echo same >"$3/same
same"; exit 0 ;;
      twice) echo same >"$3/same"; exit 0 ;;
      deleted | listing-fails) echo first >"$3/first"; echo late >"$3/late"; echo third >"$3/third"; exit 0 ;;
    esac
    echo first >"$3/first"
    echo late >"$3/late"
    [ "${DROP_ONE:-}" = yes ] || echo second >"$3/second"
    echo third >"$3/third"
    ;;
esac
EOF
)"

# step_exit <drop one: yes|no> [scenario]: the exit status the bucket role records for its first step.
step_exit() {
  docker run --rm --network none --read-only --user 65534 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /scratch:rw,mode=1777 --tmpfs /staging:rw,mode=1777 --tmpfs /fake:rw,exec,mode=1777 \
    --volume "$script:/stage_files.sh:ro" --env STAND_IN="$stand_in" --env DROP_ONE="$1" --env SCENARIO="${2:-}" --env BUCKET=stand-in \
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
[ "$(step_exit no newline)" = 0 ] || fail "a key with a newline, listed with the symbol for it, did not end the step with exit 0 for the manifest to refuse"
echo "a key with a newline, listed with the symbol for it, ended with exit 0 and is left to the manifest's refusal"
twice="$(step_exit no twice)"
[ -n "$twice" ] && [ "$twice" != 0 ] || fail "a key listed twice ended with exit '${twice:-none}'"
echo "a key listed twice and no name with a newline ended with exit $twice"
[ "$(step_exit no deleted)" = 0 ] ||
  fail "a key that left the bucket while the sync ran, with a late key beside the others, did not end with exit 0"
echo "a key deleted from the bucket during the sync ended with exit 0"
relisting="$(step_exit no listing-fails)"
[ -n "$relisting" ] && [ "$relisting" != 0 ] || fail "a failed second listing ended with exit '${relisting:-none}'"
echo "a missing key and a failed second listing ended with exit $relisting"
