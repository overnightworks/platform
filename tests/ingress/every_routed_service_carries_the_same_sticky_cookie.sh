#!/usr/bin/env bash
# every_routed_service_carries_the_same_sticky_cookie.sh: holds docs/app.md's sticky cookie. Every Kustomization of
# clusters/pc whose path is a directory is rendered by tests/flux/render_layer.sh as Flux renders it. For every Ingress,
# the Service its backends name in the same namespace must carry Traefik's five sticky-cookie annotations, and each of
# the five values must be equal across all layers and Services; no value is restated here. The root's own layer holds
# the Secrets alone and has no Ingress. The judgement, judge_layers, takes the repository root, so the mutants below can
# judge a throwaway root. Exits 1 on a breach, naming layer, Service and annotation, which are public.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../flux/render_layer.sh
source "$(dirname "${BASH_SOURCE[0]}")/../flux/render_layer.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The annotations Traefik reads from a Service to set the cookie.
annotation_keys='["traefik.ingress.kubernetes.io/service.sticky.cookie", "traefik.ingress.kubernetes.io/service.sticky.cookie.name",
  "traefik.ingress.kubernetes.io/service.sticky.cookie.secure", "traefik.ingress.kubernetes.io/service.sticky.cookie.httponly",
  "traefik.ingress.kubernetes.io/service.sticky.cookie.samesite"]'

# routed_services <layer> <rendered YAML file>: one JSON line per Service that an Ingress of the render routes to, with
# its namespace, name and the value of each annotation (null where it has none), or a problem string for a missing Service.
# shellcheck disable=SC2016 # jq's variables
routed_services() {
  yq --output-format json --indent 0 '.' "$2" |
    jq --slurp --compact-output --arg layer "$1" --argjson keys "$annotation_keys" '
      [.[] | select(.kind == "Service")] as $services
      | [.[] | select(.kind == "Ingress") | (.metadata.namespace // "") as $namespace
         | [.spec.rules[]?.http.paths[]?.backend.service.name, .spec.defaultBackend.service.name]
         | map(select(. != null)) | .[] | {namespace: $namespace, name: .}] | unique | .[]
      | . as $routed
      | ([$services[] | select((.metadata.namespace // "") == $routed.namespace and .metadata.name == $routed.name)] | first) as $service
      | if $service == null then "problem: \($layer): an Ingress routes to the Service \($routed.namespace)/\($routed.name), which the layer does not hold"
        else {layer: $layer, service: "\($routed.namespace)/\($routed.name)",
              annotations: ([$keys[] as $key | {key: $key, value: ($service.metadata.annotations[$key] // null)}] | from_entries)}
        end'
}

# judge_rows: reads the lines of routed_services and prints the problem lines.
# shellcheck disable=SC2016 # jq's variables
judge_rows() {
  jq --slurp --raw-output '
    [.[] | strings] + [
      [.[] | objects] as $rows
      | (if ($rows | length) == 0 and ([.[] | strings] | length) == 0 then "problem: no Ingress routes to a Service" else empty end),
        ($rows[] | . as $row | .annotations | to_entries[] | select(.value == null)
          | "problem: \($row.layer): the Service \($row.service) lacks \(.key)"),
        ([$rows[] | . as $row | .annotations | to_entries[] | select(.value != null)
          | {key, value, where: "\($row.layer) \($row.service)"}] | group_by(.key)[]
          | select(map(.value) | unique | length > 1) | .[0].key as $key
          | "problem: \($key) differs: \(group_by(.value) | map("\(.[0].value) in \(map(.where) | join(", "))") | join("; "))"),
        "\($rows | length) routed Services"
    ] | .[]'
}

# judge_layers <repository root>: the problem lines of every layer of <root>/clusters/pc, and a line counting what it judged.
judge_layers() {
  local root="$1" layer path directory nested status rendered="$work/layer.yaml"
  while read -r layer path; do
    [ "$path" != ./ ] || continue
    directory="$root/${path#./}"
    status=0
    nested="$(render_layer "$directory" "$rendered")" || status=$?
    case "$status" in
      0) ;;
      2)
        jq --null-input --compact-output --arg layer "$layer" --arg nested "$nested" '"problem: \($layer) has no kustomization, and Flux renders its subdirectory \($nested) as a resource of its own"'
        continue ;;
      *) fail "$layer ($path) does not render" ;;
    esac
    routed_services "$layer" "$rendered"
  done < <(yq --no-doc 'select(.kind == "Kustomization") | .metadata.name + " " + .spec.path' "$root"/clusters/pc/*.yaml) |
    judge_rows
}

problems="$(judge_layers "$repository_root")"
echo "$problems"
[ -z "$(grep '^problem: ' <<<"$problems" || true)" ] || fail "a routed Service breaks the sticky cookie rule of docs/app.md"

# A throwaway root with two layers, each routing one Service that carries the annotations the real layers hold.
throwaway="$work/root"
mkdir -p "$throwaway/clusters/pc" "$throwaway/apps/first" "$throwaway/apps/second"
cat >"$throwaway/clusters/pc/apps.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: first
spec:
  path: ./apps/first
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: second
spec:
  path: ./apps/second
YAML
# one_routed_service <layer>: the Service of the layer and the Ingress that routes to it.
one_routed_service() {
  yq --no-doc 'select(.kind == "Service") | .metadata.name = "web"' "$repository_root/apps/hopin/hopin.yaml" |
    yq 'del(.metadata.namespace)' >"$throwaway/apps/$1/web.yaml"
  cat >>"$throwaway/apps/$1/web.yaml" <<'YAML'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
spec:
  rules:
    - host: web.invalid
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
YAML
}
one_routed_service first
one_routed_service second
unchanged="$(judge_layers "$throwaway")"
[ -z "$(grep '^problem: ' <<<"$unchanged" || true)" ] || fail "the throwaway root with equal annotations is red: $unchanged"

samesite_key="$(jq --raw-output '.[4]' <<<"$annotation_keys")"
SERVICE_KEY="$samesite_key" yq --inplace 'select(.kind == "Service") |= del(.metadata.annotations[strenv(SERVICE_KEY)])' "$throwaway/apps/second/web.yaml"
expect_problem "second: the Service /web lacks $samesite_key" "a routed Service without one annotation" judge_layers "$throwaway"
yq --inplace 'select(.kind == "Service") |= del(.metadata.annotations)' "$throwaway/apps/second/web.yaml"
expect_problem "second: the Service /web lacks $samesite_key" "a routed Service without annotations" judge_layers "$throwaway"

one_routed_service second
SERVICE_KEY="$samesite_key" yq --inplace 'select(.kind == "Service") |= (.metadata.annotations[strenv(SERVICE_KEY)] = "strict")' "$throwaway/apps/second/web.yaml"
expect_problem "$samesite_key differs" "a routed Service with another samesite" judge_layers "$throwaway"

one_routed_service second
mkdir -p "$throwaway/apps/third"
yq 'select(.kind == "Ingress") | .metadata.name = "third"' "$throwaway/apps/first/web.yaml" >"$throwaway/apps/third/ingress.yaml"
cat >>"$throwaway/clusters/pc/apps.yaml" <<'YAML'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: third
spec:
  path: ./apps/third
YAML
expect_problem "third: an Ingress routes to the Service /web, which the layer does not hold" "an Ingress in a new layer without its Service" judge_layers "$throwaway"
yq 'select(.kind == "Service") | .metadata.annotations = {}' "$throwaway/apps/first/web.yaml" >"$throwaway/apps/third/service.yaml"
expect_problem "third: the Service /web lacks $samesite_key" "an Ingress in a new layer whose Service has no annotations" judge_layers "$throwaway"
echo "every routed Service carries the same five sticky cookie annotations, and every mutant is red"
