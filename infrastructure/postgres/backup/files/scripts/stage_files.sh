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
# Usage: sh stage_files.sh stager|copy|bucket|dump, run by busybox sh in each container's image.
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

# serve <step> <command>...: waits for the step's request, runs the command and records its exit status. A restarted
# container finds the step's exit status in /scratch and does not run it again.
serve() {
  step="$1"
  shift
  [ ! -e "$scratch/$step.exit" ] || return 0
  until [ -e "$scratch/$step.request" ]; do nap; done
  status=0
  "$@" &
  wait "$!" || status=$?
  echo "$status" >"$scratch/$step.exit.tmp"
  mv "$scratch/$step.exit.tmp" "$scratch/$step.exit"
}

# sync_files: the declared claim, mounted read-only at /source, into files/. A uid that cannot read a file makes rsync
# exit 23.
sync_files() {
  rsync -a --delete /source/ "$staging/files/" 2>/dev/null
}

# sync_bucket: the Namespace's bucket, read with the backup's own key, into bucket/. rclone's output names objects, so
# stdout is dropped and stderr is held in memory, where only the lines that report a source entry rclone skipped are
# counted: a key that is also a directory prefix, or two keys on one path, which rclone ignores with exit 0 and which the
# copy would silently lack. Any such line, or any exit status but 0, fails the step.
sync_bucket() {
  mkdir -p "$staging/bucket" || return 1
  status=0
  messages="$(rclone sync ":s3:$BUCKET" "$staging/bucket/" --use-server-modtime 2>&1 >/dev/null)" || status=$?
  skipped="$(printf '%s\n' "$messages" | grep -c 'found in source - ignoring')"
  [ "$status" = 0 ] || return "$status"
  [ "$skipped" = 0 ]
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

# manifest: writes MANIFEST.tmp from the finished tree; refuses a name with a newline, which would split its line.
manifest() {
  cd "$staging" || exit 1
  trees=files
  [ -z "${STAGE_BUCKET:-}" ] || trees="files bucket"
  for tree in $trees; do
    names_with_newline="$(find "$tree" -name "*$newline*" 2>/dev/null)" || exit 1
    if [ -n "$names_with_newline" ]; then
      echo "stage: refused: a name under $tree/ holds a newline" >&2
      exit 3
    fi
  done
  dump_sha256="$(sha256sum postgres.dump)" || exit 1
  dump_size="$(stat -c %s postgres.dump)" || exit 1
  files="$(find $trees -type f -exec stat -c "file$tab%s$tab%Y$tab%n" {} + 2>/dev/null)" || exit 1
  {
    printf 'dump\t%s\t%s\n' "${dump_sha256%% *}" "$dump_size"
    [ -z "$files" ] || printf '%s\n' "$files" | LC_ALL=C sort
  } >MANIFEST.tmp
}

# fail <message>: names the failed step on stderr and idles, so the pod never turns Ready.
fail() {
  echo "stage: $1" >&2
  idle
}

# run_steps <deadline> <steps>: requests every step of the space-separated list together and waits for all of them until
# the deadline, in seconds since the epoch. A step that failed ends the stage naming itself, the first in list order, and
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
      [ "$status" = 0 ] || fail "$step failed with exit $status"
      case " $finished " in
        *" $step "*) ;;
        *)
          finished="$finished $step"
          echo "stage: $step done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
          ;;
      esac
    done
    [ -n "$running" ] || return 0
    [ "$(date +%s)" -lt "$deadline" ] || fail "$running ran out of its budget"
    nap
  done
}

# guard: refuses while any pod but this one mounts the staging claim, such as a file Job of a failed Backup that still
# reads it. A pod that has ended holds no mount.
guard() {
  pods="$(kubectl --cache-dir=/tmp/kube get pods --output json)" || fail "the guard cannot list the namespace's pods"
  holders="$(printf '%s' "$pods" | jq --arg own "$POD_NAME" '
    (.items[] | select(.metadata.name == $own) | .spec.volumes[] | select(.name == "staging") |
     .persistentVolumeClaim.claimName) as $claim |
    [.items[] | select(.metadata.name != $own and .status.phase != "Succeeded" and .status.phase != "Failed") |
     select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName? == $claim))] | length')" ||
    fail "the guard cannot read the namespace's pods"
  [ -n "$holders" ] || fail "the guard cannot find its own pod"
  [ "$holders" = 0 ] || fail "refused: $holders other pods mount the staging claim"
  echo "stage: guard passed"
}

# report_bucket: prints the count and the summed size of the staged bucket's files, no name.
report_bucket() {
  sizes="$(find "$staging/bucket" -type f -exec stat -c %s {} + 2>/dev/null)" || fail "the staged bucket cannot be counted"
  objects=0
  bytes=0
  for size in $sizes; do
    objects=$((objects + 1))
    bytes=$((bytes + size))
  done
  echo "stage: bucket $objects objects $bytes bytes"
}

stager() {
  : "${PRE_SYNC_BUDGET:?}" "${CAPTURE_BUDGET:?}" "${POD_NAME:?}"
  # A restarted container finds its earlier attempt's files in /scratch and does not stage again.
  [ ! -e "$scratch/attempted" ] || fail "a restarted stager does not stage again"
  : >"$scratch/attempted"
  guard
  rm -f "$staging/MANIFEST" "$staging/MANIFEST.tmp" || fail "the old MANIFEST cannot be removed"
  pre_sync_steps=pre-sync
  final_sync_steps=final-sync
  if [ -n "${STAGE_BUCKET:-}" ]; then
    pre_sync_steps="$pre_sync_steps bucket-pre-sync"
    final_sync_steps="$final_sync_steps bucket-final-sync"
  else
    # A layer that dropped the bucket leaves no earlier copy for this run's snapshot or MANIFEST.
    rm -rf "$staging/bucket" || fail "the old bucket copy cannot be removed"
  fi
  run_steps "$(($(date +%s) + PRE_SYNC_BUDGET))" "$pre_sync_steps"
  capture_deadline="$(($(date +%s) + CAPTURE_BUDGET))"
  run_steps "$capture_deadline" dump
  run_steps "$capture_deadline" "$final_sync_steps"
  [ -z "${STAGE_BUCKET:-}" ] || report_bucket
  remaining="$((capture_deadline - $(date +%s)))"
  [ "$remaining" -gt 0 ] || fail "manifest ran out of its budget"
  status=0
  timeout "$remaining" sh "$0" manifest &
  wait "$!" || status=$?
  [ "$status" = 0 ] || fail "manifest failed with exit $status"
  mv "$staging/MANIFEST.tmp" "$staging/MANIFEST" || fail "the MANIFEST cannot be renamed"
  : >"$scratch/ready"
  echo "stage: ready"
  idle
}

case "${1:-}" in
  stager) stager ;;
  copy)
    serve pre-sync sync_files
    serve final-sync sync_files
    idle
    ;;
  bucket)
    serve bucket-pre-sync sync_bucket
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
  *)
    echo "usage: sh stage_files.sh stager|copy|bucket|dump" >&2
    exit 2
    ;;
esac
