# shellcheck shell=bash
# Sourced by the scripts under tests/nvidia/.
# gpu_pod <name> <image>: a Pod that meets Pod Security restricted at uid 1000, names the RuntimeClass nvidia, limits
# nvidia.com/gpu to 1 and runs nvidia-smi -L, which the runtime injects into the container.
gpu_pod() {
  NAME="$1" IMAGE="$2" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME)},
     "spec": {"runtimeClassName": "nvidia", "restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "list", "image": strenv(IMAGE), "command": ["/usr/bin/nvidia-smi", "-L"],
         "env": [{"name": "NVIDIA_DRIVER_CAPABILITIES", "value": "utility"}],
         "resources": {"limits": {"nvidia.com/gpu": 1}},
         "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]}}'
}
