#!/usr/bin/env bash
# Usage: CANDIDATE_REVISION=<sha> CANDIDATE_BRANCH=<branch> CANDIDATE_SOURCE_URL=<url> RUNNER_TEMP=<dir> \
#   tests/speech_runtime/a_gpu_release_keeps_a_ready_speech_pod_from_bridge_to_settle.sh
# Run after the candidate was reconciled and served by tests/flux/serve_the_candidate_commit.sh, and last of its part. k3d
# has no card, so the cell commits a stand-in: the GPU Deployment without its runtime class and card, with the small
# image's environment and memory, read from speech-runtime.yaml, at speech's previous CPU release. It then sets the card to
# speech (the stand-in at one pod, the small image at none) and commits a GPU release, the stand-in's ref moved to speech's
# current CPU release. The cell proves the order from timestamps: the small pod turns Ready before the old GPU pod is killed,
# and the new GPU pod turns Ready before the small pod is killed; a sample of the Service's endpoints each second never
# shows none from the small pod's Ready to the end. Then, with the layer speech-runtime suspended, it commits a second
# release, waits until the new Job bridge raised the small image, runs the Job settle of the first release under a name of its
# own, which finds the newer release pending and leaves the small image up, and resumes the layer: the Job settle of the
# second release lowers it. Each Job is a new object each time. Every wait ends within the time of one phase, so that a stall fails the cell
# with the state of the layers, the pods, the Jobs and their logs inside the part's time limit, which a cancelled job would not print.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
cells="$(dirname "${BASH_SOURCE[0]}")/.."
served="$RUNNER_TEMP/candidate-source/repository.git"
tree="$RUNNER_TEMP/speech-release"
samples="$RUNNER_TEMP/speech-endpoint-samples"
small_ready_pods="$RUNNER_TEMP/speech-small-ready-pods"
namespace=speech-runtime
small=speech-runtime
gpu=speech-runtime-gpu
# The longest a phase may wait: a pull and a start take about a minute on the runner, and the part's limit stands about
# fourteen minutes after this cell's start.
phase_seconds=300
layer=speech-runtime
bridge_layer=speech-runtime-bridge
small_manifest="$tree/apps/speech-runtime/speech-runtime.yaml"
gpu_manifest="$tree/apps/speech-runtime/speech-runtime-gpu.yaml"
release_component="$tree/apps/speech-runtime/release/kustomization.yaml"

git worktree add --quiet --detach "$tree" "$CANDIDATE_REVISION"
sampler_pid=""
layer_suspended=""
# diagnose: what the step "Print Flux's state" lacks after a stalled or failed phase: the namespace's Normal events (the scale
# and the kills of the roll) and the logs of the Jobs, read only and never failing.
diagnose() {
  echo "::group::the Normal events and the Jobs' logs of $namespace at the failure"
  kubectl --namespace "$namespace" get events --field-selector type=Normal --sort-by=.lastTimestamp || true
  local job
  for job in bridge settle settle-of-the-first-release; do
    echo "the log of the Job $job:"
    kubectl --namespace "$namespace" logs "job/$job" --tail=40 || true
  done
  echo "::endgroup::"
}
cleanup() {
  local status=$?
  [ "$status" -eq 0 ] || diagnose
  [ -z "$sampler_pid" ] || kill "$sampler_pid" 2>/dev/null || true
  [ -z "$layer_suspended" ] || flux resume kustomization "$layer" >/dev/null || true
  git worktree remove --force "$tree"
}
trap cleanup EXIT

# release_of <placeholder>: "<tag> <digest>" of the entry of the release Component in the tree.
release_of() { NAME="$1" yq '.images[] | select(.name == strenv(NAME)) | .newTag + " " + .digest' "$release_component"; }

# previous_cpu_release: "<tag> <digest>" of the newest CPU release that the history of apps/speech-runtime removed and the
# release no longer holds, whether it stood in an image line or in the release Component.
previous_cpu_release() {
  local current_digest
  current_digest="${1#* }"
  git -C "$tree" log -p -U0 --format= "$CANDIDATE_REVISION" -- apps/speech-runtime |
    awk '/^-[[:space:]]+image: ghcr.io\/overnightworks\/speech:/ { split($3, ref, "[:@]"); print ref[2], ref[3] ":" ref[4] }
         /^-[[:space:]]+newTag: /{tag=$3} /^-[[:space:]]+digest: sha256:/{print tag, $3}' |
    { grep -v -F -e '-gpu ' -e " $current_digest" || true; } | sed -n 1p
}

# stand_in: the GPU Deployment as a CPU Deployment of the small image's environment and memory, both read from the manifest of
# the small image, so that k3d, which has no card, runs it.
stand_in() {
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env' "$small_manifest" >"$RUNNER_TEMP/stand-in-env.yaml"
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources' "$small_manifest" >"$RUNNER_TEMP/stand-in-resources.yaml"
  yq --inplace '.spec.template.spec |= (del(.runtimeClassName) | .containers[0].env = load(strenv(STAND_IN_ENV)) | .containers[0].resources = load(strenv(STAND_IN_RESOURCES)))' \
    "$gpu_manifest"
}
export STAND_IN_ENV="$RUNNER_TEMP/stand-in-env.yaml" STAND_IN_RESOURCES="$RUNNER_TEMP/stand-in-resources.yaml"

# move_gpu_ref <tag> <digest>: the release Component names that release for the GPU Deployment.
move_gpu_ref() {
  NEW_TAG="$1" NEW_DIGEST="$2" yq --inplace '(.images[] | select(.name == "speech-gpu")) |= (.newTag = strenv(NEW_TAG) | .digest = strenv(NEW_DIGEST))' "$release_component"
}

# serve_commit <message>: commits the tree as a child of the last commit, serves it as the candidate and reconciles it. The
# GPU Deployment keeps the count Git gives it, as the stand-in runs.
serve_commit() {
  git -C "$tree" -c user.name="speech release" -c user.email="speech-release@invalid" commit --quiet --no-verify --all --message="$1"
  revision="$(git -C "$tree" rev-parse HEAD)"
  git push --quiet "$served" "${revision}:refs/heads/${CANDIDATE_BRANCH}"
  echo "the candidate branch serves $revision: $1"
  local scratch
  scratch="$(mktemp -d)"
  RUNNER_TEMP="$scratch" CANDIDATE_REVISION="$revision" SPEECH_GPU_STAND_IN=1 "$cells/flux/reconcile_the_candidate_tree.sh" >/dev/null
  flux reconcile kustomization flux-system --with-source --timeout="${phase_seconds}s"
}

# applied <layer> <revision>: the layer is Ready and applied the revision.
applied() {
  [ "$(kubectl --namespace flux-system get kustomization "$1" \
    -o jsonpath='{.status.lastAppliedRevision}{" "}{.status.conditions[?(@.type=="Ready")].status}')" = "${CANDIDATE_BRANCH}@sha1:${2} True" ]
}

# uid_of <kind> <name>: the uid of the object, which a new object does not share.
uid_of() { kubectl --namespace "$namespace" get "$1" "$2" -o jsonpath='{.metadata.uid}'; }
# replicas_of <deployment>
replicas_of() { kubectl --namespace "$namespace" get "deployment/$1" -o jsonpath='{.spec.replicas}'; }
# pod_of <deployment>: the name of its one pod.
pod_of() { kubectl --namespace "$namespace" get pods --selector "app.kubernetes.io/name=$1" -o jsonpath='{.items[0].metadata.name}'; }
# ready_since <pod>: when the pod turned Ready.
ready_since() { kubectl --namespace "$namespace" get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}'; }
# killed_at <pod>: when the kubelet began to stop the pod.
killed_at() {
  kubectl --namespace "$namespace" get events --field-selector "involvedObject.name=$1,reason=Killing" -o jsonpath='{.items[0].firstTimestamp}'
}
# not_after <time> <time>: the first, in the one RFC 3339 form in UTC, is no later than the second.
not_after() { [[ ! "$1" > "$2" ]]; }

# sample_endpoints: each second the time and the number of the Service's ready endpoints into `samples`, and each Ready pod of
# the small image with the time it turned Ready into `small_ready_pods`, until it is killed: a pod that the settle deleted
# keeps no object to read.
sample_endpoints() {
  while :; do
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(kubectl --namespace "$namespace" get endpointslices --selector "kubernetes.io/service-name=$small" \
      -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.targetRef.name}{"\n"}{end}' | grep -c . || true)" >>"$samples"
    kubectl --namespace "$namespace" get pods --selector "app.kubernetes.io/name=$small" \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
      awk '$3 == "True" { print $1, $2 }' >>"$small_ready_pods" || true
    sleep 1
  done
}

previous="$(previous_cpu_release "$(release_of speech-cpu)")"
[ -n "$previous" ] || fail "the history of apps/speech-runtime holds no CPU release other than the current one"
read -r previous_tag previous_digest <<<"$previous"
read -r current_tag current_digest <<<"$(release_of speech-cpu)"
echo "the stand-in starts at the previous CPU release $previous_tag and the GPU release moves it to $current_tag"

# The stand-in at the previous release, with the card given to speech: it at one pod, the small image at none.
stand_in
move_gpu_ref "$previous_tag" "$previous_digest"
# The overlay that serves the stand-in drops the count patch of the layer speech-runtime and points the source at the new
# commit in one apply. A layer whose spec changed reconciles at once at the revision it holds, which would give the old GPU
# Deployment, with its card and runtime class, the count of one and keep the layer waiting on a pod that k3d cannot create.
# The layer stands still until the source holds the stand-in.
flux suspend kustomization "$layer"
layer_suspended=1
serve_commit "Stand in a CPU Deployment for the GPU Deployment at the previous CPU release"
stand_in_revision="$revision"
flux resume kustomization "$layer" >/dev/null
layer_suspended=""
until_true "$phase_seconds" "the Kustomization $layer applied the stand-in $stand_in_revision" applied "$layer" "$stand_in_revision"
kubectl --namespace "$namespace" scale "deployment/$gpu" --replicas=1 >/dev/null
kubectl --namespace "$namespace" wait "deployment/$gpu" --for=jsonpath='{.status.readyReplicas}'=1 --timeout="${phase_seconds}s" >/dev/null
kubectl --namespace "$namespace" scale "deployment/$small" --replicas=0 >/dev/null
kubectl --namespace "$namespace" wait --for=delete pod --selector "app.kubernetes.io/name=$small" --timeout="${phase_seconds}s" >/dev/null
echo "the card is speech's: $gpu stands at 1 and $small at none"

old_gpu_pod="$(pod_of "$gpu")"
bridge_before="$(uid_of job bridge)"
settle_before="$(uid_of job settle)"
: >"$samples"
: >"$small_ready_pods"
sample_endpoints &
sampler_pid=$!

# The GPU release.
move_gpu_ref "$current_tag" "$current_digest"
serve_commit "A GPU release at the current CPU release"
release_revision="$revision"
until_true "$phase_seconds" "the Kustomization $bridge_layer applied $release_revision" applied "$bridge_layer" "$release_revision"
until_true "$phase_seconds" "the Kustomization $layer applied $release_revision" applied "$layer" "$release_revision"
sleep 2
kill "$sampler_pid"
sampler_pid=""

[ "$(uid_of job bridge)" != "$bridge_before" ] || fail "the Job bridge is the object it was before the release"
[ "$(uid_of job settle)" != "$settle_before" ] || fail "the Job settle is the object it was before the release"
[ "$(replicas_of "$small")" -eq 0 ] || fail "the small image stands at $(replicas_of "$small") after the release, not none"
[ "$(replicas_of "$gpu")" -eq 1 ] || fail "$gpu stands at $(replicas_of "$gpu") after the release, not one"
new_gpu_pod="$(pod_of "$gpu")"
[ "$new_gpu_pod" != "$old_gpu_pod" ] || fail "the GPU pod is the pod it was before the release"

# The small pod that the bridge raised and the settle killed, which the sampler saw Ready.
[ "$(sort -u "$small_ready_pods" | wc -l)" -eq 1 ] || fail "the sampler saw $(sort -u "$small_ready_pods" | wc -l) Ready pods of $small, not one: $(sort -u "$small_ready_pods" | tr '\n' ';')"
read -r small_pod small_ready <"$small_ready_pods"
echo "the pulls of the release's images: $(kubectl --namespace "$namespace" get events --field-selector reason=Pulled -o jsonpath='{range .items[*]}{.involvedObject.name}{": "}{.message}{"; "}{end}')"
old_killed="$(killed_at "$old_gpu_pod")"
[ -n "$old_killed" ] || fail "no event says that the old GPU pod $old_gpu_pod was killed"
not_after "$small_ready" "$old_killed" || fail "the old GPU pod was killed at $old_killed, before the small pod turned Ready at $small_ready"
echo "the small pod $small_pod turned Ready at $small_ready, before the old GPU pod was killed at $old_killed"
new_gpu_ready="$(ready_since "$new_gpu_pod")"
small_killed="$(killed_at "$small_pod")"
[ -n "$small_killed" ] || fail "no event says that the small pod $small_pod was killed"
not_after "$new_gpu_ready" "$small_killed" || fail "the small pod was killed at $small_killed, before the new GPU pod turned Ready at $new_gpu_ready"
echo "the new GPU pod $new_gpu_pod turned Ready at $new_gpu_ready, before the small pod was killed at $small_killed"
# A sample, not a proof: the order above is the proof.
gaps="$(awk -v since="$small_ready" '$1 >= since && $2 == 0' "$samples")"
[ -z "$gaps" ] || fail "the Service had no ready endpoint at: ${gaps//$'\n'/; }"
echo "the Service had a ready endpoint in each of $(awk -v since="$small_ready" '$1 >= since' "$samples" | wc -l) samples from the small pod's Ready to the end"

# Two releases within one roll: the layer speech-runtime stands still while the Job bridge of the second runs.
# The first release's Job settle runs under a name of its own, since a Job that kubectl created or applied under the name
# settle would carry a field manager that Flux cleans from the object it then replaces, and that fails on the deleted Job.
settle_of_release="$RUNNER_TEMP/settle-of-the-first-release.yaml"
kubectl kustomize "$tree/apps/speech-runtime" |
  yq 'select(.kind == "Job" and .metadata.name == "settle") | .metadata.name = "settle-of-the-first-release" | del(.metadata.annotations)' >"$settle_of_release"
bridge_before="$(uid_of job bridge)"
flux suspend kustomization "$layer"
layer_suspended=1
move_gpu_ref "$previous_tag" "$previous_digest"
serve_commit "A second GPU release, the previous CPU release"
second_revision="$revision"
until_true "$phase_seconds" "the Kustomization $bridge_layer applied $second_revision" applied "$bridge_layer" "$second_revision"
[ "$(uid_of job bridge)" != "$bridge_before" ] || fail "the Job bridge of the second release is the object of the first"
[ "$(replicas_of "$small")" -eq 1 ] || fail "the Job bridge of the second release left the small image at $(replicas_of "$small"), not one"
kubectl --namespace "$namespace" wait "deployment/$small" --for=jsonpath='{.status.readyReplicas}'=1 --timeout="${phase_seconds}s" >/dev/null
echo "the Job bridge of the second release raised the small image to one Ready pod"

# The Job settle of the first release finds the newer release pending and leaves the small image up.
kubectl create -f "$settle_of_release" >/dev/null
kubectl --namespace "$namespace" wait job/settle-of-the-first-release --for=condition=complete --timeout="${phase_seconds}s" >/dev/null
[ "$(replicas_of "$small")" -eq 1 ] || fail "the Job settle of the first release lowered the small image to $(replicas_of "$small") although a newer release was pending"
echo "the Job settle of the first release left the small image up for the second release"

settle_before="$(uid_of job settle)"
flux resume kustomization "$layer" >/dev/null
layer_suspended=""
until_true "$phase_seconds" "the Kustomization $layer applied $second_revision" applied "$layer" "$second_revision"
[ "$(uid_of job settle)" != "$settle_before" ] || fail "the Job settle of the second release is the object of the first"
[ "$(replicas_of "$small")" -eq 0 ] || fail "the Job settle of the second release left the small image at $(replicas_of "$small"), not none"
[ "$(replicas_of "$gpu")" -eq 1 ] || fail "$gpu stands at $(replicas_of "$gpu") after the second release, not one"
echo "the Job settle of the second release lowered the small image after its GPU pod turned Ready"
