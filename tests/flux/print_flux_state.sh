#!/usr/bin/env bash
set -euo pipefail
# The node's own state first, before any call the API server could refuse: a runner that lost its node or killed a
# process for memory shows here and nowhere in Flux's state.
echo "== the node container and the kernel's OOM kills"
node_container="k3d-${CLUSTER_NAME:?CLUSTER_NAME names the cluster}-server-0"
echo "the node container $node_container: $(docker inspect \
  --format '{{.State.Status}} exit={{.State.ExitCode}} oomkilled={{.State.OOMKilled}}' "$node_container" 2>&1)"
sudo dmesg 2>&1 | grep -i -E 'out of memory|oom-kill|killed process' || echo "no OOM-kill line in the kernel's log, or it could not be read"
flux get all --all-namespaces
# A layer's timeout ends the wait for every Kustomization, so each one not Ready is named with its reason.
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.status.conditions[?(@.type=="Ready")].reason}: {.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' |
  while IFS='|' read -r kustomization ready reason; do
    [ "$ready" = True ] || echo "::error::the Kustomization $kustomization is not Ready: $reason"
  done
# One read of Pods, claims and events says what each Pod that is not Ready waits on: a claim that is not Bound with its
# last event, a pull begun and not ended with its seconds, and the Pod's last events. It reads no Secret.
waits_on_filter="$(
  cat <<'JQ'
  def at: .lastTimestamp // .eventTime // .metadata.creationTimestamp;
  def seconds_since: sub("\\.[0-9]+Z$"; "Z") | now - fromdateiso8601 | floor;
  def ready: any(.status.conditions[]?; .type == "Ready" and .status == "True");
  def line: "  " + at + " " + .reason + ": " + ((.message // "") | gsub("\n"; " "));
  def events_of($events; $kind; $namespace; $name):
    [$events[] | select(.involvedObject.kind == $kind and .involvedObject.namespace == $namespace and .involvedObject.name == $name)]
    | sort_by(at);
  [.items[] | select(.kind == "Event")] as $events
  | [.items[] | select(.kind == "PersistentVolumeClaim" and .status.phase != "Bound")] as $unbound
  | .items[] | select(.kind == "Pod" and .status.phase != "Succeeded" and (ready | not))
  | . as $pod | .metadata.namespace as $namespace | .metadata.name as $name
  | events_of($events; "Pod"; $namespace; $name) as $pod_events
  | "-- \($namespace)/\($name): phase \(.status.phase), waiting [\([.status.containerStatuses[]?, .status.initContainerStatuses[]? | .state.waiting.reason // empty] | join(","))], unmet [\([.status.conditions[]? | select(.status == "False") | .reason // .type] | join(","))]",
    ($pod.spec.volumes[]?.persistentVolumeClaim.claimName as $claim
      | $unbound[] | select(.metadata.namespace == $namespace and .metadata.name == $claim)
      | "  claim \($claim) is \(.status.phase), its last event:" + (events_of($events; "PersistentVolumeClaim"; $namespace; $claim) | last // empty | line | ltrimstr(" "))),
    ($pod_events[] | select(.reason == "Pulling") as $pulling
      | ($pulling.message | capture("image \"(?<image>[^\"]+)\"").image) as $image
      | select(any($pod_events[]; .reason == "Pulled" and (.message | contains("\"" + $image + "\"")) and at >= ($pulling | at)) | not)
      | "  pulling \($image) for \($pulling | at | seconds_since) s"),
    "  last events of the Pod, oldest first:", ($pod_events[-5:][] | line)
JQ
)"
echo "== what each Pod that is not Ready waits on"
kubectl get pods,persistentvolumeclaims,events --all-namespaces --output json | jq --raw-output "$waits_on_filter" ||
  echo "the Pods, claims and events could not be read or formatted"
flux logs --all-namespaces --level=error
# Pod Security's refusal of a Pod appears only in Warning events and the workloads' conditions, never in Flux's state.
kubectl get events --all-namespaces --field-selector type=Warning
# What an app's pull cost the runner before the failure: the kubelet's own report of each pull, and the disk.
kubectl get events --all-namespaces --field-selector reason=Pulled \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.message}{"\n"}{end}'
df --human-readable /
kubectl get deployments,replicasets --all-namespaces -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name}{range .status.conditions[*]} {.type}={.status}({.reason}: {.message}){end}{"\n"}{end}'
# A start an app refuses appears only in its own log, a refused pull only in its container's waiting state.
kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.status.containerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.waiting.message}{"\n"}{end}' |
  while IFS='|' read -r pod ready waiting; do
    [ "$ready" != True ] || continue
    echo "the Pod $pod is not Ready: $waiting"
    kubectl --namespace "${pod%/*}" logs "pod/${pod#*/}" --all-containers --tail=20 || true
  done
