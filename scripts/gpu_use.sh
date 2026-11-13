#!/usr/bin/env bash
# `mise run gpu:use <songs|speech>`: gives the PC's one card to songmaker's music or to speech's GPU image. The operator
# switches; Git names no replica count for a card's user, so Flux keeps what this sets. One card serves one user at a
# time only because the PC holds one: each user requests one GPU, and with a second card both may run.
# `songs` starts speech's small image on the CPU and waits until it is Ready, stops the GPU image and waits until its
# pod is gone, which frees the card, then runs acestep-worker and waits until it is Ready, which its /health grants only
# with the card. `speech` stops acestep-worker and waits until its pod is gone, runs the GPU image and waits until it is
# Ready, which takes minutes, since it loads its models first, then stops the small image. The Service speech-runtime
# reaches whichever one is Ready, and no step leaves it without one while the next is not Ready.
# Usage: scripts/gpu_use.sh <songs|speech>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
user="${1:?usage: gpu_use.sh <songs|speech>}"
say() { echo "gpu:use: $1"; }
fail() { echo "gpu:use: $1" >&2; exit 1; }

songs_namespace=songmaker
songs_worker=acestep-worker
speech_namespace=speech-runtime
speech_small=speech-runtime
speech_gpu=speech-runtime-gpu

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

# wait_ready <namespace> <deployment> <minutes> <way back>
wait_ready() {
  kubectl rollout status --namespace "$1" "deployment/$2" --timeout="$(($3 * 60))s" >/dev/null ||
    fail "$2 is not Ready within $3 minutes; $4"
}

case "$user" in
  songs)
    scale "$speech_namespace" "$speech_small" 1
    wait_ready "$speech_namespace" "$speech_small" 5 "speech has no Ready pod, so look at $speech_small's pod in namespace $speech_namespace, then run it again; the GPU image still holds the card and runs"
    scale "$speech_namespace" "$speech_gpu" 0
    wait_gone "$speech_namespace" "$speech_gpu" "run it again"
    scale "$songs_namespace" "$songs_worker" 1
    wait_ready "$songs_namespace" "$songs_worker" 10 "another user may still hold the card, so run 'mise run gpu:use speech' or free it, then run it again"
    say "the card is songmaker's: $songs_worker is Ready, and speech runs its small image on the CPU"
    ;;
  speech)
    scale "$songs_namespace" "$songs_worker" 0
    wait_gone "$songs_namespace" "$songs_worker" "run it again"
    scale "$speech_namespace" "$speech_gpu" 1
    # The pull of the image takes minutes, and its start another ten.
    wait_ready "$speech_namespace" "$speech_gpu" 25 "the small image still runs, so look at $speech_gpu's pod in namespace $speech_namespace, then run it again or run 'mise run gpu:use songs' to give the card back"
    scale "$speech_namespace" "$speech_small" 0
    say "the card is speech's: $speech_gpu is Ready, $songs_worker stands at 0 and the small image at 0"
    ;;
  *)
    fail "unknown user '$user'; name songs or speech"
    ;;
esac
