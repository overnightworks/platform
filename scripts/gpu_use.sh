#!/usr/bin/env bash
# `mise run gpu:use <songs|speech>`: gives the PC's one card to songmaker's music or to speech. The operator switches;
# Git names no replica count for a card's user, so Flux keeps what this sets. One card serves one user at a time only
# because the PC holds one card: each user requests one GPU, and with a second card both may run.
# `songs` runs acestep-worker and waits until it is Ready, which its /health grants only with the card. `speech` stops
# it and waits until its pod is gone, which frees the card for speech.
# Usage: scripts/gpu_use.sh <songs|speech>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
user="${1:?usage: gpu_use.sh <songs|speech>}"
say() { echo "gpu:use: $1"; }
fail() { echo "gpu:use: $1" >&2; exit 1; }

songs_worker=(--namespace songmaker deployment/acestep-worker)

case "$user" in
  songs)
    kubectl scale "${songs_worker[@]}" --replicas=1 >/dev/null ||
      fail "could not scale songmaker's acestep-worker to 1; check that the kubeconfig $KUBECONFIG reaches the cluster, then run it again"
    kubectl rollout status "${songs_worker[@]}" --timeout=600s >/dev/null ||
      fail "acestep-worker is not Ready within 10 minutes; another user may still hold the card, so run 'mise run gpu:use speech' or free it, then run it again"
    say "the card is songmaker's: acestep-worker is Ready"
    ;;
  speech)
    kubectl scale "${songs_worker[@]}" --replicas=0 >/dev/null ||
      fail "could not scale songmaker's acestep-worker to 0; check that the kubeconfig $KUBECONFIG reaches the cluster, then run it again"
    kubectl wait --namespace songmaker --for=delete pod --selector app.kubernetes.io/name=acestep-worker --timeout=180s >/dev/null ||
      fail "acestep-worker's pod is still there after 3 minutes; run it again"
    say "the card is free for speech: acestep-worker stands at 0"
    ;;
  *)
    fail "unknown user '$user'; name songs or speech"
    ;;
esac
