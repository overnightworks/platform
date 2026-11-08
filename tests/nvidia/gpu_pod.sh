# shellcheck shell=bash
# Sourced by the scripts under tests/nvidia/.
# runtime_class_field <yq path>: that field (.metadata.name or .handler) of the RuntimeClass the layer commits, which
# owns both.
runtime_class_field() {
  yq "select(.kind == \"RuntimeClass\") | $1" "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/nvidia/nvidia.yaml"
}
# gpu_pod <name> <image> <RuntimeClass>: a Pod that meets Pod Security restricted at uid 1000, names the RuntimeClass,
# limits nvidia.com/gpu to 1 and runs nvidia-smi -L, which the runtime injects into the container.
gpu_pod() {
  NAME="$1" IMAGE="$2" CLASS="$3" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
     "spec": {"runtimeClassName": strenv(CLASS), "restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "list", "image": strenv(IMAGE), "command": ["/usr/bin/nvidia-smi", "-L"],
         "env": [{"name": "NVIDIA_DRIVER_CAPABILITIES", "value": "utility"}],
         "resources": {"limits": {"nvidia.com/gpu": 1}},
         "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]}}'
}
