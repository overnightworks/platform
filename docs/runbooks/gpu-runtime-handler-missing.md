# Runbook: GPU runtime handler missing

Symptom: the Pod events of NVIDIA's device plugin in namespace `nvidia` name a missing runtime handler.
Impact: the node offers no `nvidia.com/gpu`, so no workload gets the card.

## Check

1. An agent: `mise exec -- tests/nvidia/restricted_pod_lists_the_card.sh`. It passes when the node offers
   `nvidia.com/gpu` 1 and a `restricted` Pod with the class and the limit lists exactly one card.

## Fix

`host/k3s/config.yaml` keeps `runtimes` disabled: k3s adds containerd's `nvidia` runtime only when it starts with
the NVIDIA container toolkit present.

1. The operator: `sudo systemctl restart k3s`, once. It does not touch Docker.
2. An agent: the check's step 1 again. It passes.

Rollback: none needed.

## Escalate

The check still fails after the restart: the operator checks that the NVIDIA container toolkit is on the host. No
shipped command checks it.
