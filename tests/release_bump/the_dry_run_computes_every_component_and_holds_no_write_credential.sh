#!/usr/bin/env bash
# Run the steps of release-bump.yml's job compute, as yq reads them from the file, in the fixture world: a new release of
# one app gives a bump whose output the job keeps, another app that runs its newest release is current and an
# unfinished release waits; a refusal is a warning with the run green and the other apps still report; a failure of one
# app leaves the others reporting and their bumps kept, and then makes the run red. The cell also holds the protective
# limits: the permissions are no more than contents and packages read, no environment and no secret, only the schedule
# and the dispatch start it, its concurrency never cancels and the registry token reaches docker only through stdin.
# The cell runs only the checkout action and the artifact upload, the latter as a copy of its path, and takes over the
# tool installer, since the world holds the tools.
# Usage: mise exec -- tests/release_bump/the_dry_run_computes_every_component_and_holds_no_write_credential.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/world.sh"
source "$(dirname "${BASH_SOURCE[0]}")/job.sh"

workflow="${repository_root}/.github/workflows/release-bump.yml"
job_path=.jobs.compute
runs=0

# fake_step <step path> <uses> <script>: the artifact upload keeps what its path holds under its name; the tool installer
# does nothing.
fake_step() {
  local path artifact
  case "$2" in
    actions/upload-artifact@*)
      path="$(evaluate "$(yq "$1.with.path" "${workflow}")")"
      [ -n "$(ls -A "${path}" 2>/dev/null)" ] || fail "the job uploads an artifact with no file"
      artifact="${job_directory}/artifacts/$(evaluate "$(yq "$1.with.name" "${workflow}")")"
      mkdir -p "${artifact}"
      cp -r "${path}/." "${artifact}"
      return 0
      ;;
  esac
  [[ $3 == *'bootstrap_pc.sh --only tools'* ]]
}
# dry_run: the job's steps in a fresh workspace; sets job_status, job_log and job_directory.
dry_run() {
  job_directory="${work}/job-$((++runs))"
  context=(["github.token"]=fixture-token)
  run_job_steps "${workflow}" "${job_path}" "${job_directory}"
}
# expect_summary <app> <text>: the step summary names the app with the text in one line.
expect_summary() {
  grep -E "(^|[^a-z-])$1([^a-z-]).*$2" "${job_directory}/summary" >/dev/null ||
    fail "the summary does not give $1 '$2': $(cat "${job_directory}/summary") (log: $(cat "${job_log}"))"
}
# kept_bumps: the apps whose output the job kept, in the one artifact it uploaded.
kept_bumps() {
  local artifact
  for artifact in "${job_directory}/artifacts"/*/*; do
    [ ! -e "${artifact}" ] || basename "${artifact}"
  done
}

hopin_image=ghcr.io/overnightworks/hopin
speech_image=ghcr.io/overnightworks/speech
speech_release "${fixture_main_release}"

# A new release gives a bump the job keeps; the app that runs its newest release is current.
app_release 2026.11.24.1
registry_add "${hopin_image}" 2026.11.24.1
dry_run
[ "${job_status}" -eq 0 ] || fail "a run with a new release is red: $(cat "${job_log}")"
expect_summary hopin bump
expect_summary speech-runtime current
[ "$(kept_bumps)" = hopin ] || fail "the job kept the output of '$(kept_bumps | tr '\n' ' ')', not of hopin"
[ "$(cat "${job_directory}/artifacts/"*/hopin/outcome)" = bump ] && [ -s "$(echo "${job_directory}/artifacts/"*/hopin/patch)" ] || fail "the kept output of hopin holds no patch"
[ "$(calls "${work}/docker-calls" '^docker login')" -eq 1 ] || fail "the job did not log in once"
! grep -q fixture-token "${work}/docker-calls" || fail "the registry token reached an argument of docker"
echo "a new release is a bump whose output the job keeps, and an app on its newest release is current"

# An unfinished release waits and keeps nothing.
app_release 2026.11.25.1
dry_run
[ "${job_status}" -eq 0 ] || fail "a run with an unfinished release is red: $(cat "${job_log}")"
expect_summary hopin waiting
[ ! -e "${job_directory}/artifacts" ] || fail "the job kept an output for no bump"
echo "an unfinished release waits and keeps nothing"

# A refusal is a warning with the run green, and the other apps still report.
app_release 2026.11.26.1 remove
registry_add "${hopin_image}" 2026.11.26.1
speech_release 2026.11.30.1
registry_add "${speech_image}" 2026.11.30.1
registry_add "${speech_image}" "2026.11.30.1${APP_IMAGE_VARIANT_SUFFIX}"
dry_run
[ "${job_status}" -eq 0 ] || fail "a refusal made the run red: $(cat "${job_log}")"
grep -q '^::warning.*hopin' "${job_log}" || fail "the refusal of hopin is no warning: $(cat "${job_log}")"
expect_summary hopin refused
expect_summary speech-runtime bump
[ "$(kept_bumps)" = speech-runtime ] || fail "the job kept the output of '$(kept_bumps | tr '\n' ' ')', not of speech-runtime"
echo "a refusal is a warning with the run green, and the other apps still report"

# A failure of one app leaves the others reporting and their bumps kept, and then makes the run red.
git -C "${app_repository}" -c user.name=fixture -c user.email=fixture@example.org tag -a v2026.11.29.1 -m unreadable "$(git -C "${app_repository}" hash-object -w --stdin <<<unreadable)"
git -C "${app_repository}" push --quiet "file://${work}/remote/overnightworks/hopin" --tags
registry_add "${hopin_image}" 2026.11.29.1
dry_run
[ "${job_status}" -ne 0 ] || fail "a failed app left the run green: $(cat "${job_log}")"
grep -q '^::error.*hopin' "${job_log}" || fail "the failure of hopin is no error: $(cat "${job_log}")"
expect_summary hopin failed
expect_summary speech-runtime bump
[ "$(kept_bumps)" = speech-runtime ] || fail "the job kept the output of '$(kept_bumps | tr '\n' ' ')', not of speech-runtime"
echo "a failure of one app leaves the others reporting, keeps their bumps and makes the run red"

# The protective limits.
[ "$(yq '.permissions | length' "${workflow}")" -eq 0 ] || fail "the workflow grants permissions to every job"
[ "$(yq '.jobs | keys | length' "${workflow}")" -eq 1 ] || fail "the workflow holds more than the one job"
[ "$(yq '.jobs.compute.permissions | tag' "${workflow}")" = '!!map' ] || fail "the job's permissions are no map of scopes"
[ -z "$(yq '.jobs.compute.permissions | to_entries | .[] | select(.value != "read" or (.key != "contents" and .key != "packages")) | .key' "${workflow}")" ] ||
  fail "the job's permissions are more than contents and packages read"
[ "$(yq '[.. | select(tag == "!!map" and has("environment"))] | length' "${workflow}")" -eq 0 ] || fail "the workflow names an environment"
! grep -qE 'secrets\.' "${workflow}" || fail "the workflow names a secret"
[ "$(yq '.on | tag' "${workflow}")" = '!!map' ] || fail "the events are no map"
[ -z "$(yq '.on | keys | .[] | select(. != "schedule" and . != "workflow_dispatch")' "${workflow}")" ] || fail "an event but the schedule and the dispatch starts the workflow"
[ "$(yq '.concurrency.cancel-in-progress' "${workflow}")" = false ] || fail "the concurrency group cancels a run in progress"
echo "the job holds no more than contents and packages read, no environment, no secret and no cancelling group"
