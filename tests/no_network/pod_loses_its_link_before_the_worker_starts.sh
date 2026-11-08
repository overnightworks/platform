#!/usr/bin/env bash
# pod_loses_its_link_before_the_worker_starts.sh: in k3d, shows that a Pod whose init container remove-link deletes its
# link holds lo alone in the worker, reaches nothing, works as a Pod does, fails closed, survives a restart and a removed
# sandbox, and that twelve lives of such Pods leave the node's address leases, veth links, sandboxes and CNI rules as
# they were, which the same lives without the init container do too. It needs CLUSTER_NAME, PROBE_IMAGE and
# NO_NETWORK_NAMESPACE, a Namespace without a Pod Security label that it creates and deletes.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/pod.sh"
namespace="$NO_NETWORK_NAMESPACE"
server="k3d-${CLUSTER_NAME}-server-0"
started_at=$SECONDS
created_namespace=false
remove_objects() {
  local cell_status=$?
  if $created_namespace; then
    delete_object delete namespace --wait --timeout=2m "$namespace"
  fi
  end_deletions "$cell_status"
}
trap remove_objects EXIT
"$(dirname "${BASH_SOURCE[0]}")/remove_link_branches.sh"

node() { docker exec "$server" "$@"; }
crictl() { node k3s crictl "$@"; }
k() { kubectl -n "$namespace" "$@"; }
grace='.spec.terminationGracePeriodSeconds = 2'

# The node's state that a leaked network would change. The lease directory is read from the node and must be there,
# so that a wrong path cannot make the comparison pass.
lease_directory="$(node sh -c 'ls -d /var/lib/cni/networks/*/')" ||
  fail "the node holds no address lease directory under /var/lib/cni/networks"
[ "$(wc -l <<<"$lease_directory")" = 1 ] || fail "the node holds several lease directories: $(tr '\n' ' ' <<<"$lease_directory")"
leases() {
  node ls -1A "$lease_directory" | { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || [ $? = 1 ]; } | sort
}
veths() { node ip -o link | sed -n 's/^[0-9]*: \(veth[^:@ ]*\).*/\1/p' | sort; }
sandboxes() { crictl pods --namespace "$namespace" -q | sort; }
cni_rules() {
  node sh -c 'PATH="$PATH:/var/lib/rancher/k3s/data/current/bin/aux:/var/lib/rancher/k3s/data/current/bin"
    iptables-save' | { grep -F 'CNI-' || [ $? = 1 ]; } | sort
}
node_state() { printf 'leases:\n%s\nveths:\n%s\nsandboxes:\n%s\nrules:\n%s\n' "$(leases)" "$(veths)" "$(sandboxes)" "$(cni_rules)"; }
[ -n "$(leases)" ] || fail "the lease directory $lease_directory holds no lease although pods run on the node"
cni_rules >/dev/null

# wait_for <description> <command>...: retries the command for 2 minutes.
wait_for() {
  local description="$1"
  shift
  for _ in $(seq 60); do
    if "$@"; then return 0; fi
    sleep 2
  done
  fail "$description did not happen within 2 minutes"
}
no_sandbox_of_the_namespace() { [ -z "$(sandboxes)" ]; }
delete_pods() {
  k delete pod --all --wait --timeout=2m
  wait_for "the removal of the namespace's sandboxes" no_sandbox_of_the_namespace
}
status_of() { k get "pod/$1" -o jsonpath="$2"; }

kubectl create namespace "$namespace"
created_namespace=true
k wait serviceaccount/default --for=create --timeout=1m
k create configmap probe --from-literal=message=config-readable

# The Pod of cells 1 to 4: an exec probe, an emptyDir written and read, a ConfigMap read, and stdout in the log.
# The ConfigMap value has no newline and the runtime logs a line only at its newline, so the worker ends it with one.
worker_works='.spec.volumes = [{"name": "scratch", "emptyDir": {}}, {"name": "config", "configMap": {"name": "probe"}}]
  | .spec.containers[0].volumeMounts = [{"name": "scratch", "mountPath": "/scratch"}, {"name": "config", "mountPath": "/config"}]
  | .spec.containers[0].command = ["sh", "-c", "echo scratch-readable > /scratch/f; cat /scratch/f; cat /config/message; echo; sleep 3600"]
  | .spec.containers[0].readinessProbe = {"exec": {"command": ["true"]}, "periodSeconds": 2}'

# Cell 1, 2 and 4: the isolated Pod.
create_pod isolated init "$grace | $worker_works"
k wait pod/isolated --for=condition=Ready --timeout=3m
[ "$(link_names isolated)" = lo ] || fail "the worker's links are '$(link_names isolated | tr '\n' ' ')', not lo alone"
addresses="$(in_worker isolated ip -o addr | awk '{print $3, $4}' | sort)"
[ "$addresses" = "$(printf 'inet 127.0.0.1/8\ninet6 ::1/128')" ] ||
  fail "the worker's addresses are '$(tr '\n' ' ' <<<"$addresses")', not exactly 127.0.0.1/8 and ::1/128"
for family in -4 -6; do
  routes="$(in_worker isolated ip "$family" route show table all)"
  [ -n "$routes" ] || fail "the worker holds no route of family $family: the inspection shows nothing"
  [ -z "$(grep -v ' dev lo ' <<<"$routes")" ] || fail "the worker holds a route of family $family beside lo's: $(grep -v ' dev lo ' <<<"$routes")"
done
echo "the worker holds lo alone with 127.0.0.1/8 and ::1/128 and only lo's routes"

api_address="$(service_address default kubernetes)"
dns_address="$(service_address kube-system kube-dns)"
node_address="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
bridge_address="$(node ip -o -6 addr show dev cni0 | awk '{print $4}' | sed -n 's|^\(fe80:[^/]*\)/.*|\1|p' | head -n 1)"
[ -n "$api_address" ] && [ -n "$dns_address" ] && [ -n "$node_address" ] || fail "an address to probe is missing"
[ -n "$bridge_address" ] || fail "the node's cni0 holds no fe80 address"
! reaches isolated "$api_address" 443 || fail "the worker reached the API's ClusterIP $api_address"
! resolves isolated kubernetes.default.svc.cluster.local "$dns_address" || fail "the worker resolved a name at cluster DNS $dns_address"
! reaches isolated "$node_address" 10250 || fail "the worker reached the node's address $node_address"
for scope in cni0 lo; do
  ! reaches isolated "$bridge_address%$scope" 10250 || fail "the worker reached the node's cni0 address $bridge_address with scope $scope"
done
! reaches isolated 1.1.1.1 443 || fail "the worker reached the outside address 1.1.1.1"
control="$(in_worker isolated sh -c '(echo pong | nc -l -s 127.0.0.1 -p 9000 &); sleep 1; nc -w 3 127.0.0.1 9000 </dev/null')"
[ "$control" = pong ] || fail "the listener on 127.0.0.1 inside the Pod was not reached"
echo "the worker reaches none of the API, DNS, the node, its cni0 address and an outside address, and its own 127.0.0.1 listener"

logs="$(k logs pod/isolated -c worker)"
[ "$logs" = "$(printf 'scratch-readable\nconfig-readable')" ] || fail "the worker's log is '$logs', not what it wrote and read"
echo "the exec probe passed, stdout reached the log, the emptyDir and the ConfigMap read"

# Cell 3: the same Pod without the init container.
create_pod default none "$grace | $worker_works"
k wait pod/default --for=condition=Ready --timeout=3m
[ "$(link_names default | tr '\n' ' ')" = 'eth0 lo ' ] || fail "the default Pod's links are '$(link_names default | tr '\n' ' ')', not eth0 and lo"
default_routes="$(in_worker default ip -4 route show)"
grep -q '^default ' <<<"$default_routes" || fail "the default Pod holds no default route"
reaches default "$api_address" 443 || fail "the default Pod did not reach the API's ClusterIP"
resolves default kubernetes.default.svc.cluster.local "$dns_address" || fail "the default Pod did not resolve a name at cluster DNS"
echo "the default Pod holds eth0 and a default route and reaches the API and DNS"
delete_pods

# Cell 5: the program run twice by two init containers of one Pod.
create_pod twice init "$grace | .spec.initContainers += [.spec.initContainers[0] * {\"name\": \"remove-link-again\"}]"
k wait pod/twice --for=condition=Ready --timeout=3m
[ "$(status_of twice '{.status.initContainerStatuses[*].state.terminated.exitCode}')" = '0 0' ] ||
  fail "the two init containers did not both end 0"
[ "$(link_names twice)" = lo ] || fail "the twice-run Pod's worker does not hold lo alone"
echo "the program ran twice in one Pod and ended 0 both times"
delete_pods

# Cell 6: fail closed.
failed_closed() {
  local pod="$1" init_codes="$2"
  k wait "pod/$pod" --for=jsonpath='{.status.phase}'=Failed --timeout=3m
  [ "$(status_of "$pod" '{.status.initContainerStatuses[*].state.terminated.exitCode}' | tr ' ' ,)" = "$init_codes" ] ||
    fail "the init containers of $pod ended '$(status_of "$pod" '{.status.initContainerStatuses[*].state.terminated.exitCode}')', not $init_codes"
  [ "$(status_of "$pod" '{.status.containerStatuses[0].state.waiting.reason}')" = PodInitializing ] ||
    fail "the worker of $pod is not still waiting for its init containers"
}
create_pod without-capability init "$grace | .spec.restartPolicy = \"Never\" | .spec.initContainers[0].securityContext.capabilities.add = []"
failed_closed without-capability 1
create_pod second-link init "$grace | .spec.restartPolicy = \"Never\" | .spec.initContainers = [.spec.initContainers[0]
  * {\"name\": \"add-link\", \"command\": [\"sh\", \"-c\", \"ip link add dummy0 type dummy\"]}] + .spec.initContainers"
failed_closed second-link 0,1
echo "the worker did not start without NET_ADMIN, nor beside a second link"
delete_pods

# Cell 7: a restarted worker and a removed sandbox.
# The worker exits once, on its first start; the emptyDir outlives the container, not the Pod.
create_pod restarting init "$grace | $worker_works | .spec.containers[0].command = [\"sh\", \"-c\",
  \"if [ -e /scratch/seen ]; then exec sleep 3600; fi; touch /scratch/seen; sleep 3\"]"
k wait pod/restarting --for=condition=Ready --timeout=3m
sandbox_before="$(sandboxes)"
init_before="$(status_of restarting '{.status.initContainerStatuses[0].containerID}')"
k wait pod/restarting --for=jsonpath='{.status.containerStatuses[0].restartCount}'=1 --timeout=3m
k wait pod/restarting --for=condition=Ready --timeout=3m
[ "$(sandboxes)" = "$sandbox_before" ] || fail "the restarted worker is in another sandbox"
[ "$(status_of restarting '{.status.initContainerStatuses[0].containerID}')" = "$init_before" ] ||
  fail "the init container ran again for a restart in the same sandbox"
[ "$(link_names restarting)" = lo ] || fail "the restarted worker does not hold lo alone"
echo "the worker restarted in its sandbox and holds lo alone"
delete_pods

create_pod recreated init "$grace"
k wait pod/recreated --for=condition=Ready --timeout=3m
old_sandbox="$(sandboxes)"
[ -n "$old_sandbox" ] && [ "$(wc -l <<<"$old_sandbox")" = 1 ] || fail "the Pod holds no single sandbox: '$old_sandbox'"
old_init="$(status_of recreated '{.status.initContainerStatuses[0].containerID}')"
crictl stopp "$old_sandbox"
crictl rmp "$old_sandbox"
sandbox_recreated() {
  [ "$(sandboxes)" != "$old_sandbox" ] && [ -n "$(sandboxes)" ] &&
    [ "$(status_of recreated '{.status.initContainerStatuses[0].containerID}')" != "$old_init" ] &&
    [ "$(status_of recreated '{.status.containerStatuses[0].ready}')" = true ]
}
wait_for "the recreation of the removed sandbox with its init container run again" sandbox_recreated
[ "$(status_of recreated '{.status.initContainerStatuses[0].state.terminated.exitCode}')" = 0 ] ||
  fail "the init container of the recreated sandbox did not end 0"
[ "$(link_names recreated)" = lo ] || fail "the worker in the recreated sandbox does not hold lo alone"
echo "a removed sandbox was recreated, the init container ran again and the worker holds lo alone"
delete_pods

# Cell 8: twelve lives; the control first, so that the comparison is shown to see a Pod that lives.
new_lease() { [ -n "$(comm -13 <(printf '%s\n' "$1") <(leases))" ]; }
life() {
  local mode="$1" kind="$2" name="$3" filter="$grace" before_leases
  case "$kind" in
    hold) filter+=' | .spec.initContainers += [{"name": "hold", "image": strenv(PROBE_IMAGE), "command": ["sleep", "3600"],
      "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]' ;;
    crash) filter+=' | .spec.restartPolicy = "Never" | .spec.containers[0].command = ["sh", "-c", "exit 1"]' ;;
  esac
  before_leases="$(leases)"
  create_pod "$name" "$mode" "$filter"
  case "$kind" in
    hold) k wait "pod/$name" --timeout=3m \
      --for=jsonpath='{.status.initContainerStatuses[?(@.name=="hold")].state.running.startedAt}' ;;
    crash) k wait "pod/$name" --for=jsonpath='{.status.phase}'=Failed --timeout=3m ;;
    *) k wait "pod/$name" --for=condition=Ready --timeout=3m ;;
  esac
  new_lease "$before_leases" || fail "no address lease was taken while $name lived ($mode, $kind)"
  case "$kind" in
    force) k delete "pod/$name" --force --grace-period=0 ;;
    *) k delete "pod/$name" --wait --timeout=2m ;;
  esac
}
lives() {
  local mode="$1" before after
  before="$(node_state)"
  for kind in normal normal normal normal force force force hold hold hold crash crash; do
    lives_made=$((lives_made + 1))
    life "$mode" "$kind" "life-$lives_made"
  done
  wait_for "the removal of the namespace's sandboxes" no_sandbox_of_the_namespace
  for _ in $(seq 45); do
    after="$(node_state)"
    [ "$after" = "$before" ] && break
    sleep 2
  done
  [ "$after" = "$before" ] || {
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true
    fail "the node's state after 12 lives ($mode) differs from before"
  }
  echo "12 lives ($mode) left the node's leases, veths, sandboxes and CNI rules as they were"
}
lives_made=0
lives none
lives init

echo "no_network cell ended after $((SECONDS - started_at)) seconds"
