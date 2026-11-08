#!/usr/bin/env bash
set -euo pipefail
# The job root's overlay adds spec.patches to both, which would replace committed ones without a word (RFC 6902
# add).
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
root_file=clusters/pc/flux-system/gotk-sync.yaml
objects="$(kubectl create --dry-run=client -f "$root_file" \
  -o go-template='{{.kind}}{{if .spec.patches}} with spec.patches{{end}}{{"\n"}}')"
case "$(grep '^Kustomization' <<<"$objects" || true)" in
  Kustomization) echo "the root Kustomization in $root_file carries no spec.patches" ;;
  "Kustomization with spec.patches")
    fail "the root Kustomization in $root_file carries spec.patches, which the job root's overlay would replace" ;;
  *) fail "$root_file holds not exactly one Kustomization" ;;
esac
tunnel_file=clusters/pc/infrastructure.yaml
tunnel="$(kubectl create --dry-run=client -f "$tunnel_file" -o go-template='{{if eq .metadata.name "tunnel"}}
  {{- .kind}}{{if .spec.patches}} with spec.patches{{end}}{{"\n"}}{{end}}')"
case "$tunnel" in
  Kustomization) echo "the Kustomization tunnel in $tunnel_file carries no spec.patches" ;;
  "Kustomization with spec.patches")
    fail "the Kustomization tunnel in $tunnel_file carries spec.patches, which the job root's patch would replace" ;;
  *) fail "$tunnel_file holds not exactly one Kustomization tunnel" ;;
esac
