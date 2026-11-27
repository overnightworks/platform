#!/bin/sh
# The staging protocol of the PreBackupPod files (files.yaml), one role per container: `stager` runs the steps in
# order and asks `copy` for each sync of the claim, `bucket` for each sync of the Namespace's bucket (where the Component
# files/bucket adds it and sets STAGE_BUCKET) and `postgres` for the dump through files in /scratch, the pod's emptyDir;
# a served step answers with <step>.exit, its exit status. The staging claim then holds files/ (the copy of the declared
# claim), bucket/ (the copy of the bucket, only with STAGE_BUCKET), postgres.dump and MANIFEST, which is written only
# after the final syncs and lists
#   dump<TAB><sha256><TAB><size>                  the dump's
#   file<TAB><size><TAB><mtime><TAB><path>        each file under files/ and bucket/, sorted, mtime in seconds since the epoch
# /scratch/ready marks the finished tree, and the pod is Ready only on it. A failed step leaves no MANIFEST and no ready.
# Nothing here prints a file name, a row or a credential: rsync's, rclone's and find's messages name files, so they are
# dropped and a failed step names itself and its exit status.
# `listing <tree>...` prints the file lines of the trees under the current directory, which db:load-dump's loader compares
# with the lines MANIFEST holds for a restored tree.
# `room <free> <total> <allocatable> <need>` is the fit's rule, which db:load-dump runs as well.
# Usage: sh stage_files.sh stager|copy|bucket|dump|manifest|room|listing <args>..., run by busybox sh in each container's image.
set -u
scratch=/scratch
staging=/staging
tab="$(printf '\t')"
newline='
'

# Every role ends at once on SIGTERM. PID 1 ignores a signal without a handler, and a shell runs a trap only between its
# commands, so each wait below is a background command the shell waits on, which a trapped signal interrupts.
trap 'exit 0' TERM

# nap: waits a second, interruptibly.
nap() {
  sleep 1 &
  wait "$!"
}

# idle: waits for the SIGTERM with which k8up ends the pod, so the pod neither restarts nor stages again.
idle() {
  sleep 2147483647 &
  wait "$!"
  exit 0
}

# serve <step> <command>...: waits for the step's request, runs the command and records its exit status; a container that
# cannot record it ends non-zero. A restarted container finds the step's exit status in /scratch and does not run it
# again. The seed's stager writes `end` when it ends, which ends every wait, so that its vendor containers end with it.
serve() {
  step="$1"
  shift
  [ ! -e "$scratch/$step.exit" ] || return 0
  until [ -e "$scratch/$step.request" ] || [ -e "$scratch/end" ]; do nap; done
  [ -e "$scratch/$step.request" ] || return 0
  status=0
  "$@" &
  wait "$!" || status=$?
  { echo "$status" >"$scratch/$step.exit.tmp" && mv "$scratch/$step.exit.tmp" "$scratch/$step.exit"; } || exit 1
}

# sync_files: the declared claim, mounted read-only at /source, into files/. A uid that cannot read a file makes rsync
# exit 23. It deletes before it transfers, so that a tree never holds its old copy beside its new one.
sync_files() {
  rsync -a --delete-before /source/ "$staging/files/" 2>/dev/null
}

# tree_size <directory>: prints "<files> <directories> <bytes>" of the tree, never a name; a tree that is not there is
# empty. find and stat read no file's bytes.
tree_size() {
  [ -d "$1" ] || { echo "0 0 0"; return 0; }
  sizes="$(find "$1" -type f -exec stat -c %s {} + 2>/dev/null)" || return 1
  directories="$(find "$1" -mindepth 1 -type d 2>/dev/null | wc -l)"
  files=0
  bytes=0
  for size in $sizes; do
    files=$((files + 1))
    bytes=$((bytes + size))
  done
  echo "$files $((directories)) $bytes"
}

# claim_size: the declared claim's tree_size, in /scratch.
claim_size() {
  size="$(tree_size /source)" || return 1
  echo "$size" >"$scratch/claim-size.answer"
}

# bucket_size: "<objects> <prefixes> <bytes>" of the Namespace's bucket, from one recursive listing with the backup's key
# that goes into a count, so no name leaves the pipe; a failed listing ends the count with a line no listing holds.
bucket_size() {
  size="$({ rclone lsf --recursive --format sp ":s3:$BUCKET" 2>/dev/null || echo failed; } | awk '
    /^failed$/ { failed = 1; next }
    { size = $0; sub(/;.*/, "", size); path = substr($0, length(size) + 2)
      if (path ~ /\/$/) prefixes++; else { objects++; bytes += size } }
    END { if (failed) exit 1; printf "%d %d %.0f\n", objects, prefixes, bytes }')" || return 1
  echo "$size" >"$scratch/bucket-size.answer"
}

# copy_bucket <listing file>: the Namespace's bucket, read with the backup's own key, into bucket/. rclone's output names
# objects, so stdout is dropped and stderr is held in memory, where only the lines that report a source entry rclone
# skipped are counted: a key that is also a directory prefix, or two keys on one path, which rclone ignores with exit 0
# and which the copy would silently lack. Some keys it drops without any message: one with a `..` segment is not
# written, and one with an empty segment lands on the path without it. So the keys listed before the sync go to the
# listing file, and each must be a file of the copy by that very name, which a key written in between cannot stand in
# for; a key listed twice has collapsed already. A listed key the copy lacks fails the step only when the bucket still
# lists it after the sync: an object deleted meanwhile is gone from the second listing, and one rclone dropped is not.
# A copy with a name that holds a newline ends the step at once: rclone lists that key with a symbol for the newline, so
# no listed line equals the name, and the manifest refuses the name with its own message. Any such line, a key the
# copy lacks and the bucket still lists, a failed listing or any exit status but 0 fails the step.
copy_bucket() {
  listing="$1"
  rclone lsf --recursive --files-only ":s3:$BUCKET" >"$listing" 2>/dev/null || return 1
  status=0
  messages="$(rclone sync ":s3:$BUCKET" "$staging/bucket/" --use-server-modtime --delete-before 2>&1 >/dev/null)" || status=$?
  skipped="$(printf '%s\n' "$messages" | grep -c 'found in source - ignoring')"
  [ "$status" = 0 ] || return "$status"
  [ "$skipped" = 0 ] || return 1
  names_with_newline="$(find "$staging/bucket" -name "*$newline*")" || return 1
  [ -z "$names_with_newline" ] || return 0
  [ -z "$(sort "$listing" | uniq -d)" ] || return 1
  find "$staging/bucket" -type f >"$listing.staged" || return 1
  sed "s|^$staging/bucket/||" "$listing.staged" >"$listing.names" || return 1
  # grep ends 1 when no line is selected, and 0 when one is, or 2 when it could not tell.
  status=0
  grep -vxFf "$listing.names" "$listing" >"$listing.missing" || status=$?
  [ "$status" != 1 ] || return 0
  [ "$status" = 0 ] || return 1
  rclone lsf --recursive --files-only ":s3:$BUCKET" >"$listing.after" 2>/dev/null || return 1
  status=0
  grep -qxFf "$listing.after" "$listing.missing" || status=$?
  [ "$status" = 1 ]
}

# sync_bucket: copy_bucket with the listings in /scratch, which holds the keys only until the step ends.
sync_bucket() {
  mkdir -p "$staging/bucket" || return 1
  listing="$scratch/bucket.listing"
  copied=0
  copy_bucket "$listing" || copied=$?
  rm -f "$listing" "$listing.staged" "$listing.names" "$listing.missing" "$listing.after"
  return "$copied"
}

# dump: the database over the Service into a temporary file, renamed when pg_dump succeeded. A fresh pod can be refused
# until the NetworkPolicy controller admits its address, so the server is awaited first, at most 30 times.
dump() {
  rm -f "$staging/postgres.dump" "$staging/postgres.dump.tmp" || return 1
  tries=0
  until pg_isready --quiet --timeout=2; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || return 1
    nap
  done
  PGPASSWORD="$(cat /run/secrets/postgres/password)" pg_dump --format=custom --file="$staging/postgres.dump.tmp" &&
    mv "$staging/postgres.dump.tmp" "$staging/postgres.dump"
}

# file_lines <tree>...: one MANIFEST line for each file under the trees, in the order find gives, from the current directory.
file_lines() {
  find "$@" -type f -exec stat -c "file$tab%s$tab%Y$tab%n" {} + 2>/dev/null
}

# listing <tree>...: the trees' file lines in MANIFEST's form, sorted, which a restore compares with MANIFEST's own.
listing() {
  files="$(file_lines "$@")" || exit 1
  [ -z "$files" ] || printf '%s\n' "$files" | LC_ALL=C sort
}

# room <free> <total> <allocatable> <need>, all in bytes but the allocatable, a Kubernetes quantity: the rule of every fit,
# which the stager and db:load-dump share. The kubelet evicts pods once the node's filesystem has less free than its hard
# threshold plus any reservation, which is total minus the node's allocatable ephemeral storage; a write of <need> bytes
# fits when it leaves more than that free. Prints the margin; exits 0 when it fits, 1 when not and 2 when the allocatable
# is no quantity it reads.
room() {
  awk -v free="$1" -v total="$2" -v allocatable="$3" -v need="$4" '
    BEGIN {
      if (allocatable !~ /^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|K|M|G|T|P)?$/) exit 2
      factor["Ki"] = 1024; factor["Mi"] = 1024 ^ 2; factor["Gi"] = 1024 ^ 3; factor["Ti"] = 1024 ^ 4; factor["Pi"] = 1024 ^ 5
      factor["K"] = 1000; factor["M"] = 1000 ^ 2; factor["G"] = 1000 ^ 3; factor["T"] = 1000 ^ 4; factor["P"] = 1000 ^ 5
      number = allocatable; sub(/[A-Za-z]+$/, "", number); unit = substr(allocatable, length(number) + 1)
      margin = total - number * (unit in factor ? factor[unit] : 1)
      if (margin < 0) margin = 0
      printf "%.0f\n", margin
      exit (free - need > margin) ? 0 : 1
    }'
}

# manifest: writes MANIFEST.tmp from the finished tree; refuses a name with a newline, which would split its line.
manifest() {
  cd "$staging" || exit 1
  set -- files
  [ -z "${STAGE_BUCKET:-}" ] || set -- files bucket
  for tree in "$@"; do
    names_with_newline="$(find "$tree" -name "*$newline*" 2>/dev/null)" || exit 1
    if [ -n "$names_with_newline" ]; then
      echo "stage: refused: a name under $tree/ holds a newline" >&2
      exit 3
    fi
  done
  dump_sha256="$(sha256sum postgres.dump)" || exit 1
  dump_size="$(stat -c %s postgres.dump)" || exit 1
  files="$(listing "$@")" || exit 1
  {
    printf 'dump\t%s\t%s\n' "${dump_sha256%% *}" "$dump_size"
    [ -z "$files" ] || printf '%s\n' "$files"
  } >MANIFEST.tmp
}

# stop_here <the seed's exit status> <the seed's outcome>: a Backup's pod idles, so it never turns Ready; the seed ends
# with its outcome as the termination message, which backup:now reads.
stop_here() {
  if [ -n "${STAGE_SEED:-}" ]; then
    printf '%s' "$2" >/dev/termination-log
    exit "$1"
  fi
  idle
}

# fail <step> <its exit status or -> <message>: names the failed step on stderr and stops there.
fail() {
  echo "stage: $3" >&2
  stop_here 1 "failed $1 $2"
}

# run_steps <deadline> <steps>: requests every step of the space-separated list together and waits for all of them until
# the deadline, in seconds since the epoch, none where it is empty. A step that failed ends the stage naming itself, the first in list order, and
# so does a step still running at the deadline. A step's start and end carry the UTC time, from which its duration reads.
run_steps() {
  deadline="$1"
  steps="$2"
  finished=
  for step in $steps; do
    : >"$scratch/$step.request"
    echo "stage: $step started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  done
  while :; do
    running=
    for step in $steps; do
      if [ ! -e "$scratch/$step.exit" ]; then
        running="${running:-$step}"
        continue
      fi
      status="$(cat "$scratch/$step.exit")"
      [ "$status" = 0 ] || fail "$step" "$status" "$step failed with exit $status"
      case " $finished " in
        *" $step "*) ;;
        *)
          finished="$finished $step"
          echo "stage: $step done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
          ;;
      esac
    done
    [ -n "$running" ] || return 0
    [ -z "$deadline" ] || [ "$(date +%s)" -lt "$deadline" ] || fail "$running" - "$running ran out of its budget"
    nap
  done
}

# guard: refuses while any pod but this one mounts the staging claim, such as a file Job of a failed Backup that still
# reads it. A pod that has ended holds no mount.
guard() {
  pods="$(kubectl --cache-dir=/tmp/kube get pods --output json)" || fail guard - "the guard cannot list the namespace's pods"
  holders="$(printf '%s' "$pods" | jq --arg own "$POD_NAME" '
    (.items[] | select(.metadata.name == $own) | .spec.volumes[] | select(.name == "staging") |
     .persistentVolumeClaim.claimName) as $claim |
    [.items[] | select(.metadata.name != $own and .status.phase != "Succeeded" and .status.phase != "Failed") |
     select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName? == $claim))] | length')" ||
    fail guard - "the guard cannot read the namespace's pods"
  [ -n "$holders" ] || fail guard - "the guard cannot find its own pod"
  if [ "$holders" != 0 ]; then
    echo "stage: refused: $holders other pods mount the staging claim" >&2
    stop_here 4 "refused-held $holders"
  fi
  echo "stage: guard passed"
}

# report_bucket: prints the count and the summed size of the staged bucket's files, no name.
report_bucket() {
  size="$(tree_size "$staging/bucket")" || fail report - "the staged bucket cannot be counted"
  read -r objects _ bytes <<EOF
$size
EOF
  echo "stage: bucket $objects objects $bytes bytes"
}

# missing <source bytes> <staged bytes>: what the sync still writes of a tree.
missing() {
  if [ "$1" -gt "$2" ]; then echo "$(($1 - $2))"; else echo 0; fi
}

# fit: from the sizes the copy and bucket containers answered and the trees already staged, what the pre-syncs write at
# most beside what the staging volume holds: each tree's bytes not yet staged, and a block for each file and directory.
# It prints the counts and bytes, and refuses a write that does not leave more than the kubelet's eviction margin free.
# What a file in flight, the dump and the app's writes meanwhile add stays below that margin.
fit() {
  read -r claim_files claim_directories claim_bytes <"$scratch/claim-size.answer" || fail fit - "the claim's size is unreadable"
  bucket_objects=0 bucket_prefixes=0 bucket_bytes=0 staged_bucket="0 0 0"
  if [ -n "${STAGE_BUCKET:-}" ]; then
    read -r bucket_objects bucket_prefixes bucket_bytes <"$scratch/bucket-size.answer" || fail fit - "the bucket's size is unreadable"
    staged_bucket="$(tree_size "$staging/bucket")" || fail fit - "the staged bucket cannot be counted"
  fi
  staged_claim="$(tree_size "$staging/files")" || fail fit - "the staged claim cannot be counted"
  block="$(stat -f -c %S "$staging")" || fail fit - "the staging volume's block size is unreadable"
  volume="$(df -P "$staging" | awk 'NR == 2 { printf "%.0f %.0f", $4 * 1024, $2 * 1024 }')"
  [ -n "$volume" ] || fail fit - "the staging volume's size is unreadable"
  free="${volume% *}" total="${volume#* }"
  claim_missing="$(missing "$claim_bytes" "${staged_claim##* }")"
  bucket_missing="$(missing "$bucket_bytes" "${staged_bucket##* }")"
  need="$((claim_missing + bucket_missing + (claim_files + claim_directories + bucket_objects + bucket_prefixes) * block))"
  status=0
  margin="$(sh "$0" room "$free" "$total" "$NODE_ALLOCATABLE_STORAGE" "$need")" || status=$?
  [ "$status" != 2 ] || fail fit 2 "the node's allocatable storage '$NODE_ALLOCATABLE_STORAGE' is no quantity"
  echo "stage: fit: claim $claim_files files $claim_directories directories $claim_bytes bytes; bucket $bucket_objects objects $bucket_prefixes prefixes $bucket_bytes bytes; need $need; free $free of $total; margin $margin"
  if [ "$status" != 0 ]; then
    echo "stage: refused: the copies need $need bytes beside the kubelet's eviction margin of $margin, and the staging volume has $free of $total bytes free; free disk space first (mise run disk shows what holds it)" >&2
    stop_here 3 "refused-room $need $free $total $margin"
  fi
}

stager() {
  : "${PRE_SYNC_BUDGET:?}" "${CAPTURE_BUDGET:?}" "${POD_NAME:?}" "${NODE_ALLOCATABLE_STORAGE:?}"
  [ -z "${STAGE_SEED:-}" ] || trap ': >"$scratch/end"' EXIT
  # A restarted container finds its earlier attempt's files in /scratch and does not stage again.
  [ ! -e "$scratch/attempted" ] || fail guard - "a restarted stager does not stage again"
  : >"$scratch/attempted"
  guard
  rm -f "$staging/MANIFEST" "$staging/MANIFEST.tmp" || fail manifest-removal - "the old MANIFEST cannot be removed"
  size_steps=claim-size
  pre_sync_steps=pre-sync
  final_sync_steps=final-sync
  if [ -n "${STAGE_BUCKET:-}" ]; then
    size_steps="$size_steps bucket-size"
    pre_sync_steps="$pre_sync_steps bucket-pre-sync"
    final_sync_steps="$final_sync_steps bucket-final-sync"
  else
    # A layer that dropped the bucket leaves no earlier copy for this run's snapshot or MANIFEST.
    rm -rf "$staging/bucket" || fail bucket-removal - "the old bucket copy cannot be removed"
  fi
  # One deadline holds the sizes and the pre-syncs. The seed has none: it stages what a Backup's deadline cannot.
  pre_sync_deadline=
  [ -n "${STAGE_SEED:-}" ] || pre_sync_deadline="$(($(date +%s) + PRE_SYNC_BUDGET))"
  run_steps "$pre_sync_deadline" "$size_steps"
  fit
  run_steps "$pre_sync_deadline" "$pre_sync_steps"
  if [ -n "${STAGE_SEED:-}" ]; then
    [ -z "${STAGE_BUCKET:-}" ] || report_bucket
    stop_here 0 seeded
  fi
  capture_deadline="$(($(date +%s) + CAPTURE_BUDGET))"
  run_steps "$capture_deadline" dump
  run_steps "$capture_deadline" "$final_sync_steps"
  [ -z "${STAGE_BUCKET:-}" ] || report_bucket
  remaining="$((capture_deadline - $(date +%s)))"
  [ "$remaining" -gt 0 ] || fail manifest - "manifest ran out of its budget"
  status=0
  timeout "$remaining" sh "$0" manifest &
  wait "$!" || status=$?
  [ "$status" = 0 ] || fail manifest "$status" "manifest failed with exit $status"
  mv "$staging/MANIFEST.tmp" "$staging/MANIFEST" || fail manifest - "the MANIFEST cannot be renamed"
  : >"$scratch/ready"
  echo "stage: ready"
  idle
}

case "${1:-}" in
  stager) stager ;;
  copy)
    serve claim-size claim_size
    serve pre-sync sync_files
    [ -z "${STAGE_SEED:-}" ] || exit 0
    serve final-sync sync_files
    idle
    ;;
  bucket)
    serve bucket-size bucket_size
    serve bucket-pre-sync sync_bucket
    [ -z "${STAGE_SEED:-}" ] || exit 0
    serve bucket-final-sync sync_bucket
    idle
    ;;
  dump)
    # 0640 at the pod's group 70, which k8up's Job pods read through their supplemental group.
    umask 027
    serve dump dump
    idle
    ;;
  manifest)
    # A manifest that its time budget stops must exit non-zero, so it keeps the default action of TERM.
    trap - TERM
    manifest
    ;;
  room)
    # A signal must end it non-zero, never as a fit.
    trap - TERM
    shift
    room "$@"
    ;;
  listing)
    shift
    listing "$@"
    ;;
  *)
    echo "usage: sh stage_files.sh stager|copy|bucket|dump|manifest|room|listing <args>..." >&2
    exit 2
    ;;
esac
