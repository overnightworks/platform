#!/usr/bin/env bash
# `mise run admission:pause` and `mise run admission:resume`: the way back from the attestation check of
# infrastructure/app-attestations, which refuses an app Pod whenever Kyverno cannot verify it. The head runs them.
# Pause suspends the Kustomization app-attestations, scales Kyverno's admission controller to 0 and deletes every webhook
# configuration Kyverno manages, its policy webhooks included, in that order; the form rule and the vendor list of
# infrastructure/admission keep reconciling, and every Pod they admit then starts. A repeated or interrupted pause ends
# the same way.
# Resume decides from live state. While the Kustomization app-attestations exists it resumes it, forces a reconcile and
# waits until the controller runs, its webhooks carry the exclusions and both match conditions of the policy and the
# Kustomization is Ready, without any read of GitHub, so it works while GitHub is unreachable. Once the Kustomization is
# gone (the removal pull request landed on a suspended one) it deletes what Flux applied for it and what Kyverno made,
# but only when the root Kustomization has applied main's head, read from GitHub, since an older revision would delete
# Kyverno and the policy while Git still declares them. It never deletes a Namespace and never waits for Ready.
# Usage: scripts/pause_or_resume_attestation_check.sh <pause|resume>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
verb="${1:?usage: pause_or_resume_attestation_check.sh <pause|resume>}"
fail() { echo "admission:$verb: $1; $2" >&2; exit 1; }

flux_namespace=flux-system
layer=app-attestations
root_layer=flux-system
kyverno_namespace=admission
policy=app-attestations
# What the chart and Kyverno label: the admission controller's Pods and Deployment, the webhook configurations the
# controller writes, and the TLS Secrets and the health Lease it creates in its namespace.
controller_selector="app.kubernetes.io/component=admission-controller,app.kubernetes.io/part-of=kyverno"
webhook_selector="webhook.kyverno.io/managed-by=kyverno"
certificate_selector="cert.kyverno.io/managed-by=kyverno"
lease_selector="app.kubernetes.io/name=kyverno"
# The Leases of Kyverno 1.20 by exact name, labelled or not: the admission controller's leader election and its
# health Lease (cmd/kyverno/main.go), the init container's election and its lock (cmd/kyverno-init/main.go) and the
# webhook controller's (pkg/controllers/webhook/controller.go).
kyverno_leases=(kyverno kyvernopre kyvernopre-lock kyverno-health)
# Flux's ownership labels of every object a Kustomization applied.
applied_selector="kustomize.toolkit.fluxcd.io/name=$layer,kustomize.toolkit.fluxcd.io/namespace=$flux_namespace"
wait_seconds="${ADMISSION_WAIT_SECONDS:-300}"
poll_seconds="${ADMISSION_POLL_SECONDS:-3}"
field_manager=flux-client-side-apply
way_back="read the objects with kubectl and run it again"

# wait_until <what> <command>...: the command passes within the wait.
wait_until() {
  local what="$1" deadline=$((SECONDS + wait_seconds))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "$what did not happen within $wait_seconds seconds" "$way_back"
    sleep "$poll_seconds"
  done
}

# A read that fails is no proof of absence: only a successful read that names nothing says the Kustomization is gone.
layer_exists() {
  local names
  names="$(kubectl --namespace "$flux_namespace" get kustomization "$layer" --ignore-not-found --output name)" ||
    fail "the Kustomization $layer cannot be read, so its presence is unknown; nothing changed" "$way_back"
  [ -n "$names" ]
}
# The root Kustomization applies app-attestations on every reconcile and takes over the fields that managers whose name
# starts with kubectl set; flux-client-side-apply is the manager its apply keeps, so a field it owns holds until a
# resume. suspend <json value>: the value of spec.suspend, null for absent as Git declares it.
suspend() {
  kubectl --namespace "$flux_namespace" patch kustomization "$layer" --field-manager="$field_manager" --type merge \
    --patch "{\"spec\":{\"suspend\":$1}}" >/dev/null
}
controller_pods_gone() {
  kubectl wait --namespace "$kyverno_namespace" --for=delete pod --selector "$controller_selector" --timeout=2m >/dev/null
}
delete_webhooks() {
  kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration --selector "$webhook_selector" \
    --ignore-not-found >/dev/null
}

pause() {
  if layer_exists; then suspend true; fi
  kubectl scale deployment --namespace "$kyverno_namespace" --selector "$controller_selector" --replicas=0 >/dev/null
  controller_pods_gone || fail "Kyverno's admission controller pods are still there after 2 minutes" "$way_back"
  delete_webhooks
}

reconciled() { [ "$(kubectl --namespace "$flux_namespace" get kustomization "$layer" --output jsonpath='{.status.lastHandledReconcileAt}')" = "$1" ]; }
layer_ready() {
  [ "$(kubectl --namespace "$flux_namespace" get kustomization "$layer" \
    --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
}
controller_ready() {
  local replicas ready
  replicas="$(kubectl get deployment --namespace "$kyverno_namespace" --selector "$controller_selector" --output jsonpath='{.items[0].spec.replicas}')"
  ready="$(kubectl get deployment --namespace "$kyverno_namespace" --selector "$controller_selector" --output jsonpath='{.items[0].status.readyReplicas}')"
  [ "${replicas:-0}" -gt 0 ] && [ "${ready:-0}" -eq "$replicas" ]
}
# Every webhook that reaches Pods excludes kube-system, flux-system and Kyverno's namespace, fails closed and carries each
# match condition of the live policy, found by its expression containing the policy's own text.
webhooks_judge_app_pods() {
  local expressions
  expressions="$(kubectl get imagevalidatingpolicy "$policy" --output json | jq --compact-output '[.spec.matchConditions[].expression]')"
  kubectl get validatingwebhookconfiguration --selector "$webhook_selector" --output json | jq --exit-status --argjson expressions "$expressions" \
    --arg namespaces "$flux_namespace kube-system $kyverno_namespace" '
      [.items[] | (.webhooks // [])[] | select(any((.rules // [])[].resources[]; . == "pods"))] as $webhooks
      | ($webhooks | length) > 0 and all($webhooks[];
          .failurePolicy == "Fail"
          and ([.namespaceSelector.matchExpressions[]? | select(.operator == "NotIn" and .key == "kubernetes.io/metadata.name") | .values[]] as $excluded
            | all($namespaces | split(" ")[]; . as $namespace | $excluded | index($namespace) != null))
          and ([.matchConditions[]?.expression] as $have
            | all($expressions[]; . as $expression | any($have[]; contains($expression)))))' >/dev/null
}

restore() {
  local token
  token="$(date +%s%N)"
  suspend null
  kubectl --namespace "$flux_namespace" annotate kustomization "$layer" "reconcile.fluxcd.io/requestedAt=$token" \
    --field-manager="$field_manager" --overwrite >/dev/null
  wait_until "Flux handling the reconcile of $layer" reconciled "$token"
  wait_until "Kyverno's admission controller running" controller_ready
  wait_until "Kyverno's webhooks excluding the system namespaces and carrying both match conditions of the policy" webhooks_judge_app_pods
  wait_until "$layer being Ready" layer_ready
}

# Every kind the API serves and can delete, but Namespaces and events: what Flux labelled as applied is deleted by kind.
applied_kinds() {
  kubectl api-resources --verbs=list,delete --output name | grep -v -x -e namespaces -e events -e events.events.k8s.io |
    paste -sd, -
}
objects_left() {
  kubectl get "$(applied_kinds)" --all-namespaces --selector "$applied_selector" --output name --ignore-not-found
}
webhooks_left() {
  kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration --selector "$webhook_selector" --output name --ignore-not-found
}
# nothing_left <listing>: the listing succeeded and printed nothing; a failed listing counts as objects left, so the wait
# goes on and ends in its own failure.
nothing_left() {
  local left
  left="$("$1")" || return 1
  [ -z "$left" ]
}

remove() {
  local url repository branch applied head
  url="$(kubectl --namespace "$flux_namespace" get gitrepository "$root_layer" --output jsonpath='{.spec.url}')"
  branch="$(kubectl --namespace "$flux_namespace" get gitrepository "$root_layer" --output jsonpath='{.spec.ref.branch}')"
  repository="${url#https://github.com/}" repository="${repository%.git}"
  applied="$(kubectl --namespace "$flux_namespace" get kustomization "$root_layer" --output jsonpath='{.status.lastAppliedRevision}')"
  head="$(gh api "repos/$repository/commits/$branch" --jq .sha)" ||
    fail "$branch's head cannot be read from GitHub, so the revision the root applied cannot be compared with it; nothing deleted" \
      "run it again when GitHub answers"
  [ -n "$applied" ] && [ "${applied##*:}" = "$head" ] ||
    fail "the root Kustomization applied '${applied:-nothing}', not $branch's head $head; nothing deleted" \
      "wait until the root has applied $branch's head, then run it again"
  kubectl delete "$(applied_kinds)" --all-namespaces --selector "$applied_selector" --ignore-not-found --wait=false >/dev/null
  delete_webhooks
  kubectl delete secret --namespace "$kyverno_namespace" --selector "$certificate_selector" --ignore-not-found >/dev/null
  kubectl delete lease --namespace "$kyverno_namespace" --selector "$lease_selector" --ignore-not-found >/dev/null
  kubectl delete lease --namespace "$kyverno_namespace" "${kyverno_leases[@]}" --ignore-not-found >/dev/null
  wait_until "the objects Flux applied for $layer being gone" nothing_left objects_left
  wait_until "Kyverno's webhook configurations being gone" nothing_left webhooks_left
}

case "$verb" in
  pause) pause ;;
  resume) if layer_exists; then restore; else remove; fi ;;
  *) echo "pause_or_resume_attestation_check.sh: unknown verb '$verb'; use pause or resume" >&2; exit 2 ;;
esac
echo "admission:$verb: done in $SECONDS seconds"
