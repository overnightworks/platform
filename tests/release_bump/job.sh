# shellcheck shell=bash
# Sourced by the cells under tests/release_bump/ that run the steps of a workflow job as yq reads them from its file, in
# the fixture world of world.sh: the checkout action is a plain git fetch of the platform remote, and every other step
# is its run script under the environment a runner gives it. A cell defines `fake_step` to take over a step (it gets the
# step's yq path, its `uses` and its run script, and returns 0 when it ran the step instead); a step that uses an action
# no cell takes over, holds a condition other than a step's output or puts an expression into its script is refused.
declare -A context

# evaluate <text>: the text with each ${{ expression }} replaced by the cell's value, and no unknown expression.
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

# run_job_steps <workflow file> <job path> <directory>: every step of the job in a fresh workspace under the directory,
# in order, as the runner would; sets job_status (0, or the status of the first failing step) and job_log (what the
# steps printed). The runner's files are $directory/{summary,path,temp}, its step outputs $directory/outputs/<step id>.
run_job_steps() {
  local file="$1" job_path="$2" directory="$3" steps index step condition uses id variable script ref
  local condition_pattern="^steps\.([a-z-]+)\.outputs\.([a-z-]+) == '([a-z]*)'\$"
  local -a step_env
  mkdir -p "${directory}/workspace" "${directory}/outputs" "${directory}/temp"
  job_log="${directory}/log"
  : >"${job_log}"
  job_status=0
  context["runner.temp"]="${directory}/temp"
  steps="$(yq "${job_path}.steps | length" "${file}")"
  for ((index = 0; index < steps; index++)); do
    step="${job_path}.steps[${index}]"
    id="$(yq "${step}.id // \"\"" "${file}")"
    condition="$(yq "${step}.if // \"\"" "${file}")"
    if [ -n "${condition}" ]; then
      [[ ${condition} =~ ${condition_pattern} ]] || fail "the cell reads no condition like '${condition}'"
      [ "$(sed -n "s/^${BASH_REMATCH[2]}=//p" "${directory}/outputs/${BASH_REMATCH[1]}")" = "${BASH_REMATCH[3]}" ] || continue
    fi
    uses="$(yq "${step}.uses // \"\"" "${file}")"
    script="$(yq "${step}.run // \"\"" "${file}")"
    if [[ ${uses} == actions/checkout@* ]]; then
      [ "$(yq "${step}.with.persist-credentials" "${file}")" = false ] || fail "the checkout keeps the credentials"
      ref="$(evaluate "$(yq "${step}.with.ref // \"\"" "${file}")")"
      git -C "${directory}/workspace" init --quiet
      git -C "${directory}/workspace" remote add origin https://github.com/overnightworks/platform
      git -C "${directory}/workspace" fetch --quiet --no-tags --depth=1 origin "${ref:-main}"
      git -C "${directory}/workspace" checkout --quiet --detach FETCH_HEAD
      continue
    fi
    if declare -F fake_step >/dev/null && fake_step "${step}" "${uses}" "${script}"; then
      continue
    fi
    [ -z "${uses}" ] || fail "the cell runs no action but checkout: ${uses}"
    [[ ${script} != *'${{'* ]] || fail "step $((index + 1)) puts an expression into its script, not into its env"
    step_env=("GITHUB_OUTPUT=${directory}/outputs/${id:-none}" "GITHUB_STEP_SUMMARY=${directory}/summary"
      "GITHUB_PATH=${directory}/path" "RUNNER_TEMP=${directory}/temp" "GITHUB_ACTOR=fixture-user")
    while IFS= read -r variable; do
      [ -z "${variable}" ] || step_env+=("${variable%%=*}=$(evaluate "${variable#*=}")")
    done < <(yq "${step}.env // {} | to_entries | .[] | .key + \"=\" + .value" "${file}")
    (cd "${directory}/workspace" && env "${step_env[@]}" bash -e -c "${script}") >>"${job_log}" 2>&1 || {
      job_status=$?
      return 0
    }
  done
}
