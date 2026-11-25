#!/usr/bin/env bash
# The command behind `mise run live:report sign-in [<app>]` and `mise run live:report nightly`: runs `live:check` for each
# app (or the one named; `nightly`, which the timer starts, takes none and first waits up to 20 minutes for the Deployment
# keycloak to be Available), runs it once more after 10 minutes when it was red or skipped, pushes the final green or red
# to the app's Gatus row, and opens one item at the app's repository for a red after the rerun. Exit 0 is done, 1 a failed
# push or item, 4 another report holds the lock for the whole bound, or the command's lock was held for 30 minutes for an
# app; nothing is pushed red for a lock. While the platform is offline (the Kustomization tunnel is suspended) nothing is
# run, pushed or opened. A TERM ends the report with 143, with no push, item or forward left for the apps not finished.
# Output is the apps' result lines and one line per push and item, never the Gatus token or an item's body.
#
# The token reaches curl on stdin only, from the Secret gatus-push through a loopback forward to the Service gatus.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
export LC_ALL=C
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# shellcheck source=live_check_apps.sh
source "$(dirname "${BASH_SOURCE[0]}")/live_check_apps.sh"
# shellcheck source=loopback_forward.sh
source "$(dirname "${BASH_SOURCE[0]}")/loopback_forward.sh"

lock_wait_seconds="${LIVE_REPORT_LOCK_WAIT_SECONDS:-3600}"
# Every kubectl and gh call, except the forward which loopback_forward.sh bounds, ends within read_timeout_seconds, so
# none holds a night; loopback_forward.sh sets its default.
read_timeout_seconds="${LIVE_REPORT_READ_TIMEOUT_SECONDS:-$read_timeout_seconds}"
# nightly waits for Keycloak before the lock, since the read is harmless to a report that holds it.
keycloak_poll_seconds=30
keycloak_wait_seconds="${LIVE_REPORT_KEYCLOAK_WAIT_SECONDS:-1200}"
rerun_delay_seconds=600
# The command's lock is held by a run of another head or of the timer: poll for it, 30 minutes at most per app.
command_lock_poll_seconds=60
command_lock_wait_limit_seconds=1800
push_tries=3
push_retry_seconds=60

check="${1:-}"
wanted_app="${2:-}"
if { [ "$check" != sign-in ] && [ "$check" != nightly ]; } || { [ -n "$wanted_app" ] && { [ "$check" = nightly ] || [ -z "$(app_row "$wanted_app")" ]; }; }; then
  echo "usage: mise run live:report sign-in [<app>] | nightly" >&2
  echo "apps: $(app_names | paste -sd ' ' -)" >&2
  exit 1
fi
[ -n "${XDG_RUNTIME_DIR:-}" ] || { echo "live:report: XDG_RUNTIME_DIR is unset, so the report has no private directory for its lock" >&2; exit 1; }

scratch="$(mktemp -d)"
finish() {
  stop_forward
  rm -rf "$scratch"
}
trap finish EXIT
trap 'exit 143' TERM INT

platform_is_offline() {
  local suspended
  suspended="$(timeout --foreground "$read_timeout_seconds" kubectl --namespace flux-system get kustomization tunnel --output jsonpath='{.spec.suspend}' 2>/dev/null)" || {
    echo "live:report: the suspend of the tunnel cannot be read; the platform counts as online" >&2
    return 1
  }
  [ "$suspended" = true ]
}

# keycloak_is_available: the Deployment keycloak/keycloak's Available condition; a read that fails counts as not Available.
keycloak_is_available() {
  local available
  available="$(timeout --foreground "$read_timeout_seconds" kubectl --namespace keycloak get deployment keycloak \
    --output jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" || return 1
  [ "$available" = True ]
}
# wait_for_keycloak: polls until Keycloak is Available, the platform goes offline or the bound passes, which the apps' own
# attempts and rerun then face; a PC that catches up a missed night finds k3s still starting.
wait_for_keycloak() {
  local waited=0
  while ! platform_is_offline; do
    keycloak_is_available && return 0
    [ "$waited" -lt "$keycloak_wait_seconds" ] || return 0
    sleep "$keycloak_poll_seconds"
    waited=$((waited + keycloak_poll_seconds))
  done
}
[ "$check" != nightly ] || wait_for_keycloak

# One report at a time, and the command's own lock stays its own.
lock_directory="$XDG_RUNTIME_DIR/live-check"
[ -d "$lock_directory" ] || mkdir -m 700 -- "$lock_directory"
exec {lock_descriptor}>"$lock_directory/report.lock"
if ! flock --nonblock "$lock_descriptor"; then
  echo "live:report: another live:report is running; waiting up to $lock_wait_seconds seconds for it"
  flock --wait "$lock_wait_seconds" "$lock_descriptor" || {
    echo "live:report: refused: another live:report is running; nothing ran" >&2
    exit 4
  }
fi

# ------------------------------------------------------------------------------------------------------ the push
gatus_token_header() {
  timeout --foreground "$read_timeout_seconds" kubectl --namespace gatus get secret gatus-push --output go-template='Authorization: Bearer {{ .data.token | base64decode }}{{ "\n" }}'
}
# push_once <app> <true|false> <error>: one push through a fresh forward.
push_once() {
  local key="live-check_$1-sign-in" push_status=0 port
  port="$(service_port gatus)" || return 1
  start_forward gatus gatus "$port" "$scratch/forward.log" || return 1
  gatus_token_header | curl --request POST --get --silent --show-error --fail --max-time 20 --output /dev/null --header @- \
    --data-urlencode "success=$2" --data-urlencode "error=$3" \
    "http://127.0.0.1:$forward_port/api/v1/endpoints/$key/external" || push_status=$?
  stop_forward
  return "$push_status"
}
# push_result <app> <true|false> <error>: three tries over two minutes; returns 1 when none went through.
push_result() {
  local try
  if platform_is_offline; then
    echo "live:report: $1 skipped reason=offline"
    return 0
  fi
  for try in $(seq "$push_tries"); do
    if push_once "$@"; then
      echo "live:report: $1 pushed success=$2"
      return 0
    fi
    [ "$try" = "$push_tries" ] || sleep "$push_retry_seconds"
  done
  echo "live:report: $1 push failed" >&2
  return 1
}

# --------------------------------------------------------------------------------------------------------- the item
# item_body <app>: the date, the result line, the step, whose side the cause is on and the command to reproduce. A name
# that may remain makes the cause platform's, except the person's session at the app itself, which a failed start or
# sign-out leaves by its own nature.
item_body() {
  local app="$1" step="before the sign-in started" cause="the cause sits at platform; the app's head forwards it with one hop" others
  others="${may_remain#may remain: }"
  others="${others%run again to clean up}"
  others="${others//the person\'s $app session; /}"
  if [[ "$result_line" =~ \ step=([a-z-]+)$ ]]; then
    step="${BASH_REMATCH[1]}"
    case "$step" in
      start | callback | account | sign-out) [ -n "$others" ] || cause="the step is the app's own" ;;
    esac
  fi
  echo "Date: $(date -u +%F)"
  echo "Result: ${result_line:-live:check: $app ended with exit $check_status and no result line}${may_remain:+; $may_remain}"
  echo "Step: $step"
  echo "Cause: $cause"
  echo "Reproduce: mise run live:check $app"
}
# open_item <app>: one item at the app's repository unless one of the title is open; returns 1 when gh fails.
open_item() {
  local app="$1" title="live:check $1 red after a rerun" titles gh_status=0 url
  if platform_is_offline; then
    echo "live:report: $app skipped reason=offline"
    return 0
  fi
  titles="$(timeout --foreground "$read_timeout_seconds" gh issue list --repo "overnightworks/$app" --state open --search "in:title \"$title\"" --json title)" || {
    echo "live:report: $app item failed (gh exit $?)" >&2
    return 1
  }
  if yq -p json -r '.[].title' <<<"$titles" | grep -qxF -- "$title"; then
    echo "live:report: $app item exists"
    return 0
  fi
  url="$(item_body "$app" | timeout --foreground "$read_timeout_seconds" gh issue create --repo "overnightworks/$app" --title "$title" --body-file -)" || gh_status=$?
  if [ "$gh_status" != 0 ]; then
    echo "live:report: $app item failed (gh exit $gh_status)" >&2
    return 1
  fi
  echo "live:report: $app item opened $url"
}

# -------------------------------------------------------------------------------------------------------- the apps
# run_check <app>: sets check_status, result_line and may_remain from one `live:check`.
run_check() {
  local output
  check_status=0
  output="$(mise run live:check "$1" 2>&1)" || check_status=$?
  result_line="$(grep -E "^live:check: $1 (green|red|skipped|refused)( |\$)" <<<"$output" | tail -n 1 || true)"
  may_remain="$(grep -E '^live:check: may remain: ' <<<"$output" | tail -n 1 | sed 's/^live:check: //' || true)"
  echo "live:report: ${result_line:-$1 ended with exit $check_status and no result line}"
}
# report_red <app>: the push of false, whose error holds the codes and the names that may remain, then the item.
report_red() {
  local error="${result_line#"live:check: $1 red"}"
  error="${error# }"
  [ -z "$may_remain" ] || error="${error:+$error; }$may_remain"
  push_result "$1" false "${error:-exit $check_status}" || failed=true
  open_item "$1" || failed=true
}
# report_app <app>: sets failed or command_busy when it could not do all its steps.
report_app() {
  local app="$1" attempt=1 command_lock_waited=0 outcome
  while :; do
    if platform_is_offline; then
      echo "live:report: $app skipped reason=offline"
      return 0
    fi
    run_check "$app"
    case "$check_status" in
      4)
        if [ "$command_lock_waited" -ge "$command_lock_wait_limit_seconds" ]; then
          echo "live:report: $app skipped reason=command-busy" >&2
          command_busy=true
          return 0
        fi
        sleep "$command_lock_poll_seconds"
        command_lock_waited=$((command_lock_waited + command_lock_poll_seconds))
        continue ;;
      0) outcome=green ;;
      3) outcome=skipped ;;
      *) outcome=red ;;
    esac
    { [ "$outcome" = green ] || [ "$attempt" = 2 ]; } && break
    echo "live:report: $app rerun in $rerun_delay_seconds seconds"
    sleep "$rerun_delay_seconds"
    attempt=2
  done
  case "$outcome" in
    green) push_result "$app" true "" || failed=true ;;
    red) report_red "$app" ;;
  esac
}

failed=false
command_busy=false
for app in $(app_names); do
  [ -z "$wanted_app" ] || [ "$app" = "$wanted_app" ] || continue
  report_app "$app"
done
[ "$failed" = false ] || exit 1
[ "$command_busy" = false ] || exit 4
