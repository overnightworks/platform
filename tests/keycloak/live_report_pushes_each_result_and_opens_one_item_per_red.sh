#!/usr/bin/env bash
# Proves docs/operations.md OPS-22: drives scripts/live_check_report.sh against fakes of mise (which scripts the exits
# and result lines of `live:check` per attempt), kubectl (the Secret, the forward line, the `tunnel` Kustomization's
# suspend), curl (which records each push and checks the token it reads on stdin) and gh (which keeps the open items
# per app repository and searches them by title), for what the live stack cannot arrange: that a green pushes
# success=true once and opens no item; that a red then green pushes true once and opens none; that a red twice pushes
# false with the codes and opens one item at the app, naming the step and whose side the cause is on, unless one is
# open; that a skipped twice pushes nothing; that the command's lock (exit 4) is waited for and never pushed red; that
# the report's own lock serializes with a bound; that an offline platform pushes and opens nothing, also when it goes
# offline between the steps; that a failed push or item does not hide the other and fails the run; that `nightly` waits for
# the Deployment keycloak to be Available up to its bound, runs the sign-in for every app as `sign-in` does and does
# nothing while offline, also when the platform turns offline during the wait; that a TERM to the whole process group
# during a rerun ends the report with 143, a push of false and an item for no one and a forward for no one; and that the
# token stands in no argument, environment or output.
# Usage: tests/keycloak/live_report_pushes_each_result_and_opens_one_item_per_red.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
token=TOKENVALUE0123456789
apps=(hopin skat presentator songmaker)

# What the fakes share: the event log, the violation file and the scan of their own arguments and environment for the token.
cat >"$work_directory/fake_lib.sh" <<'FAKE'
log_event() { echo "$1" >>"$FAKE_STATE/log"; }
violate() { echo "$1" >>"$FAKE_STATE/violation"; }
scan_arguments_and_environment() {
  local name="$1" token
  shift
  token="$(<"$FAKE_STATE/token")"
  if [[ "$*" == *"$token"* ]]; then violate "$name: the token in an argument"; fi
  if env | grep -qF -- "$token"; then violate "$name: the token in the environment"; fi
}
FAKE

# mise: `run live:check <app>` pops the app's next scripted attempt from mise-<app>, whose lines read
# `<exit>|<stdout line>|<stderr line>`; the exit `hang` runs until a signal ends it.
cat >"$fake_bin/mise" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
scan_arguments_and_environment mise "$@"
[ "$1 $2" = "run live:check" ] || { violate "mise: unexpected $*"; exit 2; }
app="$3"
log_event "mise: live:check $app"
[ -s "$FAKE_STATE/mise-$app" ] || { violate "mise: no scripted attempt left for $app"; exit 1; }
IFS='|' read -r exit_code standard_line error_line <"$FAKE_STATE/mise-$app"
sed -i 1d "$FAKE_STATE/mise-$app"
if [ "$exit_code" = hang ]; then
  echo $$ >"$FAKE_STATE/hang-pid"
  log_event "mise: hanging"
  exec "$(command -p -v sleep)" 600
fi
[ -z "$standard_line" ] || echo "$standard_line"
[ -z "$error_line" ] || echo "$error_line" >&2
exit "$exit_code"
FAKE

# kubectl: the Secret's header on stdout, the forward line, the Service's port and the `tunnel` Kustomization's suspend,
# which is read from tunnel-reads, one line per read, the last one for every later read (`unreadable` fails the read), and
# the Available condition of the Deployment keycloak, read the same way from keycloak-reads.
# FAKE_FORWARD_FAILS ends the forward with no line, FAKE_SERVICE_HANGS makes the read of the Service gatus run until a
# signal ends it.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
scan_arguments_and_environment kubectl "$@"
case " $* " in
  *" get kustomization tunnel "*)
    value="$(head -n 1 "$FAKE_STATE/tunnel-reads")"
    [ "$(wc -l <"$FAKE_STATE/tunnel-reads")" -le 1 ] || sed -i 1d "$FAKE_STATE/tunnel-reads"
    log_event "kubectl: tunnel read $value"
    [ "$value" != unreadable ] || { echo "error: the server is unreachable" >&2; exit 1; }
    printf '%s' "$value" ;;
  *" get deployment keycloak "*)
    value="$(head -n 1 "$FAKE_STATE/keycloak-reads")"
    [ "$(wc -l <"$FAKE_STATE/keycloak-reads")" -le 1 ] || sed -i 1d "$FAKE_STATE/keycloak-reads"
    log_event "kubectl: keycloak read $value"
    [ "$value" != unreadable ] || { echo "error: the server is unreachable" >&2; exit 1; }
    printf '%s' "$value" ;;
  *" get service gatus "*)
    [ -z "${FAKE_SERVICE_HANGS:-}" ] || { log_event "kubectl: service read hangs"; exec "$(command -p -v sleep)" 600; }
    echo 8080 ;;
  *" get secret gatus-push "*)
    log_event "kubectl: secret read"
    printf 'Authorization: Bearer %s\n' "$(<"$FAKE_STATE/token")" ;;
  *" port-forward "*)
    [ -z "${FAKE_FORWARD_FAILS:-}" ] || { log_event "kubectl: forward failed"; echo "error: unable to listen" >&2; exit 1; }
    echo $$ >>"$FAKE_STATE/forward-pids"
    log_event "kubectl: forward started"
    echo "Forwarding from 127.0.0.1:43210 -> 8080"
    echo "Forwarding from [::1]:43210 -> 8080"
    exec "$(command -p -v sleep)" 600 ;;
  *) violate "kubectl: unexpected $*"; exit 1 ;;
esac
FAKE

# curl: one push per call, whose key, success and error it records; the header comes on stdin and must carry the token;
# FAKE_PUSH_FAILS=<n> fails the first n calls the way a refused connection does.
cat >"$fake_bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
scan_arguments_and_environment curl "$@"
url="" success="" error="" header_from_stdin=false
while [ $# -gt 0 ]; do
  case "$1" in
    --request | --max-time | --output) shift ;;
    --get | --silent | --show-error | --fail) ;;
    --header) [ "$2" = @- ] && header_from_stdin=true; shift ;;
    --data-urlencode)
      case "$2" in success=*) success="${2#success=}" ;; error=*) error="${2#error=}" ;; *) violate "curl: unexpected data" ;; esac
      shift ;;
    http://127.0.0.1:43210/api/v1/endpoints/*/external) url="$1" ;;
    *) violate "curl: unexpected argument"; exit 2 ;;
  esac
  shift
done
[ "$header_from_stdin" = true ] && [ -n "$url" ] || { violate "curl: no header on stdin or no address"; exit 2; }
header="$(cat)"
log_event "curl: push attempt"
fails=0
[ ! -e "$FAKE_STATE/push-failures" ] || fails="$(<"$FAKE_STATE/push-failures")"
if [ "$fails" -gt 0 ]; then echo $((fails - 1)) >"$FAKE_STATE/push-failures"; exit 7; fi
[ "$header" = "Authorization: Bearer $(<"$FAKE_STATE/token")" ] || { echo "curl: (22) The requested URL returned error: 401" >&2; exit 22; }
key="${url#*/endpoints/}"
echo "${key%/external} success=$success error=$error" >>"$FAKE_STATE/pushes"
FAKE

# gh: the open items of each repository are the lines of items-<app>, newest first; a search returns those whose title
# holds the searched title, the way GitHub's does, and at most 30. FAKE_GH_FAILS=list or create fails that call with 7,
# hang-list or hang-create makes it run until a signal ends it.
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_LIB"
scan_arguments_and_environment gh "$@"
action="$2"
repository="$4"
app="${repository#overnightworks/}"
log_event "gh: $action $repository"
[ "$FAKE_GH_FAILS" != "hang-$action" ] || exec "$(command -p -v sleep)" 600
[ "$FAKE_GH_FAILS" != "$action" ] || { echo "gh: keyring locked" >&2; exit 7; }
case "$action" in
  list)
    [ "$5 $6 $7" = "--state open --search" ] && [ "$9" = "--json" ] && [ "${10}" = title ] || { violate "gh: unexpected list arguments"; exit 2; }
    searched="${8#in:title \"}"
    searched="${searched%\"}"
    { grep -F -- "$searched" "$FAKE_STATE/items-$app" || true; } | head -n 30 |
      sed 's/.*/{"title": "&"}/' | paste -sd, - | sed 's/^/[/; s/$/]/' ;;
  create)
    [ "$5" = --title ] && [ "$7 $8" = "--body-file -" ] || { violate "gh: unexpected create arguments"; exit 2; }
    echo "$6" >"$FAKE_STATE/created-title-$app"
    cat >"$FAKE_STATE/body-$app"
    echo "https://example.invalid/$repository/issues/1" ;;
  *) violate "gh: unexpected $*"; exit 2 ;;
esac
FAKE

# sleep: a wait of ten seconds or more is recorded and skipped, a shorter one is real.
cat >"$fake_bin/sleep" <<'FAKE'
#!/usr/bin/env bash
if [ "${1%.*}" -ge 10 ] 2>/dev/null; then echo "$1" >>"$FAKE_STATE/sleeps"; else exec "$(command -p -v sleep)" "$@"; fi
FAKE
chmod +x "$fake_bin"/*

state="" runtime="" output_file="" status=0
prepare_case() {
  state="$work_directory/state-$1"
  runtime="$work_directory/runtime-$1"
  mkdir "$state"
  mkdir -m 700 "$runtime"
  output_file="$work_directory/output-$1"
  echo "$token" >"$state/token"
  : >"$state/log" && : >"$state/violation" && : >"$state/sleeps" && : >"$state/pushes" && : >"$state/forward-pids"
  echo false >"$state/tunnel-reads"
  echo True >"$state/keycloak-reads"
  echo 0 >"$state/push-failures"
  local app
  for app in "${apps[@]}"; do
    : >"$state/mise-$app" && : >"$state/items-$app"
  done
}
# script <app> <line>...: the attempts of live:check for the app.
script() {
  local app="$1"
  shift
  printf '%s\n' "$@" >>"$state/mise-$app"
}
# The attempts' lines, as `live:check` prints them.
green_attempt() { echo "0|live:check: $1 green (start=303 login-page=200 sign-in-form=302 callback=303 account=200 sign-out=200 account-after=401)|"; }
red_attempt() { echo "1|live:check: $1 red (start=303 login-page=500) step=${2:-login-page}|${3:-}"; }
# The names that may remain, as `live:check` prints them: the person's session at the app itself, which a failed start or
# sign-out leaves, and another name.
own_session_remains() { echo "live:check: may remain: the person's $1 session; run again to clean up"; }
other_name_remains() { echo "live:check: may remain: the person's $1 session; the person's Keycloak sessions; run again to clean up"; }
skipped_attempt() { echo "3|live:check: $1 skipped|live:check: the Deployment $1 is not Available"; }
# report_command <argument>...: the report in the cell's environment, in the launcher's session when one is set.
report_command() {
  (cd "$repository_root" && exec env PATH="$fake_bin:$PATH" XDG_RUNTIME_DIR="$runtime" TMPDIR="$work_directory" FAKE_STATE="$state" \
    FAKE_LIB="$work_directory/fake_lib.sh" FAKE_GH_FAILS="${FAKE_GH_FAILS:-}" KUBECONFIG=/nonexistent MISE_DISABLE_TOOLS=kubectl \
    "${extra_environment[@]}" "${launcher[@]}" scripts/live_check_report.sh "$@")
}
run_report() {
  shift
  status=0
  report_command "$@" >"$output_file" 2>&1 || status=$?
}
extra_environment=()
launcher=()
show_output() { sed 's/^/  /' "$output_file" >&2; }
refuse() { show_output; fail "$1"; }
sleeps_are() { [ "$(paste -sd' ' "$state/sleeps")" = "$1" ]; }
pushes_are() { [ "$(paste -sd'|' "$state/pushes")" = "$1" ]; }
mise_calls() { grep -c '^mise: live:check' "$state/log" || true; }
no_item() { ! grep -q '^gh: create' "$state/log"; }
no_gh_call() { ! grep -q '^gh: ' "$state/log"; }
# expect_status <case> <status>
expect_status() { [ "$status" = "$2" ] || refuse "$1: exit $status, not $2"; }
# kept_clean <case>: no fake saw the token anywhere but on stdin, it stands in no output or file of the run, and no
# forward outlives the run.
kept_clean() {
  local name="$1" pid
  [ ! -s "$state/violation" ] || refuse "$name: $(paste -sd';' "$state/violation")"
  ! grep -rqF -- "$token" "$output_file" "$runtime" "$state/log" "$state/pushes" "$work_directory"/state-"$name"/body-* 2>/dev/null ||
    refuse "$name: the token is in an output or a file of the run"
  while read -r pid; do
    ! kill -0 "$pid" 2>/dev/null || refuse "$name: a forward still runs"
  done <"$state/forward-pids"
}
hopin_key=live-check_hopin-sign-in

# ---------------------------------------------------------------------------------------------------- green and rerun
prepare_case green
script hopin "$(green_attempt hopin)"
run_report green sign-in hopin
expect_status green 0
pushes_are "$hopin_key success=true error=" || refuse "green: pushes read '$(paste -sd'|' "$state/pushes")'"
no_gh_call || refuse "green: gh was called"
[ "$(mise_calls)" = 1 ] && sleeps_are "" || refuse "green: more than one attempt or a wait"
kept_clean green
echo "a green pushes success=true once, with no item and no rerun"

prepare_case red-then-green
script hopin "$(red_attempt hopin)" "$(green_attempt hopin)"
run_report red-then-green sign-in hopin
expect_status red-then-green 0
pushes_are "$hopin_key success=true error=" || refuse "red-then-green: pushes read '$(paste -sd'|' "$state/pushes")'"
no_gh_call || refuse "red-then-green: gh was called"
sleeps_are 600 || refuse "red-then-green: the rerun did not wait 10 minutes"
kept_clean red-then-green
echo "a red that is green on the rerun 10 minutes later pushes true once and opens no item"

# --------------------------------------------------------------------------------------------------------- red twice
# the item's body holds only these lines, and the output never repeats them
body_lines='^(Date: [0-9]{4}-[0-9]{2}-[0-9]{2}|Result: live:check: .*|Step: .*|Cause: .*|Reproduce: mise run live:check [a-z]+)$'
for case_step in "hopin login-page platform none" "skat start app own_session_remains" "presentator callback app none" \
  "songmaker sign-out app own_session_remains" "hopin account platform other_name_remains" "hopin sign-in-form platform none" "hopin none platform none"; do
  read -r red_app red_step verdict remains <<<"$case_step"
  case_name="red-twice-$red_app-$red_step"
  prepare_case "$case_name"
  remaining_line=""
  [ "$remains" = none ] || remaining_line="$("$remains" "$red_app")"
  if [ "$red_step" = none ]; then red_line="1|live:check: $red_app red|live:check: the person could not be enabled"; else red_line="$(red_attempt "$red_app" "$red_step" "$remaining_line")"; fi
  script "$red_app" "$red_line" "$red_line"
  run_report "$case_name" sign-in "$red_app"
  expect_status "$case_name" 0
  grep -q "^live-check_$red_app-sign-in success=false error=.*start=303 login-page=500" "$state/pushes" ||
    [ "$red_step" = none ] || refuse "$case_name: the push of false holds not the codes: $(paste -sd'|' "$state/pushes")"
  [ "$(wc -l <"$state/pushes")" = 1 ] && grep -q ' success=false ' "$state/pushes" || refuse "$case_name: not one push of false"
  [ "$(<"$state/created-title-$red_app")" = "live:check $red_app red after a rerun" ] || refuse "$case_name: wrong item title"
  [ "$(grep -c '^gh: create overnightworks/' "$state/log")" = 1 ] && grep -q "^gh: create overnightworks/$red_app\$" "$state/log" ||
    refuse "$case_name: the item is not one at overnightworks/$red_app"
  while IFS= read -r line; do
    [[ "$line" =~ $body_lines ]] || refuse "$case_name: the body holds the line '$line'"
  done <"$state/body-$red_app"
  [ "$(wc -l <"$state/body-$red_app")" = 5 ] || refuse "$case_name: the body is not date, result, step, cause and command"
  grep -q "^Step: .*$red_step\|^Step: .*[Bb]efore" "$state/body-$red_app" || refuse "$case_name: the body names not the step"
  case "$verdict" in
    app) grep -q "^Cause: .*app's own" "$state/body-$red_app" && ! grep -q 'at platform' "$state/body-$red_app" || refuse "$case_name: the body does not say the step is the app's" ;;
    platform) grep -q '^Cause: .*at platform' "$state/body-$red_app" || refuse "$case_name: the body does not say the cause is at platform" ;;
  esac
  grep -q "^Reproduce: mise run live:check $red_app\$" "$state/body-$red_app" || refuse "$case_name: the body holds not the reproduce command"
  ! grep -q '^Reproduce:\|^Cause:' "$output_file" || refuse "$case_name: the output repeats the body"
  kept_clean "$case_name"
  echo "$red_app red twice at $red_step: one push of false and one item at overnightworks/$red_app, whose cause is on the side of $verdict"
done

prepare_case may-remain
script skat "1|live:check: skat red (start=303 login-page=200 sign-in-form=302 callback=303 account=200 sign-out=200 account-after=401)|live:check: may remain: the person's hopin session; run again to clean up" \
  "1|live:check: skat red (start=303 login-page=200 sign-in-form=302 callback=303 account=200 sign-out=200 account-after=401)|live:check: may remain: the person's hopin session; run again to clean up"
run_report may-remain sign-in skat
expect_status may-remain 0
grep -q "success=false error=.*may remain: the person's hopin session" "$state/pushes" || refuse "may-remain: the push holds not the names"
grep -q "^Result: .*may remain: the person's hopin session" "$state/body-skat" && grep -q '^Cause: .*at platform' "$state/body-skat" ||
  refuse "may-remain: the item holds not the names or names the app as the cause"
kept_clean may-remain
echo "a may remain reaches the push, the item and its platform cause, though every step of the sign-in passed"

prepare_case an-open-item
script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
echo "live:check hopin red after a rerun" >>"$state/items-hopin"
run_report an-open-item sign-in hopin
expect_status an-open-item 0
no_item || refuse "an-open-item: a second item was opened"
grep -q 'success=false' "$state/pushes" || refuse "an-open-item: the red was not pushed"
kept_clean an-open-item
echo "an open item of that title gets no second one, and the red is still pushed"

prepare_case suffixed-title
script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
echo "live:check hopin red after a rerun (again)" >>"$state/items-hopin"
run_report suffixed-title sign-in hopin
grep -q '^gh: create overnightworks/hopin$' "$state/log" || refuse "suffixed-title: an item whose title differs by a suffix counted as the item"
kept_clean suffixed-title
echo "an open item whose title differs only by a suffix does not count"

prepare_case item-beyond-the-newest-thirty
script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
for number in $(seq 40); do echo "unrelated item $number" >>"$state/items-hopin"; done
echo "live:check hopin red after a rerun" >>"$state/items-hopin"
run_report item-beyond-the-newest-thirty sign-in hopin
no_item || refuse "item-beyond-the-newest-thirty: an item outside the newest 30 was not found"
kept_clean item-beyond-the-newest-thirty
echo "the lookup asks by title, so an item outside the newest 30 still counts"

prepare_case four-reds
for app in "${apps[@]}"; do script "$app" "$(red_attempt "$app")" "$(red_attempt "$app")"; done
run_report four-reds sign-in
expect_status four-reds 0
[ "$(grep -c ' success=false ' "$state/pushes")" = 4 ] && [ "$(grep -c '^gh: create ' "$state/log")" = 4 ] || refuse "four-reds: not four pushes and four items"
for app in "${apps[@]}"; do
  grep -q '^Cause: .*at platform' "$state/body-$app" || refuse "four-reds: the item of $app does not say the cause is at platform"
done
kept_clean four-reds
echo "Keycloak down: four apps red after reruns give four pushes of false and four items, each at its app, each naming platform"

prepare_case every-app-green
for app in "${apps[@]}"; do script "$app" "$(green_attempt "$app")"; done
run_report every-app-green sign-in
expect_status every-app-green 0
[ "$(grep -c ' success=true ' "$state/pushes")" = 4 ] || refuse "every-app-green: not four pushes of true"
for app in "${apps[@]}"; do grep -q "^live-check_$app-sign-in " "$state/pushes" || refuse "every-app-green: no push for $app"; done
no_gh_call || refuse "every-app-green: gh was called"
kept_clean every-app-green
echo "no app argument reports every app of the table"

# Gatus' key of a row is its group and its name with the spaces made hyphens: the rows the config declares are the keys
# the report pushes, one per app of the table.
pushed_keys="$(cut -d' ' -f1 "$state/pushes" | sort)"
configured_keys="$(yq '.external-endpoints[] | .group + "_" + (.name | sub(" ", "-"))' "$repository_root/infrastructure/gatus/gatus-config.yaml" | sort)"
[ "$pushed_keys" = "$configured_keys" ] || refuse "the keys of the Gatus config ($(paste -sd' ' <<<"$configured_keys")) are not the keys the report pushes ($(paste -sd' ' <<<"$pushed_keys"))"
echo "the external endpoints of the Gatus config are the keys the report pushes for each app of the table"

# --------------------------------------------------------------------------------------------------------- skipped
prepare_case skipped-twice
script hopin "$(skipped_attempt hopin)" "$(skipped_attempt hopin)"
run_report skipped-twice sign-in hopin
expect_status skipped-twice 0
pushes_are "" && no_gh_call || refuse "skipped-twice: a push or an item"
sleeps_are 600 || refuse "skipped-twice: no rerun after 10 minutes"
kept_clean skipped-twice
echo "an app skipped twice pushes nothing and opens no item"

prepare_case skipped-then-red
script hopin "$(skipped_attempt hopin)" "$(red_attempt hopin)"
run_report skipped-then-red sign-in hopin
grep -q 'success=false' "$state/pushes" && grep -q '^gh: create' "$state/log" || refuse "skipped-then-red: the red after a skip was not reported"
kept_clean skipped-then-red
echo "a skip then a red is a red after a rerun"

# ----------------------------------------------------------------------------------------- the command's own lock
prepare_case command-lock-held
script hopin "4|live:check: hopin refused|live:check: another run holds the lock; nothing was changed" "4|live:check: hopin refused|" "$(green_attempt hopin)"
run_report command-lock-held sign-in hopin
expect_status command-lock-held 0
pushes_are "$hopin_key success=true error=" || refuse "command-lock-held: pushes read '$(paste -sd'|' "$state/pushes")'"
sleeps_are "60 60" && [ "$(mise_calls)" = 3 ] || refuse "command-lock-held: waits '$(paste -sd' ' "$state/sleeps")', calls $(mise_calls)"
no_gh_call || refuse "command-lock-held: gh was called"
kept_clean command-lock-held
echo "exit 4 of the command waits for its lock and runs again, and is never pushed red"

prepare_case command-lock-held-past-the-bound
for _ in $(seq 31); do script hopin "4|live:check: hopin refused|"; done
run_report command-lock-held-past-the-bound sign-in hopin
expect_status command-lock-held-past-the-bound 4
pushes_are "" && no_gh_call || refuse "command-lock-held-past-the-bound: a push or an item"
[ "$(wc -l <"$state/sleeps")" = 30 ] || refuse "command-lock-held-past-the-bound: not 30 minutes of waits"
grep -q 'hopin skipped reason=command-busy' "$output_file" || refuse "command-lock-held-past-the-bound: the output names not the reason"
kept_clean command-lock-held-past-the-bound
echo "a command lock held for 30 minutes leaves the app unchecked with exit 4, nothing pushed, nothing opened"

# ------------------------------------------------------------------------------------------------ the report's lock
prepare_case report-lock-bound
mkdir -m 700 "$runtime/live-check"
exec {lock_descriptor}>"$runtime/live-check/report.lock"
flock --nonblock "$lock_descriptor"
extra_environment=(LIVE_REPORT_LOCK_WAIT_SECONDS=1)
run_report report-lock-bound sign-in hopin
exec {lock_descriptor}>&-
extra_environment=()
expect_status report-lock-bound 4
grep -q 'refused: another live:report is running; nothing ran' "$output_file" || refuse "report-lock-bound: the refusal is not printed"
[ "$(mise_calls)" = 0 ] && pushes_are "" && no_gh_call || refuse "report-lock-bound: something ran"
echo "a second report past the lock's bound exits 4 with nothing run, pushed or opened"

prepare_case report-lock-waited
mkdir -m 700 "$runtime/live-check"
exec {lock_descriptor}>"$runtime/live-check/report.lock"
flock --nonblock "$lock_descriptor"
script hopin "$(green_attempt hopin)"
extra_environment=(LIVE_REPORT_LOCK_WAIT_SECONDS=60)
# The background run must not inherit the test's own hold of the lock.
{ exec {lock_descriptor}>&-; run_report report-lock-waited sign-in hopin; } &
runner_pid=$!
for _ in $(seq 100); do grep -q 'waiting' "$output_file" 2>/dev/null && break; command sleep 0.1; done
grep -q 'waiting' "$output_file" || refuse "report-lock-waited: the second report does not say it waits"
[ "$(mise_calls)" = 0 ] || refuse "report-lock-waited: the second report ran while the lock was held"
exec {lock_descriptor}>&-
wait "$runner_pid"
extra_environment=()
pushes_are "$hopin_key success=true error=" || { show_output; refuse "report-lock-waited: the second report did not run after the first ended: $(<"$state/log")"; }
echo "a second report waits for the lock and runs once it is free"

# --------------------------------------------------------------------------------------------------- offline
prepare_case offline
echo true >"$state/tunnel-reads"
run_report offline sign-in hopin
expect_status offline 0
grep -q 'hopin skipped reason=offline' "$output_file" || refuse "offline: the output names not the reason"
[ "$(mise_calls)" = 0 ] && pushes_are "" && no_gh_call || refuse "offline: something ran"
kept_clean offline
echo "an offline platform skips every app with no attempt, push or item"

prepare_case offline-before-the-rerun
printf '%s\n' false true >"$state/tunnel-reads"
script hopin "$(red_attempt hopin)"
run_report offline-before-the-rerun sign-in hopin
[ "$(mise_calls)" = 1 ] && pushes_are "" && no_gh_call || refuse "offline-before-the-rerun: something ran after the first attempt"
kept_clean offline-before-the-rerun
echo "an offline that starts after the first attempt drops the rerun"

prepare_case offline-before-the-push
printf '%s\n' false false true >"$state/tunnel-reads"
script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
run_report offline-before-the-push sign-in hopin
pushes_are "" && no_gh_call || refuse "offline-before-the-push: a push or an item"
kept_clean offline-before-the-push
echo "an offline that starts during the rerun drops the red, which it made"

prepare_case offline-before-the-item
printf '%s\n' false false false true >"$state/tunnel-reads"
script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
run_report offline-before-the-item sign-in hopin
grep -q 'success=false' "$state/pushes" && no_gh_call || refuse "offline-before-the-item: the push is missing or gh was called"
kept_clean offline-before-the-item
echo "an offline that starts after the push opens no item"

prepare_case offline-unreadable
echo unreadable >"$state/tunnel-reads"
script hopin "$(green_attempt hopin)"
run_report offline-unreadable sign-in hopin
expect_status offline-unreadable 0
grep -q 'the suspend of the tunnel cannot be read; the platform counts as online' "$output_file" || refuse "offline-unreadable: the output does not say the suspend cannot be read"
[ "$(mise_calls)" = 1 ] && pushes_are "$hopin_key success=true error=" || refuse "offline-unreadable: the attempt or its push did not run"
kept_clean offline-unreadable
echo "a suspend that cannot be read counts as online, says so and runs the attempt"

# ------------------------------------------------------------------------------------------------ failures
prepare_case push-fails
echo 99 >"$state/push-failures"
script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
run_report push-fails sign-in hopin
expect_status push-fails 1
[ "$(grep -c '^curl: push attempt' "$state/log")" = 3 ] || refuse "push-fails: not three tries"
sleeps_are "600 60 60" || refuse "push-fails: the tries are not spread over two minutes: '$(paste -sd' ' "$state/sleeps")'"
grep -q '^gh: create' "$state/log" || refuse "push-fails: the item depends on the push"
kept_clean push-fails
echo "a push that fails three times over two minutes still opens the item and fails the run"

prepare_case push-fails-once
echo 1 >"$state/push-failures"
script hopin "$(green_attempt hopin)"
run_report push-fails-once sign-in hopin
expect_status push-fails-once 0
pushes_are "$hopin_key success=true error=" || refuse "push-fails-once: the retry did not push"
kept_clean push-fails-once
echo "a push that fails once is retried"

prepare_case forward-fails
script hopin "$(green_attempt hopin)"
extra_environment=(FAKE_FORWARD_FAILS=1)
run_report forward-fails sign-in hopin
extra_environment=()
expect_status forward-fails 1
pushes_are "" || refuse "forward-fails: a push without a forward"
kept_clean forward-fails
echo "a forward that never listens fails the push and the run"

for failing_call in list create; do
  prepare_case "gh-$failing_call-fails"
  script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
  FAKE_GH_FAILS="$failing_call" run_report "gh-$failing_call-fails" sign-in hopin
  expect_status "gh-$failing_call-fails" 1
  grep -q 'success=false' "$state/pushes" || refuse "gh-$failing_call-fails: the red push is gone"
  grep -q 'hopin item failed (gh exit 7)' "$output_file" || refuse "gh-$failing_call-fails: the output names not the failure"
  ! grep -q '^gh: create' "$state/log" || [ "$failing_call" = create ] || refuse "gh-$failing_call-fails: a create followed a failed lookup"
  ! grep -qE '^(Date|Cause|Reproduce|Step):' "$output_file" || refuse "gh-$failing_call-fails: the output holds the body"
  kept_clean "gh-$failing_call-fails"
  echo "a gh that fails on $failing_call leaves the red push, opens nothing, prints no body and fails the run"
done

# ----------------------------------------------------------------------------------------------------------- nightly
keycloak_reads() { grep -c '^kubectl: keycloak read' "$state/log" || true; }
skipped_offline_lines() { grep -c ' skipped reason=offline' "$output_file" || true; }

prepare_case sign-in-does-not-wait
echo False >"$state/keycloak-reads"
script hopin "$(green_attempt hopin)"
run_report sign-in-does-not-wait sign-in hopin
expect_status sign-in-does-not-wait 0
[ "$(keycloak_reads)" = 0 ] && sleeps_are "" || refuse "sign-in-does-not-wait: sign-in read or waited for Keycloak"
kept_clean sign-in-does-not-wait
echo "sign-in does not wait for Keycloak"

prepare_case nightly-keycloak-available
for app in "${apps[@]}"; do script "$app" "$(green_attempt "$app")"; done
run_report nightly-keycloak-available nightly
expect_status nightly-keycloak-available 0
[ "$(grep -c ' success=true ' "$state/pushes")" = 4 ] && no_gh_call && sleeps_are "" || refuse "nightly-keycloak-available: not four pushes of true with no wait"
for app in "${apps[@]}"; do grep -q "^live-check_$app-sign-in " "$state/pushes" || refuse "nightly-keycloak-available: no push for $app"; done
[ "$(keycloak_reads)" = 1 ] || refuse "nightly-keycloak-available: Keycloak was read $(keycloak_reads) times"
kept_clean nightly-keycloak-available
echo "nightly runs the sign-in for every app and pushes as sign-in does, with no wait when Keycloak is Available"

prepare_case nightly-waits-for-keycloak
printf '%s\n' False False True >"$state/keycloak-reads"
for app in "${apps[@]}"; do script "$app" "$(green_attempt "$app")"; done
run_report nightly-waits-for-keycloak nightly
expect_status nightly-waits-for-keycloak 0
sleeps_are "30 30" || refuse "nightly-waits-for-keycloak: waits '$(paste -sd' ' "$state/sleeps")'"
[ "$(grep -n -m1 '^mise:' "$state/log" | cut -d: -f1)" -gt "$(grep -n '^kubectl: keycloak read' "$state/log" | tail -n 1 | cut -d: -f1)" ] ||
  refuse "nightly-waits-for-keycloak: an attempt ran before Keycloak was Available"
[ "$(grep -c ' success=true ' "$state/pushes")" = 4 ] || refuse "nightly-waits-for-keycloak: not four pushes of true"
kept_clean nightly-waits-for-keycloak
echo "nightly polls every 30 seconds for Keycloak and runs every app once it is Available"

prepare_case nightly-keycloak-never-available
echo False >"$state/keycloak-reads"
for app in "${apps[@]}"; do script "$app" "$(green_attempt "$app")"; done
extra_environment=(LIVE_REPORT_KEYCLOAK_WAIT_SECONDS=90)
run_report nightly-keycloak-never-available nightly
extra_environment=()
expect_status nightly-keycloak-never-available 0
sleeps_are "30 30 30" || refuse "nightly-keycloak-never-available: waits '$(paste -sd' ' "$state/sleeps")'"
[ "$(mise_calls)" = 4 ] && [ "$(grep -c ' success=true ' "$state/pushes")" = 4 ] || refuse "nightly-keycloak-never-available: the apps did not run at the bound"
kept_clean nightly-keycloak-never-available
echo "nightly runs every app anyway once the wait's bound passes"

prepare_case nightly-keycloak-unreadable
printf '%s\n' unreadable unreadable True >"$state/keycloak-reads"
for app in "${apps[@]}"; do script "$app" "$(green_attempt "$app")"; done
run_report nightly-keycloak-unreadable nightly
expect_status nightly-keycloak-unreadable 0
sleeps_are "30 30" && [ "$(mise_calls)" = 4 ] || refuse "nightly-keycloak-unreadable: a failed read did not count as not Available"
kept_clean nightly-keycloak-unreadable
echo "a Keycloak read that fails counts as not Available"

prepare_case nightly-offline
echo true >"$state/tunnel-reads"
echo False >"$state/keycloak-reads"
run_report nightly-offline nightly
expect_status nightly-offline 0
[ "$(skipped_offline_lines)" = 4 ] || refuse "nightly-offline: not every app skipped for the platform being offline"
[ "$(keycloak_reads)" = 0 ] && sleeps_are "" && [ "$(mise_calls)" = 0 ] && pushes_are "" && no_gh_call || refuse "nightly-offline: something read, waited, ran or pushed"
kept_clean nightly-offline
echo "nightly while offline skips every app with no wait, attempt, push or item"

prepare_case nightly-offline-during-the-wait
printf '%s\n' false true >"$state/tunnel-reads"
echo False >"$state/keycloak-reads"
run_report nightly-offline-during-the-wait nightly
expect_status nightly-offline-during-the-wait 0
[ "$(skipped_offline_lines)" = 4 ] && sleeps_are "30" || refuse "nightly-offline-during-the-wait: the wait did not end when the platform went offline"
[ "$(mise_calls)" = 0 ] && pushes_are "" && no_gh_call || refuse "nightly-offline-during-the-wait: something ran, pushed or opened"
kept_clean nightly-offline-during-the-wait
echo "an offline that starts during the wait ends it and skips every app"

prepare_case nightly-reports-a-red
script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
for app in skat presentator songmaker; do script "$app" "$(green_attempt "$app")"; done
run_report nightly-reports-a-red nightly
expect_status nightly-reports-a-red 0
[ "$(grep -c ' success=false ' "$state/pushes")" = 1 ] && [ "$(grep -c ' success=true ' "$state/pushes")" = 3 ] || refuse "nightly-reports-a-red: not one push of false and three of true"
grep -q '^gh: create overnightworks/hopin$' "$state/log" && [ "$(grep -c '^gh: create ' "$state/log")" = 1 ] || refuse "nightly-reports-a-red: not one item, at hopin"
sleeps_are 600 || refuse "nightly-reports-a-red: the rerun did not wait 10 minutes"
kept_clean nightly-reports-a-red
echo "a red after its rerun in nightly gets its push and its item, beside the green apps' pushes"

prepare_case nightly-report-lock
mkdir -m 700 "$runtime/live-check"
exec {lock_descriptor}>"$runtime/live-check/report.lock"
flock --nonblock "$lock_descriptor"
extra_environment=(LIVE_REPORT_LOCK_WAIT_SECONDS=1)
run_report nightly-report-lock nightly
exec {lock_descriptor}>&-
extra_environment=()
expect_status nightly-report-lock 4
[ "$(mise_calls)" = 0 ] && pushes_are "" && no_gh_call || refuse "nightly-report-lock: something ran while another report held the lock"
echo "nightly takes the report's lock and exits 4 when another report holds it past the bound"

# systemd's stop sends TERM to every process of the unit's group: the fake run of attempt 2 hangs until it comes.
prepare_case term-during-the-rerun
script hopin "$(red_attempt hopin)" "hang||"
# The launcher names its pid, which is the report's process group once it has called setsid.
launcher=(bash -c 'echo $$ >"$FAKE_STATE/runner-pid" && exec setsid "$@"' _)
report_command nightly >"$output_file" 2>&1 &
background_pid=$!
launcher=()
for _ in $(seq 100); do grep -q '^mise: hanging' "$state/log" 2>/dev/null && break; command sleep 0.1; done
runner_pid="$(<"$state/runner-pid")"
grep -q '^mise: hanging' "$state/log" || { kill -TERM -- "-$runner_pid" 2>/dev/null || true; refuse "term-during-the-rerun: attempt 2 never started"; }
kill -TERM -- "-$runner_pid"
status=0
wait "$background_pid" || status=$?
expect_status term-during-the-rerun 143
pushes_are "" && no_gh_call || refuse "term-during-the-rerun: a push or an item followed the TERM"
! kill -0 "$(<"$state/hang-pid")" 2>/dev/null || refuse "term-during-the-rerun: the attempt still runs"
kept_clean term-during-the-rerun
echo "a TERM to the whole group during attempt 2 ends the report with 143, with no push of false, no item and no forward left"

# A call that hangs is cut after 20 seconds, so one stuck read cannot hold a night until the cap.
prepare_case gh-hangs
script hopin "$(red_attempt hopin)" "$(red_attempt hopin)"
FAKE_GH_FAILS=hang-list run_report gh-hangs sign-in hopin
expect_status gh-hangs 1
grep -q 'hopin item failed (gh exit 124)' "$output_file" || refuse "gh-hangs: the hung lookup was not cut after its bound"
grep -q 'success=false' "$state/pushes" || refuse "gh-hangs: the red push is gone"
kept_clean gh-hangs
echo "a gh call that hangs is cut by its bound and fails the item, not the night"

prepare_case service-read-hangs
script hopin "$(green_attempt hopin)"
extra_environment=(LIVE_REPORT_READ_TIMEOUT_SECONDS=1 FAKE_SERVICE_HANGS=1)
run_report service-read-hangs sign-in hopin
extra_environment=()
expect_status service-read-hangs 1
[ "$(grep -c '^kubectl: service read hangs' "$state/log")" = 3 ] || refuse "service-read-hangs: not three cut reads, one per try"
grep -q 'hopin push failed' "$output_file" || refuse "service-read-hangs: the failed push is not named"
pushes_are "" && no_item && ! grep -q '^kubectl: forward started' "$state/log" || refuse "service-read-hangs: a push, an item or a forward followed the hung read"
kept_clean service-read-hangs
echo "a read of the Service port that hangs is cut by its bound and fails the push after its tries, with no false red"

# ------------------------------------------------------------------------------------------------------- usage
for usage_arguments in "" "journeys" "sign-in nosuchapp" "nightly hopin"; do
  prepare_case "usage-${usage_arguments// /-}"
  # shellcheck disable=SC2086 # the words are the arguments
  run_report "usage-${usage_arguments// /-}" $usage_arguments
  expect_status "usage-${usage_arguments// /-}" 1
  [ "$(sed -n 1p "$output_file")" = 'usage: mise run live:report sign-in [<app>] | nightly' ] || refuse "usage-$usage_arguments: not the plain usage"
  [ ! -s "$state/log" ] || refuse "usage-$usage_arguments: a call was made"
done
echo "a missing or unknown check, an unknown app and an app after nightly print the usage with no call"
