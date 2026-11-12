#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
layer() { kubectl --namespace "${1%/*}" get kustomization "${1#*/}" -o jsonpath="$2"; }

for manifest in $APP_MANIFESTS; do
  app_layer="flux-system/$(basename "$(dirname "$manifest")")"
  applied_revision="$(layer "$app_layer" '{.status.lastAppliedRevision}')"
  [ "${applied_revision##*@sha1:}" = "$CANDIDATE_REVISION" ] ||
    fail "the Kustomization $app_layer applied '$applied_revision', not the candidate $CANDIDATE_REVISION"
  [[ " $(layer "$app_layer" '{.spec.dependsOn[*].name}') " == *" ${SECRETS_LAYER#*/} "* ]] ||
    fail "the Kustomization $app_layer does not depend on $SECRETS_LAYER"
  echo "the Kustomization $app_layer applied the candidate and depends on $SECRETS_LAYER"

  deployment="$(yq 'select(.kind == "Deployment") | .metadata.namespace + "/" + .metadata.name' "$manifest")"
  namespace="${deployment%/*}" name="${deployment#*/}"
  markers="$(kubectl get namespace "$namespace" \
    -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}|{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}')"
  # presentator's Namespace enforces no level, as its build worker's init container holds NET_ADMIN; its warn and audit
  # labels are read by tests/presentator/namespace_warns_at_restricted_and_no_template_takes_its_uids.sh.
  expected_markers=restricted
  [ "$namespace" != presentator ] || expected_markers=
  [ "$markers" = "$expected_markers|disabled" ] ||
    fail "the Namespace $namespace reads '$markers', not Pod Security '${expected_markers:-none}' enforced and prune disabled"
  echo "the Namespace $namespace enforces '${expected_markers:-no level}', and Flux never prunes it"

  # A Deployment at 0 replicas has no pod to be Available; its strategy and image are still judged.
  replicas="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.spec.replicas}')"
  if [ "$replicas" = 0 ]; then
    state="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.status.replicas}|{.spec.strategy.type}')"
    [ "$state" = "|Recreate" ] || fail "the Deployment $deployment reads '$state', not no pod at 0 replicas and Recreate"
    pods="$(kubectl --namespace "$namespace" get pods -l "app.kubernetes.io/name=$name" -o name)"
    [ -z "$pods" ] || fail "the Deployment $deployment at 0 replicas has pods: $pods"
    # The class is applied by another layer, so admission finds it only once that layer has.
    runtime_class="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.spec.template.spec.runtimeClassName}')"
    [ -z "$runtime_class" ] || until_true 180 "the RuntimeClass $runtime_class exists" kubectl get runtimeclass "$runtime_class"
    # The template is what a go at 1 replica creates, so its Pod meets the Namespace's Pod Security level now.
    kubectl --namespace "$namespace" get deployment "$name" -o yaml |
      yq '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": .metadata.name + "-dry-run", "labels": .spec.template.metadata.labels}, "spec": .spec.template.spec}' |
      kubectl --namespace "$namespace" create --dry-run=server -f - ||
      fail "the Pod template of the Deployment $deployment is refused by $namespace's admission"
    echo "the Deployment $deployment has no pod and its Pod template passes server-side dry-run in $namespace"
    # The Deployment's reach, read from the applied policy: each rule as its sources and ports, sorted; a rule's source
    # is a namespace and a pod's first label value, or an address block with its exceptions.
    case "$deployment" in
      songmaker/acestep-worker)
        expected_ingress="/music-worker,/web -> 8001/TCP"
        expected_egress="/redis -> 6379/TCP;/web -> 8080/TCP;kube-system/kube-dns -> 53/TCP,53/UDP" ;;
      personas/personas)
        expected_ingress=""
        expected_egress="0.0.0.0/0 except 10.42.0.0/16,10.43.0.0/16 -> 443/TCP;kube-system/kube-dns -> 53/TCP,53/UDP;litellm/litellm-front -> 4000/TCP" ;;
      *) fail "the Deployment $deployment runs no pod and no reach is expected of it" ;;
    esac
    sources='(.from // .to) | map(
      (.ipBlock | select(. != null) | .cidr + " except " + (.except | sort | join(",")))
      // ((.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] // "") + "/" + (.podSelector.matchLabels | to_entries | .[0].value))) | sort | join(",")'
    ports='[.ports[] | (.port | tostring) + "/" + .protocol] | sort | join(",")'
    rules='map((('"$sources"') + " -> " + ('"$ports"'))) | sort | join(";")'
    policy="$(kubectl --namespace "$namespace" get networkpolicy "$name" -o yaml)"
    for direction in ingress:"$expected_ingress" egress:"$expected_egress"; do
      expected="${direction#*:}"
      actual="$(yq "(.spec.${direction%%:*} // []) | $rules" <<<"$policy")"
      [ "$actual" = "$expected" ] ||
        fail "the NetworkPolicy $namespace/$name reads '$actual' for ${direction%%:*}, not '$expected'"
    done
    [ "$(yq '.spec.policyTypes | sort | join(",")' <<<"$policy")" = "Egress,Ingress" ] ||
      fail "the NetworkPolicy $namespace/$name does not govern exactly Ingress and Egress"
    echo "the NetworkPolicy $namespace/$name admits '${expected_ingress:-nobody}' and sends only '$expected_egress'"
  else
    kubectl --namespace "$namespace" wait "deployment/$name" --for=condition=Available --timeout=3m
    state="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.status.readyReplicas}|{.spec.strategy.type}')"
    [ "$state" = "1|Recreate" ] || fail "the Deployment $deployment reads '$state', not one Ready pod and Recreate"
  fi
  image="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.spec.template.spec.containers[*].image}')"
  [[ $image =~ ^ghcr[.]io/${GITHUB_REPOSITORY_OWNER,,}/[^[:space:]:@]+:[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] ||
    fail "the Deployment $deployment runs '$image', not one full app ref"
  echo "the Deployment $deployment is Available with one Ready pod, Recreate, and runs the full app ref $image"
  # What the image cost the runner: the kubelet's own report of each pull, and the disk after it.
  kubectl --namespace "$namespace" get events --field-selector reason=Pulled \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}'
  df --human-readable /

  # The Secrets the pod pulls and starts from are platform-secrets' objects, there before the Deployment.
  created="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.metadata.creationTimestamp}')"
  secrets_inventory="$(layer "$SECRETS_LAYER" '{range .status.inventory.entries[*]}{.id}{"\n"}{end}')"
  pull_secrets="$(kubectl --namespace "$namespace" get deployment "$name" -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}')"
  [ -n "$pull_secrets" ] || fail "the Deployment $deployment names no pull Secret"
  for secret in $pull_secrets $(kubectl --namespace "$namespace" get deployment "$name" \
    -o jsonpath='{.spec.template.spec.volumes[*].secret.secretName} {.spec.template.spec.volumes[*].projected.sources[*].secret.name}'); do
    grep -qxF "${namespace}_${secret}__Secret" <<<"$secrets_inventory" ||
      fail "the Secret $namespace/$secret is not in the inventory of $SECRETS_LAYER"
    secret_created="$(kubectl --namespace "$namespace" get secret "$secret" -o jsonpath='{.metadata.creationTimestamp}')"
    [[ ! $created < "$secret_created" ]] ||
      fail "the Deployment $deployment was created at $created, before its Secret $secret at $secret_created"
    echo "the Secret $namespace/$secret of $SECRETS_LAYER was created at $secret_created, not after the Deployment at $created"
  done
  for secret in $pull_secrets; do
    type="$(kubectl --namespace "$namespace" get secret "$secret" -o jsonpath='{.type}')"
    [ "$type" = kubernetes.io/dockerconfigjson ] || fail "the pull Secret $namespace/$secret is of type $type"
  done
  echo "the Deployment $deployment pulled its private image through $pull_secrets"
done
