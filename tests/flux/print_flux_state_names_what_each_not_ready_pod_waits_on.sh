#!/usr/bin/env bash
# Drive print_flux_state.sh against fake kubectl, flux, docker and sudo, all first on PATH, in the shape of a runner
# stall: a Pod behind a claim whose provisioning failed, a Pod whose pull has begun and not ended, a Ready Pod and a
# finished one. The report names the unbound claim with its event and the pull with its seconds, leaves the Ready and the
# finished Pod out, and reads no Secret; when the API answers EOF it still prints the node's state first.
# Usage: mise exec -- tests/flux/print_flux_state_names_what_each_not_ready_pod_waits_on.sh
set -euo pipefail

# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
print_flux_state="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/print_flux_state.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
mkdir "$fake_bin"

# The pull began 300 seconds before the report; the other times are fixed.
pull_began="$(date -u --date "@$(($(date +%s) - 300))" '+%Y-%m-%dT%H:%M:%SZ')"
cat >"$scratch/cluster.json" <<JSON
{"apiVersion": "v1", "kind": "List", "items": [
  {"kind": "Pod", "metadata": {"namespace": "objectstore", "name": "garage-0"},
   "spec": {"volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "data-garage-0"}}]},
   "status": {"phase": "Pending", "conditions": [{"type": "PodScheduled", "status": "False", "reason": "Unschedulable"}]}},
  {"kind": "PersistentVolumeClaim", "metadata": {"namespace": "objectstore", "name": "data-garage-0"},
   "status": {"phase": "Pending"}},
  {"kind": "Event", "metadata": {"namespace": "objectstore", "name": "data-garage-0.1"}, "type": "Warning",
   "reason": "ProvisioningFailed", "lastTimestamp": "2026-11-27T10:00:00Z",
   "message": "failed to provision volume: create process timeout after 120 seconds",
   "involvedObject": {"kind": "PersistentVolumeClaim", "namespace": "objectstore", "name": "data-garage-0"}},
  {"kind": "Pod", "metadata": {"namespace": "songmaker", "name": "scoring-worker-7"},
   "spec": {"volumes": []},
   "status": {"phase": "Pending", "containerStatuses": [{"name": "worker", "state": {"waiting": {"reason": "ContainerCreating"}}}]}},
  {"kind": "Event", "metadata": {"namespace": "songmaker", "name": "scoring-worker-7.1"}, "type": "Normal",
   "reason": "Pulling", "lastTimestamp": "$pull_began", "message": "Pulling image \"ghcr.io/example/scoring-worker:4\"",
   "involvedObject": {"kind": "Pod", "namespace": "songmaker", "name": "scoring-worker-7"}},
  {"kind": "Pod", "metadata": {"namespace": "web", "name": "web-0"}, "spec": {"volumes": []},
   "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}},
  {"kind": "Event", "metadata": {"namespace": "web", "name": "web-0.1"}, "type": "Normal", "reason": "Pulling",
   "lastTimestamp": "$pull_began", "message": "Pulling image \"ghcr.io/example/web:1\"",
   "involvedObject": {"kind": "Pod", "namespace": "web", "name": "web-0"}},
  {"kind": "Pod", "metadata": {"namespace": "web", "name": "migrate-x"}, "spec": {"volumes": []},
   "status": {"phase": "Succeeded", "conditions": [{"type": "Ready", "status": "False"}]}}
]}
JSON

cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/kubectl-calls"
case "$*" in
  *[Ss]ecret*) echo "$*" >>"$FAKE_DIR/secret-reads"; echo "the fake kubectl refuses a Secret read" >&2; exit 99 ;;
esac
if [ -e "$FAKE_DIR/api-gone" ]; then echo "Unable to connect to the server: EOF" >&2; exit 1; fi
case "$*" in
  "get pods,persistentvolumeclaims,events --all-namespaces --output json") cat "$FAKE_DIR/cluster.json" ;;
esac
FAKE
cat >"$fake_bin/flux" <<'FAKE'
#!/usr/bin/env bash
if [ -e "$FAKE_DIR/api-gone" ]; then echo "Unable to connect to the server: EOF" >&2; exit 1; fi
FAKE
cat >"$fake_bin/docker" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = inspect ] || { echo "the fake docker answers only inspect" >&2; exit 97; }
echo "exited exit=137 oomkilled=true"
FAKE
cat >"$fake_bin/sudo" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = dmesg ] || { echo "the fake sudo runs only dmesg" >&2; exit 97; }
echo "Out of memory: Killed process 4242 (containerd)"
FAKE
chmod +x "$fake_bin"/*

# report <scenario>: the report's output on its standard output and error together, whatever its exit status.
report() {
  rm -f "$scratch/api-gone" "$scratch/kubectl-calls" "$scratch/secret-reads"
  [ "$1" != api-gone ] || : >"$scratch/api-gone"
  PATH="$fake_bin:$PATH" FAKE_DIR="$scratch" MISE_DISABLE_TOOLS=kubectl,flux KUBECONFIG=/nonexistent \
    CLUSTER_NAME=platform "$print_flux_state" 2>&1 || true
}
expect_line() { grep -qE -- "$2" <<<"$1" || fail "the report lacks a line like '$2'; it printed: $1"; }
reject_line() { ! grep -qE -- "$2" <<<"$1" || fail "the report holds a line like '$2'; it printed: $1"; }

output="$(report api-up)"
expect_line "$output" 'objectstore/garage-0.*Pending'
expect_line "$output" 'claim data-garage-0 is Pending.*ProvisioningFailed.*create process timeout after 120 seconds'
expect_line "$output" 'songmaker/scoring-worker-7.*ContainerCreating'
expect_line "$output" 'pulling ghcr.io/example/scoring-worker:4 for 30[0-9] s'
reject_line "$output" 'web/web-0|web/migrate-x'
[ ! -e "$scratch/secret-reads" ] || fail "the report asked kubectl for a Secret: $(cat "$scratch/secret-reads")"
echo "the report names the claim with its reason and the pull with its seconds, and reads no Secret"

output="$(report api-gone)"
expect_line "$output" 'node container.*exited exit=137 oomkilled=true'
expect_line "$output" 'Killed process 4242'
[ ! -e "$scratch/kubectl-calls" ] || fail "the report called kubectl before the node's state: $(cat "$scratch/kubectl-calls")"
echo "the node's state prints before any kubectl call, with the API answering EOF"
