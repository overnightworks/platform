#!/usr/bin/env bash
set -euo pipefail
# The job root is the PC's own clusters/pc/flux-system as a kustomize base, no file copied. The overlay adds
# only Flux's spec.patches on the root and the source's url and ref, which serve the run's candidate.
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
          # k3d has no card: a pod of the acestep-worker would stay Pending on nvidia.com/gpu, and the Kustomization
          # songmaker, which waits, would never turn Ready; the Deployment applies and runs no pod.
          - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: songmaker}
            patch: |
              - op: add
                path: /spec/patches
                value:
                  - target: {group: apps, kind: Deployment, name: acestep-worker}
                    patch: |
                      - op: replace
                        path: /spec/replicas
                        value: 0
          # k3d has no card: a pod of speech's GPU image would stay Pending on nvidia.com/gpu, and the Kustomization
          # speech-runtime, which waits, would never turn Ready; the Deployment applies and runs no pod, so its image
          # stays off the node too.
          - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: speech-runtime}
            patch: |
              - op: add
                path: /spec/patches
                value:
                  - target: {group: apps, kind: Deployment, name: speech-runtime-gpu}
                    patch: |
                      - op: add
                        path: /spec/replicas
                        value: 0
          # The acestep-worker runs no pod in k3d, so its image stays off the node. The scoring-worker's, about 4 GB and
          # most of the pull time, stays off the Job too: the Job would pull it before songmaker's layer starts, and the
          # wait for every Kustomization would then run that pull and the layer's start one after the other. Its own pod
          # pulls it beside the rest of the layer's start, as without a pull layer; the Job mounts web and music-worker,
          # which pods of the layer run.
          - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: songmaker-pull}
            patch: |
              - op: add
                path: /spec/patches
                value:
                  - target: {group: batch, kind: Job, name: pull}
                    patch: |
                      apiVersion: batch/v1
                      kind: Job
                      metadata:
                        name: pull
                      spec:
                        template:
                          spec:
                            containers:
                              - name: pull
                                volumeMounts:
                                  - mountPath: /images/acestep-worker
                                    $patch: delete
                                  - mountPath: /images/scoring-worker
                                    $patch: delete
                            volumes:
                              - name: acestep-worker
                                $patch: delete
                              - name: scoring-worker
                                $patch: delete
          # k3d resolves the public MCP URLs of hopin and skat to the live apps, so a pod of the personas runner would
          # either never turn Ready or call the PC's apps with a dummy secret; the Deployment applies and runs no pod.
          - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: personas}
            patch: |
              - op: add
                path: /spec/patches
                value:
                  - target: {group: apps, kind: Deployment, name: personas}
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
# The source is the job's own repository, which holds the run's commit on one branch: Flux reads that commit and
# nothing a landing or a push moves. It stays so in the object applied here and in Flux's build.
candidate_ref="{branch: ${CANDIDATE_BRANCH}, commit: ${CANDIDATE_REVISION}}"
candidate_patches="$(cat <<'YAML'
  - target: {group: source.toolkit.fluxcd.io, kind: GitRepository, name: flux-system}
    patch: |
      - op: replace
        path: /spec/ref
        value: @CANDIDATE_REF@
      - op: replace
        path: /spec/url
        value: @CANDIDATE_URL@
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
            - op: replace
              path: /spec/url
              value: @CANDIDATE_URL@
YAML
)"
candidate_patches="${candidate_patches//@CANDIDATE_REF@/${candidate_ref}}"
printf '%s\n' "${candidate_patches//@CANDIDATE_URL@/${CANDIDATE_SOURCE_URL}}" >> "$overlay/kustomization.yaml"
# A second run, which moves the candidate to a child commit, takes spec.ref and spec.patches over from the field manager
# of Flux's own apply of the first run.
kubectl apply --server-side --force-conflicts -k "$overlay"
kubectl -n flux-system get kustomization flux-system -o yaml
