#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/failure.sh"
server="k3d-${CLUSTER_NAME}-server-0"
node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
configured="$(yq '.["kubelet-arg"][] | select(test("^container-log-max-files=")) | sub("^[^=]*=", "")' \
  "$K3S_CONFIG_SOURCE")"
[ -n "$configured" ] || fail "$K3S_CONFIG_SOURCE sets no container-log-max-files"
max_files="$(kubectl get --raw "/api/v1/nodes/$node/proxy/configz" |
  yq -p json '.kubeletconfig.containerLogMaxFiles')"
[ "$max_files" = "$configured" ] ||
  fail "the kubelet keeps $max_files log files per container, not the $configured $K3S_CONFIG_SOURCE sets"
echo "the kubelet of $node keeps $max_files log files per container, as $K3S_CONFIG_SOURCE sets"

# One writer prints a line with its time each second; the other 1 MiB each second, past several rotations.
# Each writer's own shell expands its script.
# shellcheck disable=SC2016
kubectl run log-ticker --image="$CLIENT_IMAGE" --restart=Never --command -- \
  sh -c 'while true; do echo "tick $(date +%s)"; sleep 1; done'
# shellcheck disable=SC2016
kubectl run log-burst --image="$CLIENT_IMAGE" --restart=Never --command -- \
  sh -c 'line="$(printf "%0100d" 0)"; for _ in $(seq 120); do yes "$line" | head -c 1048576; sleep 1; done'
kubectl wait pod/log-ticker pod/log-burst --for=condition=Ready --timeout=3m
# container_dir <pod>: the pod's log directory of its one container, found by the pod's uid on the node.
container_dir() {
  local pod="$1" uid
  uid="$(kubectl get pod "$pod" -o jsonpath='{.metadata.uid}')"
  docker exec "$server" sh -c 'ls -d /var/log/pods/*_"$1"/"$2"' sh "$uid" "$pod"
}

# The clean of host/pod-logs deletes a live file and its emptied directories, here the whole pod directory.
ticker_dir="$(container_dir log-ticker)"
live_file="$ticker_dir/$(docker exec "$server" ls -1A "$ticker_dir")"
echo "deleting ${ticker_dir%/*} with the node's $(docker exec "$server" rm --version | head -n 1)"
deleted_at="$(docker exec "$server" sh -c 'rm -r "$1" && date +%s' sh "${ticker_dir%/*}")"
for _ in $(seq 30); do docker exec "$server" test -f "$live_file" && break; sleep 1; done
docker exec "$server" test -f "$live_file" || fail "the kubelet did not recreate $live_file within 30 seconds"
echo "the kubelet recreated $live_file within $(($(date +%s) - deleted_at)) seconds"
for _ in $(seq 10); do
  newer="$(kubectl logs log-ticker | awk -v deleted_at="$deleted_at" '$1 == "tick" && $2 > deleted_at' || true)"
  [ -z "$newer" ] || break
  sleep 1
done
[ -n "$newer" ] || fail "kubectl logs shows no line written after the deletion"
echo "kubectl logs shows $(wc -l <<<"$newer") lines written after the deletion"

# The default of five files compresses each rotated file but the newest; two rotations show the difference.
burst_dir="$(container_dir log-burst)"
live_name="${live_file##*/}"
rotated=""
rotations=0
for _ in $(seq 90); do
  files="$(docker exec "$server" ls -1A "$burst_dir")"
  [ "$(wc -l <<<"$files")" -le "$max_files" ] || fail "$burst_dir holds ${files//$'\n'/ }"
  ! grep -qE '\.(gz|tmp)$' <<<"$files" || fail "$burst_dir holds a compressed copy: ${files//$'\n'/ }"
  rotated="$({ [ -z "$rotated" ] || echo "$rotated"; grep -vxF "$live_name" <<<"$files" || true; } | sort -u)"
  rotations="$(grep -c . <<<"$rotated" || true)"
  [ "$rotations" -lt 2 ] || break
  sleep 1
done
[ "$rotations" -ge 2 ] || fail "the kubelet rotated $burst_dir less than twice: ${rotated:-none}"
echo "through the rotations ${rotated//$'\n'/ } $burst_dir held at most $max_files files and no compressed copy"
kubectl delete pod log-ticker log-burst --wait=false
