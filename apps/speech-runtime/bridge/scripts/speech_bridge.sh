#!/bin/sh
# The script of both Jobs of a speech GPU release, in k8up's sh, which holds the one image and its kubectl. speech-runtime-gpu
# rolls with Recreate on the one card, so while speech holds the card (the GPU image at one pod, the small image at none) the
# roll leaves the Service without a Ready pod for the pull and the start. Mode `up`, the Job bridge, raises the small image to
# one pod and waits until it is Ready before the GPU image rolls; mode `settle`, the Job settle, waits until the new GPU pod
# is Ready and lowers the small image to none again, the count `gpu:use speech` leaves. Both read the release's GPU image
# from GPU_IMAGE, the annotation gpu-image of the Job's pod. Every scale carries the count it expects, so a count that
# `gpu:use` set meanwhile is refused and never overwritten: the script reads the counts again and decides once more, three
# times at most. It never scales the GPU image. The namespace is the Job's own.
# Usage: sh speech_bridge.sh <up|settle>
set -eu

mode="${1:?usage: speech_bridge.sh <up|settle>}"
gpu_image="${GPU_IMAGE:?the release's GPU image, from the pod's annotation gpu-image}"
small=deployment/speech-runtime
gpu=deployment/speech-runtime-gpu
bridge=job/bridge
decisions=3
# Below the Job bridge's deadline, so that a pod that never turns Ready fails with its name.
ready_seconds=1400
# One round of settle's wait: after it the GPU image's count is read again.
round_seconds=60

say() { echo "speech-bridge $mode: $1"; }
fail() {
  echo "speech-bridge $mode: $1" >&2
  exit 1
}

# field <object> <JSONPath>: the field's value, empty when it is not set, and failing when the object is unreadable. Each caller
# reads it into a variable of its own statement, so that a failure ends the script under `set -e`.
field() { kubectl get "$1" --output "jsonpath={$2}"; }

image_path='.spec.template.spec.containers[0].image'
annotation_path='.spec.template.metadata.annotations.gpu-image'

# scale_small <from> <to>: succeeds when the scale held, fails when the count was no longer <from>.
scale_small() { kubectl scale "$small" --current-replicas="$1" --replicas="$2" >/dev/null; }

# The GPU image's count is empty without the Deployment.
read_gpu_replicas() { gpu_count="$(kubectl get "$gpu" --ignore-not-found --output 'jsonpath={.spec.replicas}')"; }

# read_unmet: sets unmet_path and unmet_value to the first condition of the GPU pod that does not hold yet, empty when the
# GPU Deployment runs the release's image, has observed its generation and has one updated, Ready pod. The order is the
# order they come true in: a Ready pod of the old image shows before the Deployment saw the new one.
read_unmet() {
  unmet_path=""
  unmet_value=""
  running="$(field "$gpu" "$image_path")"
  generation="$(field "$gpu" .metadata.generation)"
  observed="$(field "$gpu" .status.observedGeneration)"
  updated="$(field "$gpu" .status.updatedReplicas)"
  ready="$(field "$gpu" .status.readyReplicas)"
  if [ "$running" != "$gpu_image" ]; then
    unmet_path="$image_path" unmet_value="$gpu_image"
  elif [ "$observed" != "$generation" ]; then
    unmet_path=.status.observedGeneration unmet_value="$generation"
  elif [ "$updated" != 1 ]; then
    unmet_path=.status.updatedReplicas unmet_value=1
  elif [ "$ready" != 1 ]; then
    unmet_path=.status.readyReplicas unmet_value=1
  fi
}

# refused_again: counts a refused scale and fails after the last decision.
refused_again() {
  refused=$((refused + 1))
  [ "$refused" -lt "$decisions" ] ||
    fail "the small image's count moved under $decisions scales; look at 'mise run gpu:use' and the Deployment speech-runtime, then delete the Job"
  say "the small image's count moved, deciding again"
}

up() {
  refused=0
  while :; do
    read_gpu_replicas
    [ -n "$gpu_count" ] || { say "there is no GPU Deployment yet, a first apply, so nothing to bridge"; return; }
    [ "$gpu_count" = 1 ] || { say "the GPU Deployment stands at $gpu_count, so speech does not hold the card and nothing rolls on it"; return; }
    running="$(field "$gpu" "$image_path")"
    [ "$running" != "$gpu_image" ] || { say "the GPU Deployment already runs the release's image, so nothing rolls"; return; }
    small_count="$(field "$small" .spec.replicas)"
    [ "$small_count" != 0 ] && break
    if scale_small 0 1; then
      say "raised the small image from 0 to 1"
      small_count=1
      break
    fi
    refused_again
  done
  say "waiting until the small image has $small_count Ready pods"
  kubectl wait "$small" --for=jsonpath='{.status.readyReplicas}'="$small_count" --timeout="${ready_seconds}s" ||
    fail "the small image is not Ready within ${ready_seconds} seconds; look at the pods of speech-runtime and their events, then delete the Job bridge"
  say "the small image has $small_count Ready pods"
}

# await_gpu_pod: returns once the GPU pod runs the release, or, with gpu_moved set, once `gpu:use` moved the GPU image off one pod.
await_gpu_pod() {
  gpu_moved=""
  while :; do
    read_unmet
    [ -n "$unmet_path" ] || return 0
    read_gpu_replicas
    [ "$gpu_count" = 1 ] || { gpu_moved=1; return 0; }
    say "waiting until $unmet_path is $unmet_value"
    kubectl wait "$gpu" --for=jsonpath="{$unmet_path}=$unmet_value" --timeout="${round_seconds}s" || sleep 2
  done
}

# later <a> <b>: a timestamp of one RFC 3339 form in UTC is later than another when it sorts after it.
later() { [ "$(expr "$1" \> "$2")" = 1 ]; }

settle() {
  refused=0
  while :; do
    read_gpu_replicas
    [ "$gpu_count" = 1 ] || { say "the GPU Deployment stands at ${gpu_count:-none}, so speech does not hold the card and nothing is lowered"; return; }
    bridge_created="$(field "$bridge" .metadata.creationTimestamp)"
    gpu_created="$(field "$gpu" .metadata.creationTimestamp)"
    if later "$gpu_created" "$bridge_created"; then
      say "the GPU Deployment is newer than the Job bridge, a first apply, so the counts stay as they are"
      return
    fi
    await_gpu_pod
    [ -z "$gpu_moved" ] || { say "the GPU Deployment's count moved while waiting, deciding again"; continue; }
    live_image="$(field "$bridge" "$annotation_path")"
    if [ "$live_image" != "$gpu_image" ]; then
      say "a newer release is pending in the Job bridge, so the small image stays up for its settle"
      return
    fi
    small_count="$(field "$small" .spec.replicas)"
    [ "$small_count" = 1 ] || { say "the small image stands at $small_count, a count that gpu:use set, so it stays"; return; }
    if scale_small 1 0; then
      say "lowered the small image from 1 to 0, as the GPU pod is Ready"
      return
    fi
    refused_again
  done
}

case "$mode" in
  up) up ;;
  settle) settle ;;
  *) fail "unknown mode '$mode'; name up or settle" ;;
esac
