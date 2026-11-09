#!/usr/bin/env bash
# rsync's --rsh: runs the command rsync names inside the container `loader` of the Pod `$RSH_POD` in the namespace
# `$RSH_NAMESPACE`, with stdin and stdout as rsync's channel. rsync passes the host it was given first; it names
# nothing here, the Pod comes from the environment.
# Usage: rsync -e scripts/rsh_into_pod.sh <source>/ loader:<target>/
set -euo pipefail
shift
exec kubectl --namespace "${RSH_NAMESPACE?}" exec --stdin "${RSH_POD?}" --container loader -- "$@"
