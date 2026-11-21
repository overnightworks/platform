#!/bin/sh
# The bucket steps of the restore test (the Component files/bucket), one role per init container, in order, handing each
# other files in /object, the pod's emptyDir, which holds every key and is the only place that does:
#   list     `bucket-list`: the live bucket's files, `<size><TAB><server time><TAB><key>` per line, into live.
#   pick     `restic-object`: from MANIFEST of the latest staging snapshot the `bucket/` objects whose key and server time
#            the live listing has too, one of the non-empty ones picked at random, whose bytes go through sha256sum.
#   compare  `bucket-compare`: the picked object's sha256 read from the live bucket, which must equal the snapshot's.
# Every verdict is one line without a key or content, and a failed step ends non-zero. rclone's and restic's messages
# name objects, so they are dropped and a failed command names its step and exit status. A key reaches a process only as
# the argument of restic dump in this pod and through rclone's --files-from-raw file.
# The listing's time is UTC (an image without a time zone), second precision, as MANIFEST's mtime is.
# Usage: sh restore_object.sh list|pick|compare, run by busybox sh in the rclone image and in k8up's.
set -u
# shellcheck disable=SC3040 # busybox sh, which both images run, has pipefail; a failed restic dump must fail its pipeline.
set -o pipefail
object=/object
staging=/data/backup-staging
tab="$(printf '\t')"
role="${1:-}"

# fail <message>: the step's verdict, which ends it.
fail() {
  echo "restore object: $role: $1"
  exit 1
}

# attempt <what> <command>...: runs the command with its messages dropped; a non-zero exit ends the step naming it.
attempt() {
  what="$1"
  shift
  status=0
  "$@" 2>/dev/null || status=$?
  [ "$status" = 0 ] || fail "$what failed with exit $status"
}

# list_live <file>: the bucket's files with size and server time, the key last since it may hold a tab.
list_live() {
  rclone lsf --recursive --files-only --use-server-modtime --format stp --separator "$tab" ":s3:$BUCKET" >"$1"
}

# latest_snapshot: id and time in seconds since the epoch of the newest staging snapshot, tab separated.
latest_snapshot() {
  restic --no-cache snapshots --json --path "$staging" | jq --raw-output '
    max_by(.time) | [.id, (.time | if endswith("Z") then sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601
      else error("the time is not UTC") end)] | @tsv' >"$object/snapshot"
}

# staged_objects <id>: the bucket's lines of the snapshot's MANIFEST as `<size><TAB><mtime><TAB><key>`.
staged_objects() {
  restic --no-cache dump "$1" "$staging/MANIFEST" |
    sed -n "s/^file${tab}\([0-9]*\)${tab}\([0-9]*\)${tab}bucket\/\(.*\)\$/\1${tab}\2${tab}\3/p" >"$object/staged"
}

# count_objects <snapshot time>: "<live objects older than the snapshot> <staged objects> <unchanged> <empty and unchanged>
# <staged with another size than the live one at the same key and time>", the unchanged non-empty live lines in
# unchanged. An object is unchanged when its key and its time are in both listings.
count_objects() {
  awk -F "$tab" -v snapshot="$1" -v live_file="$object/live" -v unchanged_file="$object/unchanged" '
    function after(line, count) {
      while (count-- > 0) line = substr(line, index(line, "\t") + 1)
      return line
    }
    function epoch(stamp,   year, month) {
      year = substr(stamp, 1, 4) + 0
      month = substr(stamp, 6, 2) + 0
      if (month <= 2) { year--; month += 12 }
      return (365 * year + int(year / 4) - int(year / 100) + int(year / 400) + int((153 * (month - 3) + 2) / 5) \
        + substr(stamp, 9, 2) - 1 - 719468) * 86400 + substr(stamp, 12, 2) * 3600 + substr(stamp, 15, 2) * 60 + substr(stamp, 18, 2)
    }
    FILENAME == live_file {
      version = epoch($2) "\t" after($0, 2)
      size[version] = $1
      line[version] = $0
      if (epoch($2) < snapshot) older++
      next
    }
    {
      version = $2 "\t" after($0, 2)
      total++
      if (!(version in size)) next
      if (size[version] + 0 != $1 + 0) differing++
      else if ($1 + 0 == 0) empty++
      else { unchanged++; print line[version] > unchanged_file }
    }
    END { print older + 0, total + 0, unchanged + 0, empty + 0, differing + 0 }' "$object/live" "$object/staged" >"$object/counts"
}

# dump_digest <id> <key>: the sha256 of the key's object in the snapshot; a failed dump fails the pipeline.
dump_digest() {
  restic --no-cache dump "$1" "$staging/bucket/$2" | sha256sum | cut -c1-64 >"$object/digest"
}

# hash_live: the sha256 of the picked object, read from the bucket; its output names the key, so it stays in a file.
hash_live() {
  rclone hashsum sha256 --download --files-from-raw "$object/key" ":s3:$BUCKET" >"$object/live.sum"
}

list_role() {
  attempt "the listing" list_live "$object/live"
}

pick_role() {
  attempt "the snapshot lookup" latest_snapshot
  IFS="$tab" read -r id epoch <"$object/snapshot"
  attempt "the MANIFEST dump" staged_objects "$id"
  attempt "the count" count_objects "$epoch"
  read -r older total unchanged empty differing <"$object/counts"
  if [ "$total" = 0 ]; then
    [ "$older" = 0 ] || fail "the latest snapshot holds no object of the bucket, which lists $older older than it"
    echo "restore object: pick: none compared, the latest snapshot holds no object of the bucket"
    return
  fi
  [ "$differing" = 0 ] || fail "$differing staged objects have another size than the bucket's at the same server time"
  [ $((unchanged + empty)) != 0 ] || fail "none of the $total objects of the latest snapshot is unchanged in the bucket"
  if [ "$unchanged" = 0 ]; then
    echo "restore object: pick: none compared, only empty objects are unchanged ($empty)"
    return
  fi
  number="$(awk -v count="$unchanged" 'BEGIN { srand(); print int(rand() * count) + 1 }')"
  sed -n "${number}p" "$object/unchanged" >"$object/picked"
  key="$(cut -f3- "$object/picked")"
  attempt "the dump of the object" dump_digest "$id" "$key"
}

compare_role() {
  if [ ! -e "$object/picked" ]; then
    echo "restore object: compare: nothing picked"
    return
  fi
  cut -f3- "$object/picked" >"$object/key"
  attempt "the hash" hash_live
  attempt "the second listing" list_live "$object/after"
  status=0
  grep -qxFf "$object/picked" "$object/after" 2>/dev/null || status=$?
  [ "$status" != 2 ] || fail "the second listing cannot be read"
  [ "$status" = 0 ] || fail "the object changed during the test"
  live_digest="$(cut -c1-64 "$object/live.sum")"
  [ "${#live_digest}" = 64 ] || fail "the bucket gave no hash"
  IFS="$tab" read -r id _ <"$object/snapshot"
  IFS="$tab" read -r size stamp _ <"$object/picked"
  [ "$live_digest" = "$(cat "$object/digest")" ] ||
    fail "the object of $size bytes, server time $stamp, differs from its copy in the snapshot $id"
  read -r _ _ unchanged _ <"$object/counts"
  echo "restore object: compare: one object equals its copy in the snapshot $id, of $unchanged unchanged"
}

case "$role" in
  list) list_role ;;
  pick) pick_role ;;
  compare) compare_role ;;
  *) fail "no such role" ;;
esac
