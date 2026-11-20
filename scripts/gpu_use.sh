#!/usr/bin/env bash
# `mise run gpu:use <songs|speech|free>`: gives the PC's one card to songmaker's music or to speech's GPU image, or
# frees it for a measurement window. The operator switches; Git names no replica count for a card's user, so Flux keeps what this sets. One card serves one user at a
# time only because the PC holds one: each user requests one GPU, and with a second card both may run.
# `songs` starts speech's small image on the CPU at two pods and waits until both are Ready, stops the GPU image and waits until its
# pod is gone, which frees the card, then runs acestep-worker and waits until it is Ready, which its /health grants only
# with the card. `speech` stops acestep-worker and waits until its pod is gone, runs the GPU image and waits until it is
# Ready, which takes minutes, since it loads its models first, then stops the small image. Each wait is for the
# Deployment's ready replicas, so no progress deadline ends it. The small image runs at two pods so that a rollout or a
# drain leaves the other to serve; the GPU image stays at one, since the card is one. The Service speech-runtime reaches whichever one is
# Ready, and no step leaves it without one while the next is not Ready.
# `free` runs only while speech holds the card (acestep-worker at 0, the GPU image at 1). It stops a stale timer, arms
# the user timer gpu-use-return to run `gpu_use.sh return` after the bound, then runs the voice half `songs` runs (the
# small image at two pods Ready, the GPU image at 0 and gone) and leaves the worker alone. The bound is armed before the
# first scale, so a failure or kill later still returns the card, and an arm that fails refuses before any scale.
# `return` is the timer's, no choice of the task: it runs `speech` only while the worker and the GPU image both stand at
# 0, else it returns nothing and ends 0, so it never takes the card from songmaker nor restarts a restored voice. A
# reboot loses the timer, and the timer runs this script at the path it was armed from.
# Usage: scripts/gpu_use.sh <songs|speech|free>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
user="${1:?usage: gpu_use.sh <songs|speech|free>}"
say() { echo "gpu:use: $1"; }
fail() { echo "gpu:use: $1" >&2; exit 1; }

songs_namespace=songmaker
songs_worker=acestep-worker
speech_namespace=speech-runtime
speech_small=speech-runtime
speech_gpu=speech-runtime-gpu
speech_small_replicas=2
return_unit=gpu-use-return
return_minutes=60

# scale <namespace> <deployment> <replicas>
scale() {
  kubectl scale --namespace "$1" "deployment/$2" --replicas="$3" >/dev/null ||
    fail "could not scale $1's $2 to $3; check that the kubeconfig $KUBECONFIG reaches the cluster, then run it again"
}

# wait_gone <namespace> <deployment> <way back>: the pods of the Deployment are gone within 3 minutes.
wait_gone() {
  kubectl wait --namespace "$1" --for=delete pod --selector "app.kubernetes.io/name=$2" --timeout=180s >/dev/null ||
    fail "$2's pod is still there after 3 minutes; $3"
}

# wait_ready <namespace> <deployment> <replicas> <minutes> <way back>: the Deployment has that many ready replicas.
# Rollout status is not used, since it fails on a progress deadline that ran out while a pod waited for the card.
wait_ready() {
  kubectl wait --namespace "$1" "deployment/$2" --for=jsonpath='{.status.readyReplicas}'="$3" --timeout="$(($4 * 60))s" >/dev/null ||
    fail "$2 is not Ready within $4 minutes; $5"
}

# replicas_of <namespace> <deployment>: the Deployment's spec.replicas, read or refused.
replicas_of() {
  local replicas
  replicas="$(kubectl get --namespace "$1" "deployment/$2" --output jsonpath='{.spec.replicas}')" &&
    [[ "$replicas" =~ ^[0-9]+$ ]] ||
    fail "could not read $1's $2 replicas; check that the kubeconfig $KUBECONFIG reaches the cluster, then run 'mise run gpu:use speech' or 'mise run gpu:use songs'"
  echo "$replicas"
}

# small_voice_serves <way back if the small image is not Ready> <way back if the GPU image's pod stays>: speech's small image runs at two pods and is Ready, then the
# GPU image stops and its pod is gone, which frees the card.
small_voice_serves() {
  scale "$speech_namespace" "$speech_small" "$speech_small_replicas"
  wait_ready "$speech_namespace" "$speech_small" "$speech_small_replicas" 5 "$1"
  scale "$speech_namespace" "$speech_gpu" 0
  wait_gone "$speech_namespace" "$speech_gpu" "$2"
}

# arm_return: stops a stale timer and arms the bound, which runs this script's `return` after the minutes.
arm_return() {
  local timer="$return_unit.timer"
  if systemctl --user is-active --quiet "$timer"; then
    systemctl --user stop "$timer" || fail "could not stop the armed $timer; look at 'systemctl --user status $timer', then run it again"
  fi
  systemd-run --user --unit="$return_unit" --collect --on-active="${return_minutes}m" --setenv=PATH --setenv=KUBECONFIG \
    -- "$(realpath "${BASH_SOURCE[0]}")" return >/dev/null 2>&1 ||
    fail "could not arm the $return_unit timer, a return of an earlier window may still run; nothing was scaled, so look at 'systemctl --user status $return_unit', then run it again"
}

case "$user" in
  songs)
    small_voice_serves "speech has no Ready pods, so look at $speech_small's pods in namespace $speech_namespace, then run it again; the GPU image still holds the card and runs" "run it again"
    scale "$songs_namespace" "$songs_worker" 1
    wait_ready "$songs_namespace" "$songs_worker" 1 10 "another user may still hold the card, so run 'mise run gpu:use speech' or free it, then run it again"
    say "the card is songmaker's: $songs_worker is Ready, and speech runs its small image on the CPU at $speech_small_replicas pods"
    ;;
  speech)
    scale "$songs_namespace" "$songs_worker" 0
    wait_gone "$songs_namespace" "$songs_worker" "run it again"
    scale "$speech_namespace" "$speech_gpu" 1
    # The pull of the image takes minutes, and its start another ten.
    wait_ready "$speech_namespace" "$speech_gpu" 1 25 "the small image still runs, so look at $speech_gpu's pod in namespace $speech_namespace, then run it again or run 'mise run gpu:use songs' to give the card back"
    scale "$speech_namespace" "$speech_small" 0
    say "the card is speech's: $speech_gpu is Ready, $songs_worker stands at 0 and the small image at 0"
    ;;
  free)
    worker_replicas="$(replicas_of "$songs_namespace" "$songs_worker")"
    gpu_replicas="$(replicas_of "$speech_namespace" "$speech_gpu")"
    if [ "$worker_replicas" != 0 ] || [ "$gpu_replicas" != 1 ]; then
      fail "the card is not speech's: $songs_worker stands at $worker_replicas and $speech_gpu at $gpu_replicas; run 'mise run gpu:use speech' to give it to speech, or 'mise run gpu:use songs' to give it to songmaker, then run it again"
    fi
    arm_return
    small_voice_serves "the $return_unit timer stays armed and gives the card back to speech in $return_minutes minutes, or run 'mise run gpu:use speech' now; look at $speech_small's pods in namespace $speech_namespace" \
      "the $return_unit timer stays armed and gives the card back to speech in $return_minutes minutes, or run 'mise run gpu:use speech' now; look at $speech_gpu's pod in namespace $speech_namespace"
    say "the card is free: $speech_small runs its small image at $speech_small_replicas pods on the CPU, $speech_gpu and $songs_worker stand at 0; it goes back to speech by itself in $return_minutes minutes (journalctl --user -u $return_unit), or now with 'mise run gpu:use speech'"
    ;;
  return)
    worker_replicas="$(replicas_of "$songs_namespace" "$songs_worker")"
    gpu_replicas="$(replicas_of "$speech_namespace" "$speech_gpu")"
    if [ "$worker_replicas" = 0 ] && [ "$gpu_replicas" = 0 ]; then
      exec "${BASH_SOURCE[0]}" speech
    fi
    say "the card has another user since free; nothing returned"
    ;;
  *)
    fail "unknown user '$user'; name songs, speech or free"
    ;;
esac
