#!/usr/bin/env bash
# The Jobs bridge (layer speech-runtime-bridge) and settle (layer speech-runtime) carry the GPU image that the Deployment
# speech-runtime-gpu renders in the annotation gpu-image of their pod template, so a new release changes both templates and
# Flux re-creates them; neither Job runs an image of the app, so neither needs a pull layer; each mounts one ConfigMap that
# its own layer renders from the one script file; each fails its Job at once on any non-zero exit of its script, so a Job
# decides in one pod and backoffLimit covers a lost pod only; and the two layers render no object in common, so every object has one layer.
# Usage: mise exec -- tests/speech_runtime/both_jobs_carry_the_rendered_gpu_release.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
cd "$repository_root"

runtime_layer="$(kubectl kustomize apps/speech-runtime)"
bridge_layer="$(kubectl kustomize apps/speech-runtime/bridge)"
script_file=apps/speech-runtime/bridge/scripts/speech_bridge.sh

# image_of <layer render> <Deployment>: the image the layer renders for the Deployment.
image_of() {
  NAME="$2" yq 'select(.kind == "Deployment" and .metadata.name == strenv(NAME)) | .spec.template.spec.containers[0].image' <<<"$1"
}
gpu_image="$(image_of "$runtime_layer" speech-runtime-gpu)"
cpu_image="$(image_of "$runtime_layer" speech-runtime)"
[ -n "$gpu_image" ] && [ -n "$cpu_image" ] || fail "the layer speech-runtime renders no image for a Deployment"
app_repository="${gpu_image%%:*}"
[ "${cpu_image%%:*}" = "$app_repository" ] || fail "the two Deployments run images of two repositories"

# job_query <layer render> <Job> <yq expression on the Job>
job_query() { NAME="$2" yq "select(.kind == \"Job\" and .metadata.name == strenv(NAME)) | $3" <<<"$1"; }

# judge <layer render> <Job> <layer name>
judge() {
  local annotation image script_map
  annotation="$(job_query "$1" "$2" '.spec.template.metadata.annotations["gpu-image"]')"
  [ "$annotation" = "$gpu_image" ] || fail "the Job $2 of $3 carries the GPU image '$annotation', not the Deployment's '$gpu_image'"
  while IFS= read -r image; do
    [[ "$image" != "$app_repository"* ]] || fail "the Job $2 of $3 runs the image $image of the app"
  done < <(job_query "$1" "$2" '.spec.template.spec | ((.containers // []) + (.initContainers // []))[].image, ((.volumes // [])[] | select(.image) | .image.reference)')
  [ "$(job_query "$1" "$2" '.spec.template.spec.volumes | map(select(.configMap)) | length')" -eq 1 ] ||
    fail "the Job $2 of $3 does not mount exactly one ConfigMap"
  script_map="$(job_query "$1" "$2" '.spec.template.spec.volumes[] | select(.configMap) | .configMap.name')"
  [ "$(NAME="$script_map" yq 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["speech_bridge.sh"]' <<<"$1")" = "$(cat "$script_file")" ] ||
    fail "the ConfigMap $script_map of the Job $2 is not rendered by $3 from $script_file"
  [ "$(job_query "$1" "$2" '.spec.podFailurePolicy.rules | map(select(.action == "FailJob" and .onExitCodes.operator == "NotIn" and (.onExitCodes.values | length) == 1 and .onExitCodes.values[0] == 0 and .onExitCodes.containerName == "'"$2"'")) | length')" = 1 ] ||
    fail "the Job $2 of $3 does not fail at once on a non-zero exit of its script"
  [ "$(job_query "$1" "$2" '.spec.podFailurePolicy.rules | length')" -eq 1 ] || fail "the Job $2 of $3 carries a pod failure rule besides the one for its script"
  echo "the Job $2 of $3 carries the GPU image $gpu_image, runs no image of the app and mounts $script_map, rendered from $script_file"
}
judge "$bridge_layer" bridge speech-runtime-bridge
judge "$runtime_layer" settle speech-runtime

# objects <layer render>: kind, namespace and name of each object, sorted.
objects() { yq --no-doc '.kind + " " + (.metadata.namespace // "") + " " + .metadata.name' <<<"$1" | LC_ALL=C sort; }
shared="$(LC_ALL=C comm -12 <(objects "$bridge_layer") <(objects "$runtime_layer"))"
[ -z "$shared" ] || fail "the layers speech-runtime-bridge and speech-runtime both render: ${shared//$'\n'/, }"
echo "the layers speech-runtime-bridge and speech-runtime render no object in common"
