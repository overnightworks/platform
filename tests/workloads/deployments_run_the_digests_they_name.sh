#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/failure.sh"
policy="$(yq 'select(.kind == "ValidatingAdmissionPolicy" and .spec.paramKind != null) | .metadata.name' "$POLICY_FILE")"
exempt=" $(kubectl get validatingadmissionpolicy "$policy" -o jsonpath='{.spec.matchConstraints.namespaceSelector.matchExpressions[?(@.operator=="NotIn")].values[*]}') "
# The runtime's imageID names the digest it resolved each container's image to.
while IFS='|' read -r namespace name replicas; do
  [[ $exempt != *" $namespace "* ]] || continue
  declare -A image_of=()
  while IFS='|' read -r container image; do
    [[ $image =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] ||
      fail "the container $container of the Deployment $namespace/$name runs '$image', not an image at a digest"
    image_of[$container]="$image"
    echo "Deployment $namespace/$name, container $container: $image"
  done < <(kubectl --namespace "$namespace" get deployment "$name" \
    -o go-template='{{range .spec.template.spec.containers}}{{.name}}|{{.image}}{{"\n"}}{{end}}')
  # A Deployment scaled to 0 has no running container, as cloudflared in this job.
  if [ "$replicas" = 0 ]; then
    unset image_of
    echo "the Deployment $namespace/$name runs no container: scaled to 0 replicas"
    continue
  fi
  selector="$(kubectl --namespace "$namespace" get deployment "$name" \
    -o go-template='{{range $key, $value := .spec.selector.matchLabels}}{{$key}}={{$value}},{{end}}')"
  image_ids="$(kubectl --namespace "$namespace" get pods --selector "${selector%,}" \
    -o go-template='{{range .items}}{{range .status.containerStatuses}}{{.name}}|{{.imageID}}{{"\n"}}{{end}}{{end}}')"
  [ -n "$image_ids" ] || fail "no running container of the Deployment $namespace/$name reports an imageID"
  while IFS='|' read -r container image_id; do
    echo "running $container: $image_id"
    image="${image_of[$container]-}"
    [ -n "$image" ] && [ "${image_id##*@}" = "${image##*@}" ] ||
      fail "the running container $container of $namespace/$name has the imageID $image_id, not its Deployment's digest"
  done <<<"$image_ids"
  unset image_of
  echo "every running container of the Deployment $namespace/$name carries its Deployment's digest"
done < <(kubectl get deployments --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.replicas}{"\n"}{end}')
