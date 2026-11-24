#!/usr/bin/env bash
# Drive apps/speech-runtime/bridge/scripts/speech_bridge.sh, the script of both Jobs of a speech GPU release, against a fake kubectl
# that holds the objects the script reads, for the outcomes the cluster cannot arrange. Mode `up` raises the small image
# to one pod and waits until it is Ready only while speech holds the card (the GPU image at one pod and not yet at the
# release's image), leaves a count above zero alone, and changes nothing without a GPU Deployment, with the GPU image at
# another count or at the release's image. Mode `settle` waits until the GPU Deployment runs the release's image, has
# observed its generation and has one updated, Ready pod, then lowers the small image from one to none, unless the GPU
# image stands off one pod (also while it waits), was created after the Job bridge, a newer release is pending in the Job
# bridge, or `gpu:use` moved the small image off one pod; a missing Job bridge fails it. A scale carries the count it
# expects, a refusal reads the counts again and decides once more, three refusals fail, and no call scales the GPU image.
# Usage: MISE_DISABLE_TOOLS=kubectl KUBECONFIG=/nonexistent mise exec -- tests/speech_runtime/bridge_raises_the_cpu_voice_only_while_speech_holds_the_card.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
bridge_script="$repository_root/apps/speech-runtime/bridge/scripts/speech_bridge.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
state="$work_directory/state"
calls="$work_directory/calls"
mkdir "$fake_bin" "$state"

# The fake kubectl holds each object as a directory of its name in FAKE_STATE, and each field as a file of the field's
# JSONPath. `get` prints the field, `wait` succeeds when the field equals the value (else it times out, as the real one
# does), `scale` is refused when its --current-replicas no longer holds. Before each `wait`, `scale` and read of an object
# that may be missing, the next line of the file wait_effects, scale_effects or read_effects in FAKE_STATE happens first:
# assignments `object|field|value` split by `;`, which stand for the pods and for `gpu:use`. The file refuse_scales holds a
# number of scales that are refused whatever the count, as when it moves and moves back between the read and the scale; the
# file refuse_waits holds the text of a wait that is refused for another reason than its timeout. The calls are recorded.
cat >"$work_directory/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -u
echo "$*" >>"$FAKE_CALLS"
happen() {
  local file="$FAKE_STATE/$1" line assignment name path value
  [ -s "$file" ] || return 0
  line="$(sed -n 1p "$file")"
  sed -i 1d "$file"
  IFS=';' read -ra assignments <<<"$line"
  for assignment in "${assignments[@]}"; do
    IFS='|' read -r name path value <<<"$assignment"
    if [ -z "$name" ]; then continue; fi
    if [ -n "$value" ]; then printf '%s' "$value" >"$FAKE_STATE/$name/$path"; else rm -f "$FAKE_STATE/$name/$path"; fi
  done
}
field_of() { cat "$FAKE_STATE/$1/$2" 2>/dev/null || true; }
command="$1"
shift
object="" ignore_missing="" jsonpath="" condition="" timeout_given="" current="" replicas=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ignore-not-found) ignore_missing=1 ;;
    --output) jsonpath="$2"; shift ;;
    --for=jsonpath=*) condition="${1#--for=jsonpath=}" ;;
    --timeout=*) timeout_given=1 ;;
    --current-replicas=*) current="${1#*=}" ;;
    --replicas=*) replicas="${1#*=}" ;;
    */*) object="${1#*/}" ;;
    *) echo "the fake kubectl knows no argument $1" >&2; exit 99 ;;
  esac
  shift
done
case "$command" in
  get)
    [ -z "$ignore_missing" ] || happen read_effects
    if [ ! -d "$FAKE_STATE/$object" ]; then
      [ -n "$ignore_missing" ] && exit 0
      echo "Error from server (NotFound): $object not found" >&2
      exit 1
    fi
    path="${jsonpath#jsonpath=\{}"
    field_of "$object" "${path%\}}"
    ;;
  wait)
    [ -n "$timeout_given" ] || { echo "a wait without --timeout ends after 30 seconds" >&2; exit 99; }
    happen wait_effects
    if [ -s "$FAKE_STATE/refuse_waits" ]; then cat "$FAKE_STATE/refuse_waits" >&2; exit 1; fi
    path="${condition%\}=*}"
    path="${path#\{}"
    if [ "$(field_of "$object" "$path")" = "${condition##*\}=}" ]; then echo "condition met"; exit 0; fi
    echo "error: timed out waiting for the condition" >&2
    exit 1
    ;;
  scale)
    happen scale_effects
    refusals="$(cat "$FAKE_STATE/refuse_scales" 2>/dev/null || echo 0)"
    if [ "$refusals" -gt 0 ]; then
      echo "$((refusals - 1))" >"$FAKE_STATE/refuse_scales"
      echo "error: Precondition failed: the replicas moved" >&2
      exit 1
    fi
    [ -n "$current" ] || { echo "an unconditional scale of $object" >&2; exit 99; }
    if [ "$(field_of "$object" .spec.replicas)" != "$current" ]; then
      echo "error: Precondition failed: replicas is not $current" >&2
      exit 1
    fi
    printf '%s' "$replicas" >"$FAKE_STATE/$object/.spec.replicas"
    ;;
  *) echo "the fake kubectl knows no command $command" >&2; exit 99 ;;
esac
FAKE
chmod +x "$work_directory/kubectl"
ln -s ../kubectl "$fake_bin/kubectl"
# A wait that fails at once is retried after a pause, which the cell does not take.
printf '#!/bin/sh\n' >"$fake_bin/sleep"
chmod +x "$fake_bin/sleep"

old_image=ghcr.io/example/speech:1.0-gpu@sha256:aaaa
release_image=ghcr.io/example/speech:2.0-gpu@sha256:bbbb
newer_image=ghcr.io/example/speech:3.0-gpu@sha256:cccc

# set_field <object> <JSONPath> <value>
set_field() { printf '%s' "$3" >"$state/$1/$2"; }

# cluster <small replicas> <GPU replicas>: the objects of a GPU release that is about to roll. The GPU Deployment runs the
# old image, was created before the Job bridge, whose release is the one of the Job asked for.
cluster() {
  rm -rf "$state"
  mkdir -p "$state/speech-runtime" "$state/speech-runtime-gpu" "$state/bridge"
  set_field speech-runtime .spec.replicas "$1"
  set_field speech-runtime .status.readyReplicas "$1"
  set_field speech-runtime-gpu .spec.replicas "$2"
  set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$old_image"
  set_field speech-runtime-gpu .metadata.creationTimestamp 2026-11-01T10:00:00Z
  set_field speech-runtime-gpu .metadata.generation 3
  set_field speech-runtime-gpu .status.observedGeneration 3
  set_field speech-runtime-gpu .status.updatedReplicas 1
  set_field speech-runtime-gpu .status.readyReplicas 1
  set_field bridge .spec.template.metadata.annotations.gpu-image "$release_image"
  set_field bridge .metadata.creationTimestamp 2026-11-24T10:00:00Z
}

# refuse_scales <n>: the next n scales are refused.
refuse_scales() { echo "$1" >"$state/refuse_scales"; }

# happens <wait_effects|scale_effects|read_effects> <line>...: the lines that happen before the file's calls, one for each.
happens() {
  local file="$state/$1"
  shift
  printf '%s\n' "$@" >"$file"
}

# run_bridge <mode>: runs the script as the Job does and leaves its status in `status` and its lines in `output`.
run_bridge() {
  : >"$calls"
  status=0
  output="$(PATH="$fake_bin:$PATH" FAKE_CALLS="$calls" FAKE_STATE="$state" GPU_IMAGE="$release_image" READY_SECONDS=600 \
    MISE_DISABLE_TOOLS=kubectl KUBECONFIG=/nonexistent timeout 20 sh "$bridge_script" "$1" 2>&1)" || status=$?
}

# changing_calls: the recorded scales and waits, which carry the order the script keeps.
changing_calls() { grep -E '^(scale|wait) ' "$calls" || true; }

# expect_calls <description> <call fragment>...: the scales and waits contain the fragments in this order and nothing else.
expect_calls() {
  local description="$1" index=0 recorded
  shift
  [ "$(changing_calls | wc -l)" -eq "$#" ] ||
    fail "$description: expected $# scales and waits, got $(changing_calls | wc -l): $(changing_calls | tr '\n' ';')"
  while IFS= read -r recorded; do
    index=$((index + 1))
    [[ "$recorded" == *"${!index}"* ]] || fail "$description: call $index is '$recorded', expected one with '${!index}'"
  done < <(changing_calls)
}

# expect_status <description> <0|failed>
expect_status() {
  if [ "$2" = 0 ]; then
    [ "$status" -eq 0 ] || fail "$1 ended $status: $output"
  else
    [ "$status" -ne 0 ] || fail "$1 ended 0: $output"
  fi
  if grep '^scale' "$calls" | grep -q 'speech-runtime-gpu'; then fail "$1 scaled the GPU image: $(changing_calls | tr '\n' ';')"; fi
  if grep -q '^scale' "$calls" && grep '^scale' "$calls" | grep -qv -e '--current-replicas='; then fail "$1 made a scale without its expected count"; fi
}

# expect_replicas <description> <small replicas>
expect_replicas() {
  [ "$(cat "$state/speech-runtime/.spec.replicas")" = "$2" ] ||
    fail "$1: the small image stands at $(cat "$state/speech-runtime/.spec.replicas"), not $2"
}

# expect_says <description> <text>
expect_says() { [[ "$output" == *"$2"* ]] || fail "$1 did not say '$2': $output"; }

# up: speech holds the card, so the small image rises from none to one and the script waits until it is Ready.
cluster 0 1
happens wait_effects "speech-runtime|.status.readyReplicas|1"
run_bridge up
expect_status "up with speech holding the card" 0
expect_calls "up with speech holding the card" \
  "scale deployment/speech-runtime --current-replicas=0 --replicas=1" \
  "wait deployment/speech-runtime --for=jsonpath={.status.readyReplicas}=1 --timeout=600s"
expect_replicas "up with speech holding the card" 1

# up: the card is songmaker's or free, so nothing changes and it says so.
for gpu_replicas in 0 2; do
  cluster 2 "$gpu_replicas"
  run_bridge up
  expect_status "up with the GPU image at $gpu_replicas" 0
  expect_calls "up with the GPU image at $gpu_replicas"
  expect_replicas "up with the GPU image at $gpu_replicas" 2
  expect_says "up with the GPU image at $gpu_replicas" "stands at $gpu_replicas"
done

# up: the first apply holds no GPU Deployment.
cluster 0 1
rm -r "$state/speech-runtime-gpu"
run_bridge up
expect_status "up on a first apply" 0
expect_calls "up on a first apply"
expect_replicas "up on a first apply" 0
expect_says "up on a first apply" "first apply"

# up: the GPU Deployment already runs the release's image, as when the Job is made again by a changed script.
cluster 0 1
set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$release_image"
run_bridge up
expect_status "up at the release's image" 0
expect_calls "up at the release's image"
expect_replicas "up at the release's image" 0
expect_says "up at the release's image" "already runs"

# up: a small image at one pod, as on a fresh cluster, is not scaled, only waited for.
cluster 1 1
run_bridge up
expect_status "up with the small image at one pod" 0
expect_calls "up with the small image at one pod" "wait deployment/speech-runtime --for=jsonpath={.status.readyReplicas}=1"

# up: the wait is for the count the small image stands at.
cluster 2 1
run_bridge up
expect_status "up with the small image at two pods" 0
expect_calls "up with the small image at two pods" "wait deployment/speech-runtime --for=jsonpath={.status.readyReplicas}=2"

# up: a pod that never turns Ready fails the Job.
cluster 0 1
run_bridge up
expect_status "up with a small pod that stays not Ready" failed
expect_calls "up with a small pod that stays not Ready" "scale" "wait deployment/speech-runtime"

# up: `gpu:use` set the small image to two between the read and the scale, so the scale is refused, the counts are read
# again and the script only waits for the two pods.
cluster 0 1
happens scale_effects "speech-runtime|.spec.replicas|2"
happens wait_effects "speech-runtime|.status.readyReplicas|2"
run_bridge up
expect_status "up after a refused scale" 0
expect_calls "up after a refused scale" \
  "scale deployment/speech-runtime --current-replicas=0 --replicas=1" \
  "wait deployment/speech-runtime --for=jsonpath={.status.readyReplicas}=2"
expect_replicas "up after a refused scale" 2

# up: three refusals fail the Job.
cluster 0 1
refuse_scales 3
run_bridge up
expect_status "up refused three times" failed
[ "$(grep -c '^scale' "$calls")" -eq 3 ] || fail "up refused three times made $(grep -c '^scale' "$calls") scales, not three"
if grep -q '^wait' "$calls"; then fail "up refused three times went on to wait"; fi

# settle, the usual roll: the GPU Deployment gets the release's image, observes its generation, runs one updated pod,
# which turns Ready, and only then the small image goes from one to none.
cluster 1 1
set_field speech-runtime-gpu .status.updatedReplicas 0
happens wait_effects \
  "speech-runtime-gpu|.spec.template.spec.containers[0].image|$release_image;speech-runtime-gpu|.metadata.generation|4" \
  "speech-runtime-gpu|.status.observedGeneration|4" \
  "speech-runtime-gpu|.status.updatedReplicas|1;speech-runtime-gpu|.status.readyReplicas|0" \
  "speech-runtime-gpu|.status.readyReplicas|1"
run_bridge settle
expect_status "settle after a roll" 0
expect_calls "settle after a roll" \
  "wait deployment/speech-runtime-gpu --for=jsonpath={.spec.template.spec.containers[0].image}=$release_image" \
  "wait deployment/speech-runtime-gpu --for=jsonpath={.status.observedGeneration}=4" \
  "wait deployment/speech-runtime-gpu --for=jsonpath={.status.updatedReplicas}=1" \
  "wait deployment/speech-runtime-gpu --for=jsonpath={.status.readyReplicas}=1" \
  "scale deployment/speech-runtime --current-replicas=1 --replicas=0"
expect_replicas "settle after a roll" 0
longest_wait="$(changing_calls | sed -n 's/^wait .*--timeout=\([0-9]*\)s.*/\1/p' | sort -n | tail -1)"
{ [ -n "$longest_wait" ] && [ "$longest_wait" -le 60 ]; } || fail "a wait of settle runs ${longest_wait:-without a timeout}, longer than one round of 60 seconds"

# settle: the Deployment is already at the release's image and Ready, so it does not wait.
cluster 1 1
set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$release_image"
run_bridge settle
expect_status "settle at a Ready release" 0
expect_calls "settle at a Ready release" "scale deployment/speech-runtime --current-replicas=1 --replicas=0"
expect_replicas "settle at a Ready release" 0

# settle: the card is songmaker's or free, so nothing is settled, whatever the small image runs.
for gpu_replicas in 0 2; do
  cluster 2 "$gpu_replicas"
  run_bridge settle
  expect_status "settle with the GPU image at $gpu_replicas" 0
  expect_calls "settle with the GPU image at $gpu_replicas"
  expect_replicas "settle with the GPU image at $gpu_replicas" 2
done

# settle: the GPU Deployment was created after the Job bridge, as on a first apply, so the counts stay at their default.
cluster 1 1
set_field speech-runtime-gpu .metadata.creationTimestamp 2026-11-24T10:00:30Z
run_bridge settle
expect_status "settle on a first apply" 0
expect_calls "settle on a first apply"
expect_replicas "settle on a first apply" 1
expect_says "settle on a first apply" "first apply"

# settle: `gpu:use songs` took the GPU image to none while it waited, so the wait ends and the counts are decided again.
cluster 1 1
happens wait_effects "speech-runtime-gpu|.spec.replicas|0;speech-runtime|.spec.replicas|2"
run_bridge settle
expect_status "settle while gpu:use gives the card away" 0
expect_calls "settle while gpu:use gives the card away" "wait deployment/speech-runtime-gpu"
expect_replicas "settle while gpu:use gives the card away" 2

# settle: `gpu:use songs` and then `gpu:use speech` moved the GPU image off one pod and back to one before the next decision,
# so it decides again from the counts, finds the roll done and lowers the small image.
cluster 1 1
happens read_effects "" "speech-runtime-gpu|.spec.replicas|0" \
  "speech-runtime-gpu|.spec.replicas|1;speech-runtime-gpu|.spec.template.spec.containers[0].image|$release_image"
run_bridge settle
expect_status "settle while gpu:use takes the card away and gives it back" 0
expect_calls "settle while gpu:use takes the card away and gives it back" "scale deployment/speech-runtime --current-replicas=1 --replicas=0"
expect_replicas "settle while gpu:use takes the card away and gives it back" 0
expect_says "settle while gpu:use takes the card away and gives it back" "moved while waiting"

# settle: a wait refused for another reason than its timeout fails the Job at once, not at its deadline.
cluster 1 1
printf 'Error from server (Forbidden): deployments.apps is forbidden\n' >"$state/refuse_waits"
run_bridge settle
expect_status "settle with a refused wait" failed
expect_calls "settle with a refused wait" "wait deployment/speech-runtime-gpu"
expect_says "settle with a refused wait" "Forbidden"
expect_replicas "settle with a refused wait" 1

# settle: a newer release is pending in the Job bridge, whose settle lowers the small image, so this one leaves it up.
cluster 1 1
set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$release_image"
set_field bridge .spec.template.metadata.annotations.gpu-image "$newer_image"
run_bridge settle
expect_status "settle with a newer release pending" 0
expect_calls "settle with a newer release pending"
expect_replicas "settle with a newer release pending" 1
expect_says "settle with a newer release pending" "pending"

# settle: the Job bridge is gone, which it cannot judge the order by.
cluster 1 1
set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$release_image"
rm -r "$state/bridge"
run_bridge settle
expect_status "settle without the Job bridge" failed
expect_calls "settle without the Job bridge"
expect_replicas "settle without the Job bridge" 1

# settle: `gpu:use` set the small image to two, so it is left alone.
cluster 2 1
set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$release_image"
run_bridge settle
expect_status "settle with the small image set by gpu:use" 0
expect_calls "settle with the small image set by gpu:use"
expect_replicas "settle with the small image set by gpu:use" 2
expect_says "settle with the small image set by gpu:use" "gpu:use"

# settle: `gpu:use` set the small image to two between the read and the scale, so the scale is refused, the count is read
# again and the script leaves it.
cluster 1 1
set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$release_image"
happens scale_effects "speech-runtime|.spec.replicas|2"
run_bridge settle
expect_status "settle after a refused scale" 0
expect_calls "settle after a refused scale" "scale deployment/speech-runtime --current-replicas=1 --replicas=0"
expect_replicas "settle after a refused scale" 2

# settle: a refusal and then a count that holds still lowers it, and three refusals fail.
cluster 1 1
set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$release_image"
refuse_scales 1
run_bridge settle
expect_status "settle after a refusal and a held count" 0
[ "$(grep -c '^scale' "$calls")" -eq 2 ] || fail "settle after a refusal made $(grep -c '^scale' "$calls") scales, not two"
expect_replicas "settle after a refusal and a held count" 0
cluster 1 1
set_field speech-runtime-gpu .spec.template.spec.containers[0].image "$release_image"
refuse_scales 3
run_bridge settle
expect_status "settle refused three times" failed
[ "$(grep -c '^scale' "$calls")" -eq 3 ] || fail "settle refused three times made $(grep -c '^scale' "$calls") scales, not three"

# An unknown mode is refused before any call.
cluster 1 1
run_bridge sideways
expect_status "an unknown mode" failed
[ ! -s "$calls" ] || fail "an unknown mode made a call: $(tr '\n' ';' <"$calls")"
echo "the bridge's two modes keep the small image up from the first scale to the settled GPU pod, and change nothing otherwise"
