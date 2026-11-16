# shellcheck shell=bash
# Sourced by the cells that read the node's state through docker from the k3d server node named by the sourcing script's
# variable server. A reader that fails ends the cell naming itself; callers read it with a plain assignment followed by
# `|| exit 1`, since a failing substitution inside another command is not an error.
# shellcheck disable=SC2154 # server and namespace are the sourcing script's.
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
#
