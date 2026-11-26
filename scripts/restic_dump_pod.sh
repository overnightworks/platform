#!/usr/bin/env bash
# Usage: scripts/restic_dump_pod.sh <namespace> <pod name> <shell script>
# Prints the manifest of a Pod that runs the shell script in the restic container of the namespace's CronJob
# restore-test (its image at its digest, its environment with the repository credentials, its securityContext and its
# restore volume), and holds no init container and no other volume. The restore test's own dump script, which writes
# the latest dump to /restore/dump, is in the container's environment as RESTORE_TEST_DUMP_SCRIPT, for a script that
# runs it. The one owner of that Pod: `backup:fetch` and the cells under tests/backup/ start it, so the task and the
# cells read a repository the way the monthly restore test does.
set -euo pipefail
namespace="${1?}" name="${2?}" script="${3?}"

kubectl --namespace "$namespace" get cronjob restore-test --output json |
  NAME="$name" SCRIPT="$script" yq --output-format json \
    '.spec.jobTemplate.spec.template.spec as $spec | $spec.initContainers[0] as $dump |
     { "apiVersion": "v1", "kind": "Pod", "metadata": { "name": strenv(NAME) }, "spec": ($spec | del(.initContainers) |
         .volumes |= map(select(.name == "restore")) |
         .containers = [$dump | .env += [{"name": "RESTORE_TEST_DUMP_SCRIPT", "value": .command[-1]}] |
           .name = "restic" | .command = ["sh", "-c", strenv(SCRIPT)]]) } |
     .spec.containers[0].volumeMounts |= map(select(.name == "restore"))'
