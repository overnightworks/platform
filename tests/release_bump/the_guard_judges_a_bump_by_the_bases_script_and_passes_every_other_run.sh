#!/usr/bin/env bash
# Run the steps of ci.yml's release-bump-scope job, as yq reads them from the file, against a fixture platform remote:
# an allowed bump passes, also one of an app whose Component names two variants of one repository; a script, another app's table or file, a name change, an older version, a deletion, a mode or
# type change and a rename out of a protected path are red, as are a Component whose images sit at two versions and a
# variant that moves between base and bump; a head that edits the guard stays red, since the base's
# script judges; a bump whose base lacks the script is red; a push, a schedule, a dispatch, a pull request from another
# branch and one from a fork pass with one line. The cell runs only the checkout action, by a plain git fetch of the
# ref the step names, and refuses any other action, expression or condition the job comes to use.
# Usage: mise exec -- tests/release_bump/the_guard_judges_a_bump_by_the_bases_script_and_passes_every_other_run.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/world.sh"

ci="${repository_root}/.github/workflows/ci.yml"
job_path='.jobs."release-bump-scope"'
repository=overnightworks/platform
printf '#!/usr/bin/env bash\necho "the guard runs no mise: $*" >&2\nexit 98\n' >"${work}/denied/mise"
chmod +x "${work}/denied/mise"

declare -A context
runs=0
# open_pull_request <change command>...: the pull request's merge commit in the fixture remote, whose first parent is the
# tip of base_branch and whose second holds what the change command edits in a clone of the base.
base_branch=main
open_pull_request() {
  local directory="${work}/pull-request-$((++runs))" identity=(-c user.name=fixture -c user.email=fixture@example.org)
  clone_main "${directory}"
  git -C "${directory}" checkout --quiet "${base_branch}"
  base_sha="$(git -C "${directory}" rev-parse HEAD)"
  git -C "${directory}" checkout --quiet -b head
  (cd "${directory}" && "$@")
  git -C "${directory}" add --all
  git -C "${directory}" "${identity[@]}" commit --quiet --allow-empty --message "the head"
  git -C "${directory}" checkout --quiet --detach "${base_sha}"
  git -C "${directory}" "${identity[@]}" merge --quiet --no-ff --message "the merge" head
  merge_sha="$(git -C "${directory}" rev-parse HEAD)"
  git -C "${directory}" push --quiet origin "HEAD:refs/pull/${runs}/merge"
}

# evaluate <text>: the text with each ${{ expression }} replaced by the event's value, and no unknown expression.
evaluate() {
  local text="$1" expression
  local pattern='\$\{\{ *([^} ]+) *\}\}'
  while [[ ${text} =~ ${pattern} ]]; do
    expression="${BASH_REMATCH[1]}"
    [ -n "${context[${expression}]+set}" ] || fail "the job reads ${expression}, which the cell's event does not hold"
    text="${text/"${BASH_REMATCH[0]}"/${context[${expression}]}}"
  done
  printf '%s' "${text}"
}

# run_job <event name> <head ref> <head repository>: every step of the job in a fresh workspace, in order, as the runner
# would; sets job_status (0, or the status of the first failing step) and job_log (what the steps printed).
run_job() {
  local directory="${work}/job-$((++runs))" steps index step condition uses id variable script
  local condition_pattern="^steps\.([a-z-]+)\.outputs\.([a-z-]+) == '([a-z]*)'\$"
  local -a step_env
  mkdir -p "${directory}/workspace" "${directory}/outputs"
  job_log="${directory}/log"
  : >"${job_log}"
  job_status=0
  context=(["github.event_name"]="$1" ["github.event.pull_request.head.ref"]="$2" ["github.event.pull_request.head.repo.full_name"]="$3"
    ["github.event.pull_request.base.sha"]="${base_sha:-}" ["github.sha"]="${merge_sha:-}" ["github.repository"]="${repository}")
  steps="$(yq "${job_path}.steps | length" "${ci}")"
  for ((index = 0; index < steps; index++)); do
    step="${job_path}.steps[${index}]"
    id="$(yq "${step}.id // \"\"" "${ci}")"
    condition="$(yq "${step}.if // \"\"" "${ci}")"
    if [ -n "${condition}" ]; then
      [[ ${condition} =~ ${condition_pattern} ]] || fail "the cell reads no condition like '${condition}'"
      [ "$(sed -n "s/^${BASH_REMATCH[2]}=//p" "${directory}/outputs/${BASH_REMATCH[1]}")" = "${BASH_REMATCH[3]}" ] || continue
    fi
    uses="$(yq "${step}.uses // \"\"" "${ci}")"
    if [ -n "${uses}" ]; then
      [[ ${uses} == actions/checkout@* ]] || fail "the cell runs no action but checkout: ${uses}"
      [ "$(yq "${step}.with.persist-credentials" "${ci}")" = false ] || fail "the checkout keeps the credentials"
      git -C "${directory}/workspace" init --quiet
      git -C "${directory}/workspace" remote add origin https://github.com/overnightworks/platform
      git -C "${directory}/workspace" fetch --quiet --no-tags --depth=1 origin "$(evaluate "$(yq "${step}.with.ref" "${ci}")")"
      git -C "${directory}/workspace" checkout --quiet --detach FETCH_HEAD
      continue
    fi
    script="$(yq "${step}.run" "${ci}")"
    [[ ${script} != *'${{'* ]] || fail "step $((index + 1)) puts an expression into its script, not into its env"
    step_env=("GITHUB_OUTPUT=${directory}/outputs/${id:-none}")
    while IFS= read -r variable; do
      [ -z "${variable}" ] || step_env+=("${variable%%=*}=$(evaluate "${variable#*=}")")
    done < <(yq "${step}.env // {} | to_entries | .[] | .key + \"=\" + .value" "${ci}")
    (cd "${directory}/workspace" && env "${step_env[@]}" bash -e -c "${script}") >>"${job_log}" 2>&1 || {
      job_status=$?
      return 0
    }
  done
}

# expect_green <description> <expected text> <run_job arguments>
expect_green() {
  local description="$1" expected="$2"
  shift 2
  run_job "$@"
  [ "${job_status}" -eq 0 ] || fail "${description} is red: $(cat "${job_log}")"
  grep -qF -- "${expected}" "${job_log}" || fail "${description} does not say '${expected}': $(cat "${job_log}")"
  echo "${description} is green: $(tail -n 1 "${job_log}")"
}
# expect_red <description> <expected text> <change command>...: the change on a bump pull request.
expect_red() {
  local description="$1" expected="$2"
  shift 2
  open_pull_request "$@"
  run_job pull_request release/hopin "${repository}"
  [ "${job_status}" -ne 0 ] || fail "the mutant '${description}' passed the guard: $(cat "${job_log}")"
  grep -qF -- "${expected}" "${job_log}" || fail "the mutant '${description}' is red for another reason than '${expected}': $(cat "${job_log}")"
  echo "the mutant '${description}' is red: $(grep -F -- "${expected}" "${job_log}" | head -n 1)"
}

# What a release bump of hopin changes: the Component, a legal copy, its entry and a rebuilt page.
newest=2099.12.31.1
set_component() { # <version> <digest>
  sed -i -E "s/newTag: .*/newTag: $1/; s/digest: .*/digest: $2/" apps/hopin/release/kustomization.yaml
}
bump() {
  set_component "${newest}" "$(digest_of ghcr.io/overnightworks/hopin "${newest}")"
  echo '<p>new</p>' >>infrastructure/legal/app-texts/hopin/datenschutz.html
  sed -i '/^\[hopin.datenschutz\]/,/^$/ s/^sha256 = .*/sha256 = "0000000000000000000000000000000000000000000000000000000000000000"/' infrastructure/legal/app-texts.toml
  echo '<p>new</p>' >>infrastructure/legal/built/datenschutz.html
}
# What a release bump of speech-runtime changes: both images of its Component, to one version, each with its variant.
speech_component=apps/speech-runtime/release/kustomization.yaml
move_speech_image() { # <index> <version>
  local variant
  variant="$(yq ".images[$1].newTag" "${speech_component}")" variant="${variant#"${fixture_main_release}"}"
  INDEX="$1" TAG="$2${variant}" DIGEST="$(digest_of ghcr.io/overnightworks/speech "$2${variant}")" \
    yq -i '.images[env(INDEX)] |= (.newTag = strenv(TAG) | .digest = strenv(DIGEST))' "${speech_component}"
}
bump_speech() { move_speech_image 0 "${newest}"; move_speech_image 1 "${newest}"; }
bump_one_speech_image() { move_speech_image 0 "${newest}"; }
bump_speech_images_to_two_versions() { move_speech_image 0 "${newest}"; move_speech_image 1 2099.12.30.1; }
bump_and() { bump; "$@"; }
bump_speech_and() { bump_speech; "$@"; }
add_a_script() { echo 'echo hi' >scripts/added.sh; }
edit_a_script() { echo 'echo hi' >>scripts/release_bump_compute.sh; }
edit_the_guard() { echo 'exit 0' >scripts/release_bump_scope.sh; }
edit_the_list_outside_the_app() { sed -i '/^\[skat.datenschutz\]/,/^$/ s/^sha256 = .*/sha256 = "1111111111111111111111111111111111111111111111111111111111111111"/' infrastructure/legal/app-texts.toml; }
add_an_indented_table_of_another_app_inside_the_app() { sed -i '/^\[hopin.datenschutz\]/i \  [skat.extra]\ndate = 2026-11-23\n' infrastructure/legal/app-texts.toml; }
edit_another_apps_copy() { echo '<p>new</p>' >>infrastructure/legal/app-texts/skat/datenschutz.html; }
rename_the_image() { sed -i 's|ghcr.io/overnightworks/hopin|ghcr.io/overnightworks/hopin-other|' apps/hopin/release/kustomization.yaml; }
edit_another_field() { sed -i 's|image-volume.yaml|other.yaml|' apps/hopin/release/kustomization.yaml; }
add_a_variant() { set_component "${newest}${APP_IMAGE_VARIANT_SUFFIX}" "$(digest_of ghcr.io/overnightworks/hopin "${newest}${APP_IMAGE_VARIANT_SUFFIX}")"; }
swap_the_variants() {
  INDEX=0 TAG="${newest}${APP_IMAGE_VARIANT_SUFFIX}" yq -i '.images[env(INDEX)].newTag = strenv(TAG)' "${speech_component}"
  INDEX=1 TAG="${newest}" yq -i '.images[env(INDEX)].newTag = strenv(TAG)' "${speech_component}"
}
run_a_tag_that_is_no_release() { set_component latest "$(digest_of ghcr.io/overnightworks/hopin latest)"; }
run_an_older_release() { set_component 2020.01.01.1 "$(digest_of ghcr.io/overnightworks/hopin 2020.01.01.1)"; }
run_the_same_release() { set_component "${main_version}" "$(digest_of ghcr.io/overnightworks/hopin other)"; }
write_a_bad_digest() { set_component "${newest}" sha256:abc; }
delete_a_page() { git rm --quiet infrastructure/legal/built/impressum.html; }
change_a_mode() { chmod +x infrastructure/legal/built/impressum.html; }
link_a_page() { ln -sf datenschutz.html infrastructure/legal/built/impressum.html; }
move_a_page_out() { git mv infrastructure/legal/built/impressum.html apps/hopin/impressum.html; }
move_a_script_in() { git mv scripts/release_bump_newest.sh infrastructure/legal/built/newest.html; }
# publish_a_base_without_the_guard: the branch no-guard, main without scripts/release_bump_scope.sh.
publish_a_base_without_the_guard() {
  clone_main "${work}/no-guard"
  git -C "${work}/no-guard" rm --quiet scripts/release_bump_scope.sh
  git -C "${work}/no-guard" -c user.name=fixture -c user.email=fixture@example.org commit --quiet --message "no guard"
  git -C "${work}/no-guard" push --quiet origin HEAD:refs/heads/no-guard
}
touch_nothing() { :; }

open_pull_request bump
expect_green "an allowed bump" "the bump of hopin is in scope" pull_request release/hopin "${repository}"

open_pull_request bump_speech
expect_green "a bump of two variants of one repository" "the bump of speech-runtime is in scope" pull_request release/speech-runtime "${repository}"

expect_red "a bump that adds a script" "scripts/added.sh is outside what a bump changes" bump_and add_a_script
expect_red "a bump that edits a script" "scripts/release_bump_compute.sh is outside what a bump changes" bump_and edit_a_script
expect_red "a bump that edits another app's table" "changes outside the tables of hopin" bump_and edit_the_list_outside_the_app
expect_red "a bump that adds an indented table of another app inside the app's tables" "changes outside the tables of hopin" bump_and add_an_indented_table_of_another_app_inside_the_app
expect_red "a bump that edits another app's copy" "name 2 apps" bump_and edit_another_apps_copy
expect_red "a bump that renames an image" "their names or variants" bump_and rename_the_image
expect_red "a bump that edits another field of the Component" "more than the version and digest" bump_and edit_another_field
expect_red "a bump to a tag that is no release version" "which is no release version" bump_and run_a_tag_that_is_no_release
expect_red "a bump to an older release" "not newer than" bump_and run_an_older_release
expect_red "a bump that keeps the version" "not newer than" bump_and run_the_same_release
expect_red "a bump that moves one of two variant images" "not at one version in the merge" bump_one_speech_image
expect_red "a bump that moves two variant images to two versions" "not at one version in the merge" bump_speech_images_to_two_versions
expect_red "a bump that adds a variant to an image" "or their names or variants" bump_and add_a_variant
expect_red "a bump that swaps the variants of two images" "or their names or variants" bump_speech_and swap_the_variants
expect_red "a bump with a bad digest" "no sha256 digest" bump_and write_a_bad_digest
expect_red "a bump that deletes a page" "is D from mode 100644 to 000000" bump_and delete_a_page
expect_red "a bump that changes a page's mode" "from mode 100644 to 100755" bump_and change_a_mode
expect_red "a bump that makes a page a link" "from mode 100644 to 120000" bump_and link_a_page
expect_red "a bump that moves a page out of a protected path" "apps/hopin/impressum.html is outside what a bump changes" bump_and move_a_page_out
expect_red "a bump that moves a script into a protected path" "a bump only edits regular files" bump_and move_a_script_in
expect_red "a bump with no change" "name 0 apps" touch_nothing
expect_red "a head that replaces the guard" "scripts/release_bump_scope.sh is outside what a bump changes" bump_and edit_the_guard

publish_a_base_without_the_guard
base_branch=no-guard
expect_red "a bump whose base lacks the script" "holds no scripts/release_bump_scope.sh" bump
base_branch=main

open_pull_request add_a_script
for event in push schedule workflow_dispatch; do
  expect_green "a ${event} run" "no release bump" "${event}" "" ""
  [ "$(grep -c . "${job_log}")" -eq 1 ] || fail "a ${event} run prints more than one line: $(cat "${job_log}")"
done
expect_green "a pull request from another branch" "no release bump" pull_request feature/hopin "${repository}"
[ "$(grep -c . "${job_log}")" -eq 1 ] || fail "a pull request from another branch prints more than one line: $(cat "${job_log}")"
expect_green "a pull request from a fork's release branch" "no release bump" pull_request release/hopin someone/platform
[ "$(grep -c . "${job_log}")" -eq 1 ] || fail "a pull request from a fork prints more than one line: $(cat "${job_log}")"
