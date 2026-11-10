# shellcheck shell=bash
# Sourced by the scripts under tests/no_network/ and by the cells of other layers that run the pod shape or read the node.
# no_network_pod <name> <image> <init|none>: a Pod of the shape the worker takes: with init, the init container
# remove-link (the program of remove_link.sh, uid 0, RuntimeDefault, only NET_ADMIN) before a non-root worker with
# restricted's fields; with none, the same worker alone. The worker sleeps, so that a cell can exec into it.
no_network_pod() {
  NAME="$1" IMAGE="$2" PROGRAM="$(cat "$(dirname "${BASH_SOURCE[0]}")/remove_link.sh")" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
     "spec": {"automountServiceAccountToken": false,
       "initContainers": [{"name": "remove-link", "image": strenv(IMAGE), "command": ["sh", "-c", strenv(PROGRAM)],
         "securityContext": {"runAsUser": 0, "allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true,
           "seccompProfile": {"type": "RuntimeDefault"}, "capabilities": {"drop": ["ALL"], "add": ["NET_ADMIN"]}}}],
       "containers": [{"name": "worker", "image": strenv(IMAGE), "command": ["sleep", "3600"],
         "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "allowPrivilegeEscalation": false,
           "seccompProfile": {"type": "RuntimeDefault"}, "capabilities": {"drop": ["ALL"]}}}]}}' |
    if [ "${3:-init}" = none ]; then yq 'del(.spec.initContainers)'; else cat; fi
}

# shellcheck disable=SC2154 # namespace is the sourcing script's.
# The functions below act on the Namespace named by the sourcing script's variable namespace, in a Pod's container worker.
# create_pod <name> <init|none> [<yq filter>]: the Pod of no_network_pod, changed by the filter.
create_pod() {
  no_network_pod "$1" "$PROBE_IMAGE" "$2" | yq "${3:-.}" | kubectl -n "$namespace" create -f -
}
# in_worker <pod> <argument>...: runs the command in the worker and prints what it printed; fails when the exec does,
# so that an inspection that did not run is never read as a result.
in_worker() {
  local pod="$1"
  shift
  kubectl -n "$namespace" exec "$pod" -c worker -- "$@" || fail "the inspection '$*' in pod/$pod did not run"
}
# link_names <pod>: the names of the Pod's links, sorted.
link_names() { in_worker "$1" ip -o link | sed -n 's/^[0-9]*: \([^:@ ]*\).*/\1/p' | sort; }
# probe <pod> <command>: sets probe_result to the status the command ended with in the worker. The exec itself must
# have run, and the sourcing script must call it outside a command substitution, so that its failure ends the script.
probe() {
  local pod="$1" output
  shift
  output="$(kubectl -n "$namespace" exec "$pod" -c worker -- sh -c "$* >/dev/null 2>&1; echo status=\$?")" ||
    fail "the probe '$*' in pod/$pod did not run"
  [ "${output%%=*}" = status ] || fail "the probe '$*' in pod/$pod printed no status"
  probe_result="${output#status=}"
}
# reaches <pod> <address> <port>: succeeds when a TCP connection from the worker is made.
reaches() { probe "$1" "nc -w 3 '$2' '$3' </dev/null"; [ "$probe_result" = 0 ]; }
# resolves <pod> <name> [<server>]: succeeds when the worker resolves the name.
resolves() { probe "$1" "timeout 8 nslookup '$2' $3"; [ "$probe_result" = 0 ]; }
# service_address <namespace> <service>: its ClusterIP.
service_address() { kubectl -n "$1" get service "$2" -o jsonpath='{.spec.clusterIP}'; }

# The node's state that a leaked network would change, read through docker from the k3d server node named by the
# sourcing script's variable server. A reader that fails ends the cell naming itself; callers read it with a plain
# assignment followed by `|| exit 1`, since a failing substitution inside another command is not an error.
# shellcheck disable=SC2154 # server is the sourcing script's.
node() { docker exec "$server" "$@"; }
crictl() { node crictl "$@"; }
# find_lease_directory: sets lease_directory, which the node must hold as the one directory of address leases, so that a
# wrong path cannot make a comparison pass.
find_lease_directory() {
  lease_directory="$(node sh -c 'ls -d /var/lib/cni/networks/*/')" ||
    fail "the node holds no address lease directory under /var/lib/cni/networks"
  [ "$(wc -l <<<"$lease_directory")" = 1 ] || fail "the node holds several lease directories: $(tr '\n' ' ' <<<"$lease_directory")"
}
reader_failed() { fail "the reader '$1' of the node's state failed" >&2; }
leases() {
  local listing
  listing="$(node ls -1A "$lease_directory" | { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || [ $? = 1 ]; } | sort)" || reader_failed leases
  [ -z "$listing" ] || printf '%s\n' "$listing"
}
veths() {
  local listing
  listing="$(node ip -o link | sed -n 's/^[0-9]*: \(veth[^:@ ]*\).*/\1/p' | sort)" || reader_failed veths
  [ -z "$listing" ] || printf '%s\n' "$listing"
}
# sandboxes [<pod>]: the ids of the Namespace's sandboxes, of one Pod's when it is named.
# shellcheck disable=SC2120 # the sourcing scripts name the Pod.
sandboxes() {
  local listing
  listing="$(crictl pods --namespace "$namespace" ${1:+--label "io.kubernetes.pod.name=$1"} -q | sort)" || reader_failed sandboxes
  [ -z "$listing" ] || printf '%s\n' "$listing"
}
iptables_rules() {
  node sh -c 'PATH="$PATH:/var/lib/rancher/k3s/data/current/bin/aux:/var/lib/rancher/k3s/data/current/bin"
    iptables-save' || reader_failed iptables_rules
}
cni_rules() {
  local listing
  listing="$(iptables_rules | { grep -F 'CNI-' || [ $? = 1 ]; } | sort)" || reader_failed cni_rules
  [ -z "$listing" ] || printf '%s\n' "$listing"
}
node_state() {
  local lease_list veth_list sandbox_list rule_list
  lease_list="$(leases)" || exit 1
  veth_list="$(veths)" || exit 1
  # shellcheck disable=SC2119 # all sandboxes of the Namespace.
  sandbox_list="$(sandboxes)" || exit 1
  rule_list="$(cni_rules)" || exit 1
  printf 'leases:\n%s\nveths:\n%s\nsandboxes:\n%s\nrules:\n%s\n' "$lease_list" "$veth_list" "$sandbox_list" "$rule_list"
}
