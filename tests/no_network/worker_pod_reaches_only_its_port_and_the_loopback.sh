#!/usr/bin/env bash
# worker_pod_reaches_only_its_port_and_the_loopback.sh: in k3d, or on the PC with KUBECONFIG set, shows that a Pod built
# from the StatefulSet build-worker of apps/presentator, with its worker container replaced by a stand-in from
# PROBE_IMAGE, takes the rules of its init container: a Pod beside it reaches the port the stand-in serves for the
# worker (the reply of an accepted connection leaves) and no other port, while the stand-in's root user and two non-root
# users reach nothing off the loopback, as a Pod without the init container does, and only the loopback when it is
# theirs. It shows the key file: mode 0400 and root's in the worker's mount, unreadable by the two non-root users, and
# readable by the web's user at the web's path. And it shows the NetworkPolicy build-worker on a Pod without
# the init container: the web's Pod reaches the port, another Pod does not, and the Pod itself reaches nothing. It needs
# PROBE_IMAGE and NO_NETWORK_NAMESPACE, a Namespace without a Pod Security label that it creates and deletes. The rule
# file, the policy, the Secret volumes and the worker's port come from the render; the Secrets hold dummies. The two
# non-root users stand for presentator's build and wire users, whose uids the rules do not name: the ruleset drops every
# uid but 0 off the loopback, so any non-root uid shows it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
namespace="$NO_NETWORK_NAMESPACE"
started_at=$SECONDS
work="$(mktemp -d)"
namespace_created=
remove_objects() {
  local cell_status=$?
  rm -rf "$work"
  [ -z "$namespace_created" ] || delete_object delete namespace --wait --timeout=2m "$namespace"
  end_deletions "$cell_status"
}
trap remove_objects EXIT
k() { kubectl -n "$namespace" "$@"; }

kubectl kustomize apps/presentator >"$work/presentator.yaml"
WORKER='select(.kind == "StatefulSet" and .metadata.name == "build-worker")'
WEB='select(.kind == "Deployment" and .metadata.name == "web")'
worker() { yq --no-doc "$WORKER | $1" "$work/presentator.yaml"; }
web() { yq --no-doc "$WEB | $1" "$work/presentator.yaml"; }

# What the render says: the rule file's ConfigMap and the key's Secret, file and volume, in the worker and in the web, and
# the worker's port.
init_mount="$(worker '.spec.template.spec.initContainers[0].volumeMounts[0].name')"
rules_map="$(worker ".spec.template.spec.volumes[] | select(.name == \"$init_mount\") | .configMap.name")"
key_file="$(worker '.spec.template.spec.containers[0].command | join(" ")' | sed -n 's/.*--key-file \([^ ]*\).*/\1/p')"
key_volume="$(worker ".spec.template.spec.containers[0].volumeMounts[] | select(.mountPath == \"${key_file%/*}\") | .name")"
key_secret="$(worker ".spec.template.spec.volumes[] | select(.name == \"$key_volume\") | .secret.secretName")"
web_volume="$(web ".spec.template.spec.volumes[] | select(.projected.sources[].secret.name == \"$key_secret\") | .name")"
web_secret="$(web ".spec.template.spec.volumes[] | select(.name == \"$web_volume\") | .projected.sources[0].secret.name")"
web_mount="$(web ".spec.template.spec.containers[0].volumeMounts[] | select(.name == \"$web_volume\") | .mountPath")"
web_key_file="$(web '.spec.template.spec.containers[0].env[] | select(.name == "PRESENTATOR_BUILD_WORKER_KEY_FILE") | .value')"
key_name="${key_file##*/}"
worker_port="$(worker '.spec.template.spec.containers[0].ports[] | select(.name == "build") | .containerPort')"
other_port=$((worker_port + 1))
[[ $worker_port =~ ^[0-9]+$ ]] && [ -n "$rules_map" ] && [ -n "$key_file" ] && [ -n "$key_volume" ] && [ -n "$key_secret" ] && [ -n "$web_volume" ] &&
  [ -n "$web_secret" ] && [ -n "$web_mount" ] && [ "$web_key_file" = "$key_file" ] ||
  fail "the render names no rule file, key file, key Secret or web volume that agree: '$rules_map' '$key_file' '$key_volume' '$key_secret' '$web_volume' '$web_secret' '$web_mount' '$web_key_file'"
# Two arbitrary non-root uids, which this cell chooses.
first_uid=10001
second_uid=10002

kubectl create namespace "$namespace"
namespace_created=1
k wait serviceaccount/default --for=create --timeout=1m
yq --no-doc "select(.kind == \"ConfigMap\" and .metadata.name == \"$rules_map\") | .metadata.namespace = \"$namespace\"" "$work/presentator.yaml" | k create -f -
NAMESPACE="$namespace" yq --no-doc 'select(.kind == "NetworkPolicy" and .metadata.name == "build-worker") | .metadata.namespace = strenv(NAMESPACE)' \
  "$work/presentator.yaml" | k create -f -
dummy_key="$(openssl rand -hex 16)"
k create secret generic "$key_secret" "--from-literal=$key_name=$dummy_key"
k create secret generic "$web_secret"

# The stand-in serves a reply on the worker's port and on the one beside it as root, as the worker's controller does for its one port.
SERVE="nc -ll -p $worker_port -e echo pong & exec nc -ll -p $other_port -e echo pong"
# worker_pod <name> <yq filter>: the Pod of the StatefulSet's template, its worker container the stand-in, no probe and no
# restart policy, its container port, init container and volumes the render's, and no ServiceAccount or pull Secret.
worker_pod() {
  NAME="$1" IMAGE="$PROBE_IMAGE" PROGRAM="$SERVE" yq --no-doc "$WORKER
    | {\"apiVersion\": \"v1\", \"kind\": \"Pod\", \"metadata\": {\"name\": strenv(NAME), \"labels\": .spec.template.metadata.labels}, \"spec\": .spec.template.spec}
    | del(.spec.serviceAccountName, .spec.imagePullSecrets)
    | .spec.containers[0] |= (.image = strenv(IMAGE) | .command = [\"sh\", \"-c\", strenv(PROGRAM)] | del(.readinessProbe, .restartPolicy))
    | $2" "$work/presentator.yaml"
}
# user_container <name> <uid>: a container of a non-root user, with no capability, the key's mount and nothing
# to serve, as JSON.
key_mount="$(worker ".spec.template.spec.containers[0].volumeMounts[] | select(.name == \"$key_volume\")" | yq -o=json -I=0)"
user_container() {
  NAME="$1" USER_ID="$2" IMAGE="$PROBE_IMAGE" KEY_MOUNT="$key_mount" yq --null-input -o=json -I=0 '{"name": strenv(NAME), "image": strenv(IMAGE), "command": ["sleep", "3600"],
    "securityContext": {"runAsUser": env(USER_ID), "runAsGroup": env(USER_ID), "allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true,
      "seccompProfile": {"type": "RuntimeDefault"}, "capabilities": {"drop": ["ALL"]}},
    "volumeMounts": [strenv(KEY_MOUNT) | from_json]}'
}
add_users=".spec.containers += [$(user_container first-user "$first_uid"), $(user_container second-user "$second_uid")]"

# filtered: the init container's rules, no label the NetworkPolicy selects. unfiltered: the same without the init container.
# policed: the worker's labels without the init container, so that only the NetworkPolicy acts on it.
worker_pod filtered ".metadata.labels = {\"probe\": \"filtered\"} | $add_users" | k create -f -
worker_pod unfiltered '.metadata.labels = {"probe": "unfiltered"} | del(.spec.initContainers)' | k create -f -
worker_pod policed 'del(.spec.initContainers)' | k create -f -
NAME=client IMAGE="$PROBE_IMAGE" yq --null-input '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME), "labels": {"probe": "client"}},
  "spec": {"terminationGracePeriodSeconds": 1, "containers": [{"name": "client", "image": strenv(IMAGE), "command": ["nc", "-ll", "-p", "9000", "-e", "echo", "client"]}]}}' | k create -f -
# web: the render's web template with the volume of the Secret files and a stand-in container, so the key is read as the web reads it.
IMAGE="$PROBE_IMAGE" VOLUME="$web_volume" yq --no-doc "$WEB
  | {\"apiVersion\": \"v1\", \"kind\": \"Pod\", \"metadata\": {\"name\": \"web\", \"labels\": .spec.template.metadata.labels}, \"spec\": .spec.template.spec}
  | del(.spec.serviceAccountName, .spec.imagePullSecrets, .spec.shareProcessNamespace)
  | .spec.terminationGracePeriodSeconds = 1
  | .spec.volumes = [.spec.volumes[] | select(.name == strenv(VOLUME))]
  | .spec.containers = [{\"name\": \"web\", \"image\": strenv(IMAGE), \"command\": [\"sleep\", \"3600\"],
      \"securityContext\": .spec.containers[0].securityContext, \"volumeMounts\": [.spec.containers[0].volumeMounts[] | select(.name == strenv(VOLUME))]}]" \
  "$work/presentator.yaml" | k create -f -
k wait pod/filtered pod/unfiltered pod/policed pod/client pod/web --for=condition=Ready --timeout=3m

# run_in <pod> <container> <command>: runs it in a shell there and sets run_status and run_output; fails when the exec
# did not run, so that a probe that never ran is no verdict.
run_in() {
  local reply
  reply="$(k exec "$1" -c "$2" -- sh -c "$3; echo status=\$?")" || fail "the probe '$3' in $1/$2 did not run"
  run_status="${reply##*status=}"
  run_output="${reply%status=*}"
  run_output="${run_output%$'\n'}"
  [[ $run_status =~ ^[0-9]+$ ]] || fail "the probe '$3' in $1/$2 printed no status: $reply"
}
# answer <pod> <container> <address:port>: sets answered to the connection's reply, empty when none was made.
answer() {
  run_in "$1" "$2" "nc -w 3 '${3%:*}' '${3##*:}' </dev/null 2>/dev/null"
  answered="$run_output"
  [ "$run_status" = 0 ] || answered=
}
# reaches <pod> <container> <address:port>: succeeds when a TCP connection from the container is made.
reaches() { run_in "$1" "$2" "nc -w 3 '${3%:*}' '${3##*:}' </dev/null >/dev/null 2>&1"; [ "$run_status" = 0 ]; }
resolves() { run_in "$1" "$2" "timeout 8 nslookup '$3' '$4' >/dev/null 2>&1"; [ "$run_status" = 0 ]; }
address_of() { k get "pod/$1" -o jsonpath='{.status.podIP}'; }

filtered_address="$(address_of filtered)"
unfiltered_address="$(address_of unfiltered)"
policed_address="$(address_of policed)"
client_address="$(address_of client)"
api_address="$(kubectl get service kubernetes -o jsonpath='{.spec.clusterIP}')"
dns_address="$(kubectl -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')"
node_address="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
[ -n "$filtered_address" ] && [ -n "$unfiltered_address" ] && [ -n "$policed_address" ] && [ -n "$client_address" ] &&
  [ -n "$api_address" ] && [ -n "$dns_address" ] && [ -n "$node_address" ] || fail "an address to probe is missing"
[ "$(k get pod/filtered -o jsonpath='{.status.initContainerStatuses[0].state.terminated.exitCode}')" = 0 ] ||
  fail "the init container of the filtered Pod did not end 0"

# The rules (input). The Pod without the init container serves both ports to the client; with it, one.
for port in "$worker_port" "$other_port"; do
  answer client client "$unfiltered_address:$port"
  [ "$answered" = pong ] || fail "the client got no reply from the unfiltered Pod's port $port"
done
answer client client "$filtered_address:$worker_port"
[ "$answered" = pong ] || fail "the client got no reply from the filtered Pod's port $worker_port, so its reply did not leave or the port was not admitted"
! reaches client client "$filtered_address:$other_port" || fail "the client reached the filtered Pod's port $other_port, which no rule admits"
echo "the filtered Pod admits a connection to its worker's port and answers it, and drops one to the port beside it, which the Pod without the rules serves"

# The rules (output). The unfiltered Pod's worker reaches the client, the API, DNS and the node; the filtered Pod's root,
# non-root users reach none of them nor 1.1.1.1, and each reaches a listener of its own on the loopback.
targets=("$client_address:9000" "$api_address:443" "$node_address:10250" 1.1.1.1:443)
for target in "${targets[@]:0:3}"; do
  reaches unfiltered worker "$target" || fail "the unfiltered Pod's worker did not reach $target, so the probe shows nothing"
done
resolves unfiltered worker kubernetes.default.svc.cluster.local "$dns_address" || fail "the unfiltered Pod did not resolve a name at cluster DNS"
loopback_port=9100
for container in worker first-user second-user; do
  for target in "${targets[@]}"; do
    ! reaches filtered "$container" "$target" || fail "the filtered Pod's $container reached $target"
  done
  ! resolves filtered "$container" kubernetes.default.svc.cluster.local "$dns_address" ||
    fail "the filtered Pod's $container resolved a name at cluster DNS $dns_address"
  run_in filtered "$container" "timeout 10 nc -ll -s 127.0.0.1 -p $loopback_port -e echo lo >/dev/null 2>&1 & sleep 1; nc -w 3 127.0.0.1 $loopback_port </dev/null"
  [ "$run_status" = 0 ] && [ "$run_output" = lo ] || fail "the filtered Pod's $container did not reach its own listener on 127.0.0.1: '$run_output'"
  loopback_port=$((loopback_port + 100))
done
echo "the filtered Pod's root and non-root users reach neither the client, the API's ClusterIP, cluster DNS, the node nor 1.1.1.1, and each reaches its own 127.0.0.1 listener"

# The key file in the worker's pod and in the web's.
run_in filtered worker "stat -L -c '%a %u' '$key_file' && cat '$key_file'"
[ "$run_status" = 0 ] && [ "$run_output" = "$(printf '400 0\n%s' "$dummy_key")" ] ||
  fail "the worker's key file reads '$run_output' (status $run_status), not mode 400, owner 0 and the Secret's value"
for container in first-user second-user; do
  run_in filtered "$container" "cat '$key_file' 2>&1"
  [ "$run_status" != 0 ] || fail "the filtered Pod's $container read the key file: '$run_output'"
  [[ $run_output == *"Permission denied"* ]] || fail "the filtered Pod's $container was refused the key file for another reason than its mode: '$run_output'"
done
run_in web web "cat '$web_key_file'"
[ "$run_status" = 0 ] && [ "$run_output" = "$dummy_key" ] || fail "the web's user did not read the key at '$web_key_file': '$run_output' (status $run_status)"
echo "the key file is mode 400 and root's in the worker, unreadable by the non-root users, and the web's user reads it at the path it names"

# The NetworkPolicy on a Pod without the rules. It acts once programmed, which is shown by the refusal of the client.
policy_programmed() { ! reaches client client "$policed_address:$worker_port"; }
until_true 120 "the NetworkPolicy refuses the client's connection to the policed Pod" policy_programmed
answer web web "$policed_address:$worker_port"
[ "$answered" = pong ] || fail "the web got no reply from the policed Pod's port $worker_port"
# The policy names the container port build, so the web's admission ends at the port the Pod declares.
! reaches web web "$policed_address:$other_port" || fail "the web reached the policed Pod's port $other_port, which its container port build does not name"
for target in "${targets[@]}"; do
  ! reaches policed worker "$target" || fail "the policed Pod reached $target"
done
! resolves policed worker kubernetes.default.svc.cluster.local "$dns_address" || fail "the policed Pod resolved a name at cluster DNS"
echo "the NetworkPolicy lets the web reach the worker's port and no other, refuses another Pod, and the policed Pod reaches nothing"

echo "worker rules cell ended after $((SECONDS - started_at)) seconds"
