# shellcheck shell=bash
# Sourced by the cells that load into presentator's database: points the layer's Kustomization presentator at
# tests/presentator/stand_in, so the commands under test suspend and resume the real one over a web that holds no database
# open, and removes it with the claim database, which Flux never prunes, on the cell's exit. The job's root
# is suspended meanwhile, since it would put the layer's own path back, and resumed last, so it puts the layer back, which
# the cell then waits for: the next cell takes the node's state, which a layer still starting would change.
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

# apply_stand_in: the Kustomization is applied and Ready for the applied generation, so the web and the claim exist. A
# Ready=True left by the previous path would satisfy the wait before the controller has seen the new one, hence the
# wait for the applied generation to be observed first.
apply_stand_in() {
  local generation
  flux suspend kustomization flux-system >/dev/null
  # A reconcile of the root already running ends first, since it would put the layer's own path back over the stand-in.
  kubectl --namespace flux-system wait kustomization/flux-system --for=condition=Ready --timeout=4m ||
    fail "within the time: no reconcile of the root Kustomization flux-system is running"
  generation="$(kubectl apply --output jsonpath='{.metadata.generation}' -f - <<'YAML'
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
  timeout: 3m0s
  sourceRef:
    kind: GitRepository
    name: flux-system
YAML
  )" || fail "kubectl apply of the stand-in Kustomization presentator failed"
  [[ "$generation" =~ ^[0-9]+$ ]] || fail "the applied stand-in Kustomization presentator names no generation: '$generation'"
  kubectl --namespace flux-system wait kustomization/presentator \
    --for=jsonpath="{.status.observedGeneration}=$generation" --timeout=4m &&
    kubectl --namespace flux-system wait kustomization/presentator --for=condition=Ready --timeout=4m ||
    { show_why_the_stand_in_is_not_ready; fail "within the time: the stand-in Kustomization presentator is Ready"; }
}

# show_why_the_stand_in_is_not_ready: the Kustomization's verdict, the namespace's Pods and its Warning events, which
# name a mount or pull error that the wait's timeout does not; names, statuses and messages only.
show_why_the_stand_in_is_not_ready() {
  kubectl --namespace flux-system get kustomization presentator \
    --output jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.reason}: {.message}{"\n"}{end}' || true
  kubectl --namespace presentator get pods || true
  kubectl --namespace presentator get events --field-selector type=Warning \
    --output custom-columns=OBJECT:.involvedObject.name,REASON:.reason,MESSAGE:.message || true
}

# remove_stand_in: for the cell's exit trap, which ends with end_deletions, after the cell removed its own Pods that mount
# the claim: a claim stays Terminating while any Pod uses it. It ends once the layer the root puts back is Ready at the
# revision the root applied and its workloads are rolled out, so no Pod, sandbox or lease is still being made.
remove_stand_in() {
  local revision
  flux resume kustomization presentator >/dev/null 2>&1 || true
  delete_object --namespace flux-system delete kustomization presentator --ignore-not-found --wait --timeout=5m
  delete_object --namespace presentator delete pvc database --ignore-not-found --wait --timeout=2m
  if ! flux resume kustomization flux-system >/dev/null; then
    echo "::error::resuming the root Kustomization flux-system failed"
    deletion_failures=$((deletion_failures + 1))
    return
  fi
  if ! revision="$(kubectl --namespace flux-system get kustomization flux-system --output jsonpath='{.status.lastAppliedRevision}')" ||
    ! kubectl --namespace flux-system wait kustomization/presentator --for=create --timeout=2m ||
    ! kubectl --namespace flux-system wait kustomization/presentator \
      --for=jsonpath="{.status.lastAppliedRevision}=$revision" --timeout=10m ||
    ! kubectl --namespace flux-system wait kustomization/presentator --for=condition=Ready --timeout=4m ||
    ! kubectl --namespace presentator rollout status deployment/web --timeout=4m ||
    ! kubectl --namespace presentator rollout status statefulset/build-worker --timeout=4m; then
    echo "::error::within the time: the layer presentator the root put back is Ready at '$revision' and its workloads are rolled out"
    deletion_failures=$((deletion_failures + 1))
  fi
}
