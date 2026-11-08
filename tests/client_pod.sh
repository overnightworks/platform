# shellcheck shell=bash
# Sourced by the scripts under tests/ that send requests from client Pods built from CLIENT_POD with CLIENT_IMAGE.
# shellcheck source=failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/failure.sh"

# request <namespace> <name> <host> <url> [<curl argument>...]: a client Pod in the namespace asks the URL with
# the host and the further arguments, runs to its end and is deleted; sets status to the statuses it printed
# and exit_code to curl's.
# shellcheck disable=SC2034 # status and exit_code are the results the sourcing script reads.
request() {
  local namespace="$1" name="$2" host="$3" url="$4" client_pod
  shift 4
  client_pod="${CLIENT_POD//@IMAGE@/${CLIENT_IMAGE}}"
  client_pod="${client_pod//@NAME@/${name}}"
  client_pod="${client_pod//@HOST@/${host}}"
  client_pod="${client_pod//@URL@/${url}}"
  if [ "$#" -gt 0 ]; then
    client_pod="$(CURL_ARGUMENTS="$(printf '%s\n' "$@")" yq '.spec.containers[0].args += (strenv(CURL_ARGUMENTS) | split("\n"))' <<<"$client_pod")"
  fi
  printf '%s\n' "$client_pod" | kubectl -n "$namespace" create -f -
  kubectl -n "$namespace" wait "pod/$name" --timeout=2m \
    --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' || {
    kubectl -n "$namespace" describe "pod/$name"
    fail "the client Pod $name in $namespace did not run to its end"
  }
  exit_code="$(kubectl -n "$namespace" get "pod/$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  status="$(kubectl -n "$namespace" logs "pod/$name")"
  kubectl -n "$namespace" delete pod "$name" --wait --timeout=2m
}
