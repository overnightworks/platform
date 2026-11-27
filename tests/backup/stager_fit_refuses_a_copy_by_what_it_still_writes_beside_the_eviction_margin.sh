#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# The stager of stage_files.sh, in seed mode as the PreBackupPod runs it, in a throwaway container without network with a
# staging volume of 64 MiB, a kubectl that lists only the stager's own pod, and the sizes the copy role would have served:
# its fit measures what the pre-syncs still write, the claim's bytes not yet staged, and refuses a copy that would leave the
# volume less free than the margin. With a margin of 40 MiB a first copy of 30 MiB is refused with exit 3 before any sync,
# naming a need above the copy's bytes, and a first copy of 20 MiB is staged; with a margin of 30 MiB a copy of 30 MiB
# that is already staged needs next to nothing and passes. The image is the one the restore test reads the repository with.
# It prints exit statuses, sizes and words, never a name.
export PATH="$HOME/.local/bin:$PATH"
image="$(mise exec -- yq 'select(.kind == "CronJob" and .metadata.name == "restore-test") | .spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "restic-dump") | .image' infrastructure/postgres/backup/backup.yaml)"
[ -n "$image" ] || fail "infrastructure/postgres/backup/backup.yaml names no image for the restore test's restic-dump"
stage_scripts="$PWD/infrastructure/postgres/backup/files/scripts"
mebibyte=1048576

# seed_fit <allocatable> <claim MiB> <staged MiB>: the seed's stager with the node's allocatable storage, the claim's size
# answered and <staged MiB> of the claim's file already staged; prints "exit <status>", "need <bytes>" from its fit line and
# "message <termination message>".
seed_fit() {
  docker run --rm --network none --user 0 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs "/staging:rw,size=64m,mode=1777" --tmpfs /scratch:rw,mode=1777 --volume "$stage_scripts:/etc/stage:ro" \
    --env STAGE_SEED=1 --env PRE_SYNC_BUDGET=300 --env CAPTURE_BUDGET=180 --env POD_NAME=stager-pod \
    --env NODE_ALLOCATABLE_STORAGE="$1" --entrypoint sh "$image" -c '
    mkdir /fake
    cat >/fake/kubectl <<"FAKE"
#!/bin/sh
echo "{\"items\":[{\"metadata\":{\"name\":\"stager-pod\"},\"status\":{\"phase\":\"Running\"},\"spec\":{\"volumes\":[{\"name\":\"staging\",\"persistentVolumeClaim\":{\"claimName\":\"backup-staging\"}}]}}]}"
FAKE
    chmod +x /fake/kubectl
    echo "1 0 $(('"$2"' * '"$mebibyte"'))" >/scratch/claim-size.answer
    echo 0 >/scratch/claim-size.exit
    echo 0 >/scratch/pre-sync.exit
    if [ '"$3"' -gt 0 ]; then
      mkdir /staging/files
      dd if=/dev/zero of=/staging/files/object bs='"$mebibyte"' count='"$3"' 2>/dev/null
    fi
    status=0
    PATH=/fake:$PATH sh /etc/stage/stage_files.sh stager >/scratch/output 2>&1 || status=$?
    echo "exit $status"
    sed -n "s/.*need \([0-9]*\);.*/need \1/p" /scratch/output
    echo "message $(cat /dev/termination-log 2>/dev/null)"'
}

# line <output> <key>: the line's value.
line() { sed -n "s/^$2 //p" <<<"$1"; }

# A margin of 40 MiB: the volume is 64 MiB and the allocatable 24 MiB.
refused="$(seed_fit 24Mi 30 0)"
[ "$(line "$refused" exit)" = 3 ] && [[ $(line "$refused" message) == "refused-room "* ]] ||
  fail "a first copy of 30 MiB beside a margin of 40 MiB in a volume of 64 MiB was not refused with exit 3: '$(tr '\n' ' ' <<<"$refused")'"
[ "$(line "$refused" need)" -gt $((30 * mebibyte)) ] && [ "$(line "$refused" need)" -lt $((31 * mebibyte)) ] ||
  fail "the need of a first copy of 30 MiB is $(line "$refused" need) bytes, not more than 30 MiB, a block for its file included"
echo "a first copy of 30 MiB beside a margin of 40 MiB in a volume of 64 MiB was refused with exit 3 and a need of $(line "$refused" need) bytes"
passes="$(seed_fit 24Mi 20 0)"
[ "$(line "$passes" exit)" = 0 ] && [ "$(line "$passes" message)" = seeded ] ||
  fail "a first copy of 20 MiB beside a margin of 40 MiB in a volume of 64 MiB was not staged: '$(tr '\n' ' ' <<<"$passes")'"
[ "$(line "$passes" need)" -gt $((20 * mebibyte)) ] && [ "$(line "$passes" need)" -lt $((21 * mebibyte)) ] ||
  fail "the need of a first copy of 20 MiB is $(line "$passes" need) bytes, not more than 20 MiB, a block for its file included"
echo "a first copy of 20 MiB beside the same margin passed the fit with a need of $(line "$passes" need) bytes"

# A margin of 30 MiB: the allocatable is 34 MiB. The copy is staged already, so the sync writes next to nothing.
staged="$(seed_fit 34Mi 30 30)"
[ "$(line "$staged" exit)" = 0 ] && [ "$(line "$staged" message)" = seeded ] ||
  fail "a copy of 30 MiB that is staged already was not accepted beside a margin of 30 MiB: '$(tr '\n' ' ' <<<"$staged")'"
[ "$(line "$staged" need)" -lt "$mebibyte" ] || fail "the need of a copy that is staged already is $(line "$staged" need) bytes, not less than 1 MiB"
echo "a copy of 30 MiB that is staged already passed the fit with a need of $(line "$staged" need) bytes"
