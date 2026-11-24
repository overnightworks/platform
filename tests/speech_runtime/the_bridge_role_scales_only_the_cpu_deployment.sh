#!/usr/bin/env bash
# The Role bridge, which the Jobs bridge and settle run under, grants on a Deployment's scale no verb beyond get and update
# (a scale with a precondition reads and replaces the scale, never patches), and only on the Deployment speech-runtime, never
# on the GPU Deployment speech-runtime-gpu.
# Usage: mise exec -- tests/speech_runtime/the_bridge_role_scales_only_the_cpu_deployment.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
cd "$repository_root"

bridge_layer="$(kubectl kustomize apps/speech-runtime/bridge)"

# scale_rules <yq expression on a rule that grants on a scale>: the rules of the Role that name a scale or any resource.
scale_rules() {
  yq "select(.kind == \"Role\" and .metadata.name == \"bridge\") | .rules[] | select(.resources | map(select(test(\"^(\\\\*|deployments/scale)$\"))) | length > 0) | $1" <<<"$bridge_layer"
}

[ -n "$(scale_rules '.verbs[]')" ] || fail "the Role bridge grants nothing on deployments/scale"
verbs="$(scale_rules '.verbs[]' | LC_ALL=C sort -u | paste -sd, -)"
[ "$verbs" = "get,update" ] || fail "the Role bridge grants '$verbs' on a scale, not get and update only"
names="$(scale_rules '(.resourceNames // ["every name"])[]' | LC_ALL=C sort -u | paste -sd, -)"
[ "$names" = "speech-runtime" ] || fail "the Role bridge grants a scale of '$names', not of speech-runtime only"
echo "the Role bridge reads and replaces the scale of speech-runtime only, never patches it and never scales speech-runtime-gpu"
