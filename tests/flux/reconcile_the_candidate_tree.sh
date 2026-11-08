#!/usr/bin/env bash
set -euo pipefail
# The job root is the PC's own clusters/pc/flux-system as a kustomize base, no file copied. The overlay adds
# only Flux's spec.patches on the root and the source's ref, which pins the run's candidate.
overlay="$RUNNER_TEMP/candidate-root"
mkdir "$overlay"
printf 'resources:\n  - %s\n' "$(realpath --relative-to="$overlay" clusters/pc/flux-system)" \
  > "$overlay/kustomization.yaml"
cat >> "$overlay/kustomization.yaml" <<'YAML'
patches:
  - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: flux-system}
    patch: |
      - op: add
        path: /spec/patches
        value:
          # The committed self-Kustomization would replace this object and its patches.
          - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: flux-system}
            patch: |
              $patch: delete
              apiVersion: kustomize.toolkit.fluxcd.io/v1
              kind: Kustomization
              metadata: {name: flux-system, namespace: flux-system}
          # The PC-only sources: CI never fetches them, and their consumers run on the job's own source.
          - target: {group: source.toolkit.fluxcd.io, kind: GitRepository, name: platform-secrets}
            patch: |
              $patch: delete
              apiVersion: source.toolkit.fluxcd.io/v1
              kind: GitRepository
              metadata: {name: platform-secrets, namespace: flux-system}
          - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: platform-secrets}
            patch: |
              - op: replace
                path: /spec/sourceRef/kind
                value: OCIRepository
          # cloudflared's manifests apply, but no pod runs: its token is the PC's alone.
          - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: tunnel}
            patch: |
              - op: add
                path: /spec/patches
                value:
                  - target: {group: apps, kind: Deployment, name: cloudflared}
                    patch: |
                      - op: replace
                        path: /spec/replicas
                        value: 0
          # k3d has no card: the device plugin's DaemonSet applies and schedules nowhere.
          - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: nvidia}
            patch: |
              - op: add
                path: /spec/patches
                value:
                  - target: {group: apps, kind: DaemonSet, name: nvidia-device-plugin-daemonset}
                    patch: |
                      - op: add
                        path: /spec/template/spec/nodeSelector
                        value: {nvidia.com/gpu.present: "true"}
YAML
# The source stays on the run's own candidate in the object applied here and in Flux's build: a pull request
# follows its head, a push to main pins its commit on the branch, so a later landing never moves the job.
if [ "$GITHUB_EVENT_NAME" = pull_request ]; then
  candidate_ref="{name: ${PULL_REQUEST_REF}}"
else
  candidate_ref="{branch: main, commit: ${CANDIDATE_REVISION}}"
fi
candidate_patches="$(cat <<'YAML'
  - target: {group: source.toolkit.fluxcd.io, kind: GitRepository, name: flux-system}
    patch: |
      - op: replace
        path: /spec/ref
        value: @CANDIDATE_REF@
  - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: flux-system}
    patch: |
      - op: add
        path: /spec/patches/-
        value:
          target: {group: source.toolkit.fluxcd.io, kind: GitRepository, name: flux-system}
          patch: |
            - op: replace
              path: /spec/ref
              value: @CANDIDATE_REF@
YAML
)"
printf '%s\n' "${candidate_patches//@CANDIDATE_REF@/${candidate_ref}}" >> "$overlay/kustomization.yaml"
kubectl apply --server-side -k "$overlay"
kubectl -n flux-system get kustomization flux-system -o yaml
