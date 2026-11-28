#!/usr/bin/env bash
# The claim and bucket half of `mise run db:load-dump` for a layer that declares a claim: finds the staging snapshot
# whose MANIFEST holds the dump's sha256, then restores that one snapshot's claim and bucket inside the namespace, in the
# Pod db-load-snapshot, never through this machine. Each step is one process through kubectl exec. It prints names,
# counts, bytes and outcomes, never a file name: restic's and rclone's messages stay in the Pod, and every line of its
# own goes to stderr, so that stdout holds only the result a caller reads.
# Usage: scripts/load_snapshot.sh declares-bucket <namespace>                prints true or false
#        scripts/load_snapshot.sh source <namespace> <dump sha256>           prints "<snapshot> <scratch bytes>"
#        scripts/load_snapshot.sh start <namespace> <claim> <scratch bytes> <true|false: declares-bucket's answer>
#        scripts/load_snapshot.sh restore-bucket|restore-claim <namespace> <snapshot>
#        scripts/load_snapshot.sh count <namespace>                          prints "<objects> <bytes>"
#        scripts/load_snapshot.sh empty|copy <namespace>
#        scripts/load_snapshot.sh check <namespace> <snapshot>
#        scripts/load_snapshot.sh stop <namespace>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
say() { echo "db:load-dump: $1" >&2; }
fail() { echo "db:load-dump: $1" >&2; exit 1; }
here="$(dirname "${BASH_SOURCE[0]}")"
shape="$here/load_snapshot.yaml"
loader=db-load-snapshot
source_pod=db-load-source
block_bytes=4096
margin_bytes=$((64 * 1024 * 1024))

# The scripts below run in the Pod's containers, by sh, with the step's name as $0 and its arguments after it.

# The newest staging snapshot whose MANIFEST holds the dump's sha256 ($1), its trees' counts, bytes and directory
# prefixes, and the scratch filesystem's free and total bytes; exit 3 when no snapshot holds the dump, 2 when the
# repository cannot be read or none of its snapshots can be dumped.
read -r -d '' source_script <<'SCRIPT' || true
staging=/data/backup-staging
snapshots="$(restic --no-cache snapshots --json --path "$staging")" || exit 2
ids="$(printf '%s' "$snapshots" | jq --raw-output 'sort_by(.time) | reverse | .[].id')" || exit 2
found= tried=0 unread=0
for id in $ids; do
  tried=$((tried + 1))
  restic --no-cache dump "$id" "$staging/MANIFEST" >/restore/MANIFEST 2>/dev/null || { unread=$((unread + 1)); continue; }
  [ "$(awk -F'\t' '$1 == "dump" { print $2; exit }' /restore/MANIFEST)" = "$1" ] || continue
  found="$id"
  break
done
if [ -z "$found" ]; then
  [ "$tried" = 0 ] || [ "$unread" -lt "$tried" ] || exit 2
  exit 3
fi
echo "snapshot $found"
awk -F'\t' '
  $1 == "file" {
    tree = $4; sub(/\/.*/, "", tree)
    objects[tree]++; bytes[tree] += $2
    parts = split($4, part, "/"); prefix = part[1]
    for (i = 2; i < parts; i++) {
      prefix = prefix "/" part[i]
      if (!(prefix in seen)) { seen[prefix] = 1; prefixes[tree]++ }
    }
  }
  END {
    printf "bucket %.0f %.0f %.0f\n", objects["bucket"], bytes["bucket"], prefixes["bucket"]
    printf "claim %.0f %.0f %.0f\n", objects["files"], bytes["files"], prefixes["files"]
  }' /restore/MANIFEST
rm -f /restore/MANIFEST
df -Pk /restore | awk 'NR == 2 { printf "filesystem %.0f %.0f\n", $4 * 1024, $2 * 1024 }'
SCRIPT

# One tree ($2: bucket or files) of the snapshot ($1): into the scratch for the bucket, into the claim for the files,
# which --delete makes equal to the snapshot's; then the tree's file lines, listed as MANIFEST lists them, against the
# snapshot's own. Prints "<files> <bytes> <differing lines>".
read -r -d '' restore_script <<'SCRIPT' || true
snapshot="$1" tree="$2" staging=/data/backup-staging delete=
if [ "$tree" = files ]; then root=/load delete=--delete; else root=/restore; fi
restic --no-cache restore "$snapshot:$staging/$tree" --target "$root/$tree" $delete --verify >/dev/null 2>&1 || exit 1
restic --no-cache dump "$snapshot" "$staging/MANIFEST" >/restore/MANIFEST 2>/dev/null || exit 1
awk -F'\t' -v tree="$tree" '$1 == "file" && index($4, tree "/") == 1' /restore/MANIFEST >"/restore/$tree.expected"
(cd "$root" && sh /etc/stage/stage_files.sh listing "$tree") >"/restore/$tree.actual" || exit 1
differing="$(LC_ALL=C sort -m "/restore/$tree.expected" "/restore/$tree.actual" | uniq -u | wc -l)"
awk -F'\t' -v differing="$differing" '{ bytes += $2 } END { printf "%.0f %.0f %.0f\n", NR, bytes, differing }' \
  "/restore/$tree.actual"
rm -f /restore/MANIFEST "/restore/$tree.expected" "/restore/$tree.actual"
SCRIPT

# The rclone steps read the bucket with the app's key. size prints "<objects> <bytes>".
read -r -d '' size_function <<'SCRIPT' || true
bucket_size() {
  rclone size ":s3:$BUCKET" --json 2>/dev/null | sed -n 's/.*"count": *\([0-9]*\).*"bytes": *\([0-9]*\).*/\1 \2/p'
}
SCRIPT
read -r -d '' count_body <<'SCRIPT' || true
size="$(bucket_size)"
[ -n "$size" ] || exit 1
echo "$size"
SCRIPT
# The bucket is kept; what it holds must count 0 afterwards.
read -r -d '' empty_body <<'SCRIPT' || true
rclone delete ":s3:$BUCKET" >/dev/null 2>&1 || exit 1
size="$(bucket_size)"
[ "${size%% *}" = 0 ] || exit 1
SCRIPT
read -r -d '' copy_body <<'SCRIPT' || true
rclone copy /restore/bucket ":s3:$BUCKET" >/dev/null 2>&1
SCRIPT
# The scratch against the bucket by content: every line of the combined list that does not start with "= " differs.
# rclone exits 1 for differences and for some errors, 2 and above for the rest: only a list that names a difference
# excuses a 1.
read -r -d '' check_body <<'SCRIPT' || true
rm -f /tmp/check
checked=0
rclone check /restore/bucket ":s3:$BUCKET" --download --combined /tmp/check >/dev/null 2>&1 || checked=$?
[ "$checked" -le 1 ] || exit 1
differing=0
[ ! -f /tmp/check ] || differing="$(grep -vc '^= ' /tmp/check || true)"
[ "$checked" = 0 ] || [ "$differing" != 0 ] || exit 1
size="$(bucket_size)"
[ -n "$size" ] || exit 1
echo "${size%% *} ${size##* } $differing"
SCRIPT
count_script="$size_function"$'\n'"$count_body"
empty_script="$size_function"$'\n'"$empty_body"
copy_script="$copy_body"
check_script="$size_function"$'\n'"$check_body"

stop() { kubectl --namespace "$1" delete pod "$loader" "$source_pod" --ignore-not-found --wait >/dev/null; }

# The PreBackupPod of the layer's claim as JSON.
pre_backup_pod() { kubectl --namespace "$1" get prebackuppod.k8up.io files --output json; }

# bucket_container_of <PreBackupPod JSON>: its container `bucket` as JSON, null where the layer has none.
bucket_container_of() {
  yq --input-format json --output-format json '[.spec.pod.spec.containers[] | select(.name == "bucket")] | .[0]' <<<"$1"
}

# declares <bucket container JSON>: true where the layer has a bucket container, else false.
declares() { if [ "$1" = null ]; then echo false; else echo true; fi; }

declares_bucket() {
  local pre_pod
  pre_pod="$(pre_backup_pod "$1")" || fail "cannot read the PreBackupPod files in $1; nothing changed"
  declares "$(bucket_container_of "$pre_pod")"
}

# create_pod <namespace> <pod> <manifest>: the Pod, once it is Ready.
create_pod() {
  kubectl --namespace "$1" create --filename - <<<"$3" >/dev/null || { echo "db:load-dump: could not start the Pod $2 in $1" >&2; return 1; }
  kubectl --namespace "$1" wait "pod/$2" --for=condition=Ready --timeout=5m >/dev/null ||
    { echo "db:load-dump: the Pod $2 is not Ready after 5 minutes" >&2; return 1; }
}

# field <output> <key> <position>: the position'th word of the output's line that starts with the key.
field() { awk -v key="$2" -v position="$3" '$1 == key { print $position }' <<<"$1"; }

# source <namespace> <dump sha256>: starts the Pod that reads the repository with the credentials of the restore test
# and no key of the object store, finds the snapshot and refuses a load the node cannot hold, with nothing changed.
source_step() {
  local namespace="$1" dump_sha256="$2" manifest output status=0 node allocatable margin
  local snapshot bucket_objects bucket_bytes bucket_prefixes claim_files claim_bytes claim_prefixes free total scratch need
  stop "$namespace" || fail "cannot delete an earlier Pod $source_pod or $loader in $namespace; nothing changed"
  trap "stop '$namespace' || true" EXIT
  manifest="$("$here/restic_dump_pod.sh" "$namespace" "$source_pod" "$(yq '.hold' "$shape")")" ||
    fail "cannot read the CronJob restore-test in $namespace; nothing changed"
  create_pod "$namespace" "$source_pod" "$manifest" || fail "the Pod $source_pod did not start; nothing changed"
  output="$(kubectl --namespace "$namespace" exec "$source_pod" --container restic -- \
    sh -c "$source_script" source "$dump_sha256")" || status=$?
  case "$status" in
    0) ;;
    3) fail "the dump is of no staging snapshot of $namespace; mise run backup:fetch $namespace <file> writes the latest; nothing changed" ;;
    *) fail "cannot read the staging snapshots of $namespace (exit $status); nothing changed" ;;
  esac
  snapshot="$(field "$output" snapshot 2)"
  bucket_objects="$(field "$output" bucket 2)" bucket_bytes="$(field "$output" bucket 3)" bucket_prefixes="$(field "$output" bucket 4)"
  claim_files="$(field "$output" claim 2)" claim_bytes="$(field "$output" claim 3)" claim_prefixes="$(field "$output" claim 4)"
  free="$(field "$output" filesystem 2)" total="$(field "$output" filesystem 3)"
  say "the dump is of the staging snapshot $snapshot: the claim holds $claim_files files, $claim_bytes bytes; the bucket holds $bucket_objects objects, $bucket_bytes bytes"
  node="$(kubectl --namespace "$namespace" get pod "$source_pod" --output jsonpath='{.spec.nodeName}')" ||
    fail "cannot read the node of the Pod $source_pod; nothing changed"
  allocatable="$(kubectl get node "$node" --output jsonpath='{.status.allocatable.ephemeral-storage}')" ||
    fail "cannot read the allocatable storage of the node; nothing changed"
  # The scratch holds the bucket's files and one block for each of its files and directories, beside restic's working
  # files. Garage's new blocks (the bucket's bytes again) and the claim's new files, counted beside its old ones, since
  # the delete frees them only late, add to what the node must hold.
  scratch=$((bucket_bytes + (bucket_objects + bucket_prefixes) * block_bytes + margin_bytes))
  need=$((scratch + bucket_bytes + claim_bytes + (claim_files + claim_prefixes) * block_bytes))
  status=0
  margin="$(sh "$here/../infrastructure/postgres/backup/files/scripts/stage_files.sh" room "$free" "$total" "$allocatable" "$need")" ||
    status=$?
  case "$status" in
    0) ;;
    1) fail "the load needs $need bytes beside the kubelet's eviction margin of $margin, and the node has $free of $total bytes free; nothing changed" ;;
    *) fail "the allocatable storage of the node is missing or unreadable; nothing changed" ;;
  esac
  say "the node has $free of $total bytes free for a load of $need bytes beside an eviction margin of $margin"
  echo "$snapshot $scratch"
}

# start <namespace> <claim> <scratch bytes> <bucket>: the loader Pod: the owner's Pod with restic's container at the
# reading uid of the PreBackupPod, the claim writable, and where the layer declares a bucket the PreBackupPod's rclone
# container with the app's key. <bucket> is declares-bucket's answer, which the caller's steps follow; a PreBackupPod
# that disagrees with it fails.
start() {
  local namespace="$1" claim="$2" scratch="$3" declared="$4" pre_pod container manifest
  stop "$namespace" || fail "cannot delete an earlier Pod $loader in $namespace"
  pre_pod="$(pre_backup_pod "$namespace")" || fail "cannot read the PreBackupPod files in $namespace"
  container="$(bucket_container_of "$pre_pod")"
  [ "$declared" = "$(declares "$container")" ] ||
    fail "the PreBackupPod files of $namespace changed its bucket container since the plan was made; nothing loaded"
  # shellcheck disable=SC2016 # $shape and $bucket are yq's variables
  manifest="$("$here/restic_dump_pod.sh" "$namespace" "$loader" "$(yq '.hold' "$shape")" |
    SHAPE="$shape" CLAIM="$claim" SCRATCH="$scratch" BUCKET_CONTAINER="$container" \
    USER_ID="$(yq --input-format json '.spec.pod.spec.securityContext.runAsUser' <<<"$pre_pod")" yq --output-format json '
      load(strenv(SHAPE)) as $shape | env(BUCKET_CONTAINER) as $bucket |
      . * $shape.pod |
      .spec.securityContext.runAsUser = env(USER_ID) | .spec.securityContext.runAsGroup = env(USER_ID) |
      .spec.containers[0].volumeMounts += $shape.restic.container.volumeMounts |
      .spec.volumes += $shape.restic.volumes |
      (.spec.volumes[] | select(.name == "claim") | .persistentVolumeClaim.claimName) = strenv(CLAIM) |
      (.spec.volumes[] | select(.name == "restore") | .emptyDir.sizeLimit) = strenv(SCRATCH) |
      (if $bucket == null then . else
        .spec.containers += [$shape.rclone.container * {
          "image": $bucket.image, "securityContext": $bucket.securityContext, "command": ["sh", "-c", $shape.hold],
          "env": (($bucket.env | map(select(.name != $shape.rclone.env[0].name))) + $shape.rclone.env)}] |
        .spec.volumes += $shape.rclone.volumes end)')" ||
    fail "cannot build the loader Pod of $namespace"
  create_pod "$namespace" "$loader" "$manifest"
  say "the loader $loader of $namespace is Ready"
}

# step_failed <namespace> <step>: names the failed step, and the backstop when the Pod's deadline ended it.
step_failed() {
  local reason hours
  reason="$(kubectl --namespace "$1" get pod "$loader" --output jsonpath='{.status.reason}' 2>/dev/null || true)"
  hours=$(($(yq '.pod.spec.activeDeadlineSeconds' "$shape") / 3600))
  if [ "$reason" = DeadlineExceeded ]; then
    echo "db:load-dump: the loader $loader reached its $hours-hour backstop during $2" >&2
  else
    echo "db:load-dump: the step $2 failed in the loader $loader of $1" >&2
  fi
}

# in_loader <namespace> <step> <container> <script> [argument]...: the script as one process of the container; its
# standard output is the result, and a failure names the step.
in_loader() {
  local namespace="$1" step="$2" container="$3" script="$4"
  shift 4
  kubectl --namespace "$namespace" exec "$loader" --container "$container" -- sh -c "$script" "$step" "$@" ||
    { step_failed "$namespace" "$step"; return 1; }
}

# restored <namespace> <step> <snapshot> <tree> <noun>: the restore of one tree and its compare with MANIFEST's lines.
restored() {
  local namespace="$1" step="$2" snapshot="$3" tree="$4" noun="$5" result files bytes differing
  result="$(in_loader "$namespace" "$step" restic "$restore_script" "$snapshot" "$tree")" || return 1
  read -r files bytes differing <<<"$result"
  [ "$differing" = 0 ] || { echo "db:load-dump: $noun differs from the snapshot $snapshot in $differing lines of its $files files, $bytes bytes" >&2; return 1; }
  say "$noun equals the snapshot $snapshot: $files files, $bytes bytes, 0 differing"
}

case "${1:-}" in
  declares-bucket) declares_bucket "$2" ;;
  source) source_step "$2" "$3" ;;
  start) start "$2" "$3" "$4" "$5" ;;
  restore-bucket) restored "$2" restore-bucket "$3" bucket "the restored bucket copy" ;;
  restore-claim) restored "$2" restore-claim "$3" files "the claim of $2" ;;
  count) in_loader "$2" count rclone "$count_script" ;;
  empty) in_loader "$2" empty rclone "$empty_script" ;;
  copy) in_loader "$2" copy rclone "$copy_script" ;;
  check)
    result="$(in_loader "$2" check rclone "$check_script")" || exit 1
    read -r objects bytes differing <<<"$result"
    [ "$differing" = 0 ] || fail "the bucket $2 differs from the snapshot $3 in $differing entries"
    say "the bucket $2 equals the snapshot $3: $objects objects, $bytes bytes, 0 differing" ;;
  stop) stop "$2" ;;
  *) fail "unknown step '${1:-}'" ;;
esac
