#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
tests_directory="$(dirname "${BASH_SOURCE[0]}")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# promtool comes from the image the render runs, so the rules are checked by the Prometheus that reads them.
image="$(yq --no-doc 'select(.kind == "Deployment" and .metadata.name == "prometheus-server") | .spec.template.spec.containers[].image | select(test("^quay[.]io/prometheus/prometheus@"))' \
  infrastructure/prometheus/rendered.yaml)"
[ -n "$image" ] || fail "infrastructure/prometheus/rendered.yaml holds no Prometheus image"
yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-rules") | .data["rules.yml"]' \
  infrastructure/prometheus/rules.yaml >"$scratch/rules.yml"
cp "$tests_directory/rules_test.yml" "$scratch/rules_test.yml"
chmod -R a+rX "$scratch"
promtool() { docker run --rm --volume "$scratch:/rules:ro" --workdir /rules --entrypoint promtool "$image" "$@"; }
promtool check rules rules.yml
promtool test rules rules_test.yml
