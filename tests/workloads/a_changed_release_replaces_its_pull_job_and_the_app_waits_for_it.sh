#!/usr/bin/env bash
# Usage: CANDIDATE_REVISION=<sha> CANDIDATE_BRANCH=<branch> CANDIDATE_SOURCE_URL=<url> RUNNER_TEMP=<dir> \
#   tests/workloads/a_changed_release_replaces_its_pull_job_and_the_app_waits_for_it.sh
# Run after the candidate was reconciled and served by tests/flux/serve_the_candidate_commit.sh. For every directory
# apps/<app>/pull it commits a child of the candidate whose release reference differs, serves it as the candidate branch
# and reconciles it. A Job's template is immutable, so the pull layer applies the new reference only if Flux re-creates the
# Job: the cell waits for both layers to apply the new commit, requires the Job to be a new object, and then judges the
# new state with the cell of the first release. The new reference is the app's previous release, the latest tag and digest
# that the history of apps/<app> removed and the release no longer holds, so its digest is another valid image that the
# node has not pulled.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
cells="$(dirname "${BASH_SOURCE[0]}")"
served="$RUNNER_TEMP/candidate-source/repository.git"
transition="$RUNNER_TEMP/release-transition"

apps=()
for pull_directory in apps/*/pull; do
  [ -d "$pull_directory" ] || continue
  app="${pull_directory#apps/}"
  apps+=("${app%/pull}")
done
[ "${#apps[@]}" -gt 0 ] || fail "no directory apps/<app>/pull exists"

# namespace and uid of each Job pull, one line each.
job_uids() { kubectl get jobs --all-namespaces --field-selector=metadata.name=pull \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.uid}{"\n"}{end}' | sort; }
jobs_before="$(job_uids)"
[ -n "$jobs_before" ] || fail "no Job pull exists before the release changes"

git worktree add --quiet --detach "$transition" "$CANDIDATE_REVISION"
trap 'git worktree remove --force "$transition"' EXIT
for app in "${apps[@]}"; do
  release="$transition/apps/$app/release/kustomization.yaml"
  [ -f "$release" ] || fail "the pull layer of $app has no release at apps/$app/release/kustomization.yaml"
  current_tag="$(yq '.images[].newTag' "$release")"
  current_digest="$(yq '.images[].digest' "$release")"
  # "<tag> <digest>" of each release removed from apps/<app>, newest first, whichever file held it.
  previous="$(git -C "$transition" log -p -U0 --format= "$CANDIDATE_REVISION" -- "apps/$app" |
    awk '/^-[[:space:]]+newTag: /{tag=$3} /^-[[:space:]]+digest: sha256:/{print tag, $3}' |
    { grep -v -F " $current_digest" || true; } | sed -n 1p)"
  [ -n "$previous" ] || fail "the history of apps/$app holds no release with another digest than $current_digest"
  NEW_TAG="${previous% *}" NEW_DIGEST="${previous#* }" yq --inplace '.images[].newTag = strenv(NEW_TAG) | .images[].digest = strenv(NEW_DIGEST)' "$release"
  echo "the release of $app moves from $current_tag@$current_digest to ${previous% *}@${previous#* }"
done
git -C "$transition" -c user.name="release transition" -c user.email="release-transition@invalid" \
  commit --quiet --no-verify --all --message="Change the release reference of every pull layer's app"
new_revision="$(git -C "$transition" rev-parse HEAD)"
git push --quiet "$served" "${new_revision}:refs/heads/${CANDIDATE_BRANCH}"
echo "the candidate branch serves $new_revision, a child of $CANDIDATE_REVISION"

scratch="$(mktemp -d)"
RUNNER_TEMP="$scratch" CANDIDATE_REVISION="$new_revision" "$cells/../flux/reconcile_the_candidate_tree.sh" >/dev/null
flux reconcile kustomization flux-system --with-source --timeout=5m

layer_applied() {
  [ "$(kubectl --namespace flux-system get kustomization "$1" \
    -o jsonpath='{.status.lastAppliedRevision}{" "}{.status.conditions[?(@.type=="Ready")].status}')" = "${CANDIDATE_BRANCH}@sha1:${new_revision} True" ]
}
for app in "${apps[@]}"; do
  until_true 300 "the Kustomization $app-pull applied $new_revision" layer_applied "$app-pull"
  until_true 300 "the Kustomization $app applied $new_revision" layer_applied "$app"
  echo "the Kustomizations $app-pull and $app applied $new_revision"
done

jobs_after="$(job_uids)"
while read -r namespace uid; do
  [[ $'\n'"$jobs_after"$'\n' != *$'\n'"$namespace $uid"$'\n'* ]] || fail "the Job $namespace/pull is the object it was before the release changed"
  echo "the Job $namespace/pull of $uid was replaced"
done <<<"$jobs_before"

CANDIDATE_REVISION="$new_revision" "$cells/pull_layers_finish_before_their_app_rolls.sh"
