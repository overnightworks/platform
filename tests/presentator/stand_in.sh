# shellcheck shell=bash
# Sourced by the cells that load into presentator's database: applies tests/presentator/stand_in as a throwaway Flux
# Kustomization named presentator, so the commands under test suspend and resume a real one, and removes it with the claim
# database, which Flux never prunes, on the cell's exit.
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

# apply_stand_in: the Kustomization is applied and Ready, so the web and the claim exist.
apply_stand_in() {
  kubectl apply -f - <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: presentator
  namespace: flux-system
spec:
  dependsOn:
    - name: platform-secrets
    - name: admission
  interval: 10m0s
  path: ./tests/presentator/stand_in
  prune: true
  wait: true
  timeout: 10m0s
  sourceRef:
    kind: GitRepository
    name: flux-system
YAML
  kubectl --namespace flux-system wait kustomization/presentator --for=condition=Ready --timeout=12m
}

# remove_stand_in: for the cell's exit trap, which ends with end_deletions.
remove_stand_in() {
  flux resume kustomization presentator >/dev/null 2>&1 || true
  delete_object --namespace flux-system delete kustomization presentator --ignore-not-found --wait --timeout=5m
  delete_object --namespace presentator delete pvc database --ignore-not-found --wait --timeout=2m
}
