#!/usr/bin/env bash
# Drive scripts/presentator_load_database.sh against fake kubectl, flux, yq and python3 on PATH: the states it names where
# the load is refused, its outcome is unknown, the rollout fails after a verified load, a signal arrives or the lock is
# unavailable, none of which the cluster cell can arrange on demand. The script's copy differs from it in its lock path
# alone, which points into the cell's directory.
# Usage: tests/presentator/load_database.sh
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"

# FAKE_SUSPENDED is what the Kustomization reports, FAKE_LOAD_EXIT the exit of the remote load, FAKE_ROLLOUT the
# rollout and FAKE_DELETE the loader's deletion: ok, fails or hangs until killed; FAKE_STOP=hangs makes the listing of
# the Deployments, which comes after the suspension, hang until killed. The remote shell runs here with the fake python3 in place of the image's.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/kubectl.log"
case "$*" in
  *"get configmap"*) printf users ;;
  *"get kustomization"*) printf '%s' "${FAKE_SUSPENDED:-false}" ;;
  *"get deployment "*) echo '{}' ;;
  *"get deployments"*)
    if [ "${FAKE_STOP:-ok}" = hangs ]; then echo $$ >"$FAKE_DIR/hang-pid"; exec sleep 60; fi
    echo deployment.apps/web ;;
  *"delete pod"*)
    case "${FAKE_DELETE:-ok}" in
      fails) exit 1 ;;
      hangs) echo $$ >"$FAKE_DIR/hang-pid"; exec sleep 60 ;;
    esac ;;
  *"get pods"*) echo 'items: []' ;;
  *"cat >/staging/copy"*) cat >/dev/null ;;
  *sqlite_copy.py*)
    echo "kubectl-own-line" >&2
    while [ "$1" != -- ]; do shift; done
    shift
    export PRESENTATOR_DATABASE=/live
    exec "${@//\/sqlite\/key-table/$FAKE_DIR/key-table}" ;;
  *"rollout status"*)
    case "${FAKE_ROLLOUT:-ok}" in
      fails) exit 1 ;;
      hangs) echo $$ >"$FAKE_DIR/hang-pid"; exec sleep 60 ;;
    esac ;;
esac
FAKE
cat >"$fake_bin/flux" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >>"$FAKE_DIR/flux.log"
FAKE
cat >"$fake_bin/yq" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
case "$*" in *items*) ;; *) echo '{}' ;; esac
FAKE
cat >"$fake_bin/python3" <<'FAKE'
#!/usr/bin/env bash
echo "remote-stderr-line" >&2
[ "${FAKE_LOAD_EXIT:-0}" != 0 ] || echo 3
exit "${FAKE_LOAD_EXIT:-0}"
FAKE
chmod +x "$fake_bin"/*
# The tools are fakes and no cluster is named, so a call that leaks to a real one fails.
export PATH="$fake_bin:$PATH" MISE_DISABLE_TOOLS=kubectl,flux,flux2,yq KUBECONFIG="$work_directory/no-kubeconfig"
copy="$work_directory/copy.sqlite3"
printf 'copy' >"$copy"

# prepare: the cell's directory, the script with the lock in it and a lock path that may be overridden.
prepare() {
  export FAKE_DIR="$work_directory/state-$cell"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/kubectl.log"
  : >"$FAKE_DIR/flux.log"
  printf users >"$FAKE_DIR/key-table"
  lock="${lock_path:-$FAKE_DIR/lock}"
  sed "s#^lock=.*#lock=$lock#" "$repository_root/scripts/presentator_load_database.sh" >"$FAKE_DIR/script.sh"
}
# run_load: sets status, output, flux_calls and loads (how many times the remote load was called).
run_load() {
  prepare
  status=0
  output="$(bash "$FAKE_DIR/script.sh" "$copy" 2>&1)" || status=$?
  collect
}
collect() {
  flux_calls="$(tr '\n' ' ' <"$FAKE_DIR/flux.log")"
  loads="$(grep -c sqlite_copy.py "$FAKE_DIR/kubectl.log" || true)"
}
expect() {
  local description="$1"
  shift
  "$@" || fail "$cell: $description; exit $status, flux $flux_calls, loads $loads: $output"
}
printed() { [[ $output == *"$1"* ]]; }
not_printed() { ! printed "$1"; }

cell_a_clean_load_converges_resumes_once_and_deletes_the_loader() {
  cell=clean
  run_load
  expect "exit 0 with the converged line" test "$status" = 0
  expect "the converged line" printed "presentator converged"
  expect "Flux suspended and resumed once" test "$flux_calls" = "suspend resume "
  expect "the loader deleted last" test "$(grep -E '^--namespace presentator (create|delete pod)' "$FAKE_DIR/kubectl.log" | tail -1)" = "--namespace presentator delete pod presentator-load --ignore-not-found --wait"
}

cell_a_failed_rollout_after_a_verified_load_names_that_state_and_loads_no_second_time() {
  cell=rollout-fails
  FAKE_ROLLOUT=fails run_load
  expect "a non-zero exit" test "$status" != 0
  expect "the verified state" printed "the load is verified"
  expect "no way back that loads again" not_printed "run the same command again"
  expect "the way finishing by hand" printed "do not load again"
  expect "one load" test "$loads" = 1
}

cell_a_term_during_the_rollout_after_a_verified_load_names_that_state() {
  cell=term-in-rollout
  prepare
  FAKE_ROLLOUT=hangs bash "$FAKE_DIR/script.sh" "$copy" >"$FAKE_DIR/output" 2>&1 &
  script_pid=$!
  until_true 30 "the rollout wait started" test -s "$FAKE_DIR/hang-pid"
  kill -TERM "$script_pid"
  kill -TERM "$(cat "$FAKE_DIR/hang-pid")"
  status=0
  wait "$script_pid" || status=$?
  output="$(cat "$FAKE_DIR/output")"
  collect
  expect "a non-zero exit" test "$status" != 0
  expect "the verified state" printed "the load is verified"
  expect "no way back that loads again" not_printed "run the same command again"
  expect "one load" test "$loads" = 1
}

cell_a_refused_source_leaves_the_database_unchanged_and_resumes_flux() {
  cell=refused
  FAKE_LOAD_EXIT=7 run_load
  expect "exit 1" test "$status" = 1
  expect "the unchanged line" printed "the copy is refused; the database is unchanged"
  expect "Flux resumed" test "$flux_calls" = "suspend resume "
}

cell_an_unknown_outcome_stays_suspended_and_names_the_same_command() {
  cell=unknown
  FAKE_LOAD_EXIT=137 run_load
  expect "a non-zero exit" test "$status" != 0
  expect "the way back" printed "run the same command again"
  expect "Flux suspended and not resumed" test "$flux_calls" = "suspend "
}

cell_a_suspension_found_stays_unless_a_load_is_verified() {
  cell=found-suspended-refused
  FAKE_SUSPENDED=true FAKE_LOAD_EXIT=7 run_load
  expect "the web at 0 named" printed "stays suspended as it was and the web at 0"
  expect "Flux untouched" test -z "$flux_calls"
  cell=found-suspended-verified
  FAKE_SUSPENDED=true run_load
  expect "exit 0" test "$status" = 0
  expect "Flux resumed without a suspend" test "$flux_calls" = "resume "
}

# run_signalled <signal>: starts the script, waits for a fake that hangs, sends the signal to the script and ends the
# hanging fake, so the script's trap runs as it would after the client returned.
run_signalled() {
  prepare
  bash "$FAKE_DIR/script.sh" "$copy" >"$FAKE_DIR/output" 2>&1 &
  script_pid=$!
  until_true 30 "a fake hangs" test -s "$FAKE_DIR/hang-pid"
  kill -"$1" "$script_pid"
  kill -TERM "$(cat "$FAKE_DIR/hang-pid")"
  status=0
  wait "$script_pid" || status=$?
  output="$(cat "$FAKE_DIR/output")"
  collect
}

cell_a_failed_first_delete_names_only_what_is_true() {
  cell=first-delete-fails
  FAKE_DELETE=fails run_load
  expect "a non-zero exit" test "$status" != 0
  expect "no state of a suspension" not_printed "suspended"
  expect "no stopped web" not_printed "web at 0"
  expect "Flux untouched" test -z "$flux_calls"
  cell=first-delete-fails-found-suspended
  FAKE_SUSPENDED=true FAKE_DELETE=fails run_load
  expect "a non-zero exit" test "$status" != 0
  expect "no stopped web" not_printed "web at 0"
  expect "Flux untouched" test -z "$flux_calls"
}

cell_a_term_during_the_first_delete_names_only_what_is_true() {
  cell=term-in-first-delete
  FAKE_DELETE=hangs run_signalled TERM
  expect "a non-zero exit" test "$status" != 0
  expect "no state of a suspension" not_printed "suspended"
  expect "no stopped web" not_printed "web at 0"
  expect "Flux untouched" test -z "$flux_calls"
}

cell_a_hup_after_the_suspension_resumes_flux_like_a_term() {
  cell=hup-after-suspend
  FAKE_STOP=hangs run_signalled HUP
  expect "a non-zero exit" test "$status" != 0
  expect "the unchanged state" printed "the database is unchanged; resuming the Kustomization"
  expect "Flux suspended and resumed" test "$flux_calls" = "suspend resume "
  cell=hup-after-found-suspended
  FAKE_SUSPENDED=true FAKE_STOP=hangs run_signalled HUP
  expect "a non-zero exit" test "$status" != 0
  expect "the suspension kept, the web not stopped" not_printed "web at 0"
  expect "the way back" printed "stays suspended as it was"
  expect "Flux untouched" test -z "$flux_calls"
}

cell_a_held_lock_is_refused_before_any_call_and_an_unopenable_one_names_its_file() {
  cell=lock_held
  prepare
  exec 8>>"$lock"
  flock -n 8
  status=0
  output="$(bash "$FAKE_DIR/script.sh" "$copy" 2>&1)" || status=$?
  exec 8>&-
  collect
  expect "a refusal that changed nothing" printed "holds $lock; nothing changed"
  expect "a non-zero exit" test "$status" != 0
  expect "no kubectl or flux call" test ! -s "$FAKE_DIR/kubectl.log" -a -z "$flux_calls"
  cell=lock_unopenable
  lock_path="$work_directory/no-directory/lock" run_load
  expect "its own refusal naming the file" printed "cannot open the lock file $lock; nothing changed"
  expect "no kubectl or flux call" test ! -s "$FAKE_DIR/kubectl.log" -a -z "$flux_calls"
}

cell_kubectls_stderr_reaches_the_output_and_the_remote_programs_does_not() {
  cell=stderr
  run_load
  expect "kubectl's line" printed "kubectl-own-line"
  expect "no remote line" not_printed "remote-stderr-line"
}

cells=(
  a_clean_load_converges_resumes_once_and_deletes_the_loader
  a_failed_rollout_after_a_verified_load_names_that_state_and_loads_no_second_time
  a_term_during_the_rollout_after_a_verified_load_names_that_state
  a_refused_source_leaves_the_database_unchanged_and_resumes_flux
  an_unknown_outcome_stays_suspended_and_names_the_same_command
  a_suspension_found_stays_unless_a_load_is_verified
  a_held_lock_is_refused_before_any_call_and_an_unopenable_one_names_its_file
  kubectls_stderr_reaches_the_output_and_the_remote_programs_does_not
  a_failed_first_delete_names_only_what_is_true
  a_term_during_the_first_delete_names_only_what_is_true
  a_hup_after_the_suspension_resumes_flux_like_a_term
)
failed=()
for name in "${cells[@]}"; do
  ("cell_$name") || failed+=("$name")
done
[ "${#failed[@]}" = 0 ] || { echo "::error::load_database: failed cells: ${failed[*]}" >&2; exit 1; }
echo "load_database: every cell held"
