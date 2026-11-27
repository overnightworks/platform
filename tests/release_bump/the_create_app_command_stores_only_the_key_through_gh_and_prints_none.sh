#!/usr/bin/env bash
# Drive `mise run release:create-app <name>` against fakes for gh, curl and the browser: the command checks the
# environment release-bump and the name before it serves anything, serves the manifest on 127.0.0.1, takes only the
# redirect that carries its state, hands the answer's key to `gh secret set` on stdin and nothing else anywhere, and after
# every failure that may have left the App behind names it for deletion. The code GitHub returns, the key, client_secret
# and webhook_secret appear in no argument, output, environment of a child or file of any scenario.
# Usage: mise exec -- tests/release_bump/the_create_app_command_stores_only_the_key_through_gh_and_prints_none.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/world.sh"

export MISE_DISABLE_TOOLS=kubectl,gh KUBECONFIG=/nonexistent
# mise keeps its tools and state under the caller's home, which each run replaces with an empty one.
export MISE_DATA_DIR="${MISE_DATA_DIR:-${HOME}/.local/share/mise}" MISE_CACHE_DIR="${MISE_CACHE_DIR:-${HOME}/.cache/mise}"
export MISE_STATE_DIR="${MISE_STATE_DIR:-${HOME}/.local/state/mise}" MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-${HOME}/.config/mise}"
listener="${repository_root}/scripts/release_bump_create_app_listener.py"

app_name=release-fixture-app
installation_page="https://github.com/apps/${app_name}/installations/new"
settings_page="https://github.com/organizations/overnightworks/settings/apps/${app_name}"
random_value() { printf '%s-%s' "$1" "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
code="$(random_value code)"
key_token="$(random_value key)"
client_secret="$(random_value client-secret)"
webhook_secret="$(random_value webhook-secret)"
pem="-----BEGIN RSA PRIVATE KEY-----"$'\n'"${key_token}"$'\n'"-----END RSA PRIVATE KEY-----"
pem_digest="$(printf '%s' "${pem}" | sha256sum | cut -d' ' -f1)"

# The fakes carry their record paths and their answers' directory in their text, so they read no variable of the caller's.
# gh answers the environment's reads and the one secret set from the run's fixture files; curl answers the conversion
# whose code its stdin configuration names, and on failure writes that code to stderr, where a listener that passed curl's
# stderr on would show it; xdg-open records the page and, for the local page, plays the browser: the script of
# $work/browser.py runs to its end before xdg-open returns.
cat >"${work}/browser.py" <<'BROWSER'
import html.parser
import http.client
import json
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

page_url, run, fixture = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
code = (fixture / "code").read_text()


class Form(html.parser.HTMLParser):
    action = manifest = None

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "form":
            self.action = attributes["action"]
        if tag == "input" and attributes.get("name") == "manifest":
            self.manifest = attributes["value"]


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, ""
    except (OSError, http.client.HTTPException):
        return "not served", ""


form = Form()
form.feed(get(page_url)[1])
(run / "manifest.json").write_text(form.manifest)
redirect_url = json.loads(form.manifest)["redirect_url"]
(fixture / "form-action").write_text(form.action)
state = urllib.parse.parse_qs(urllib.parse.urlparse(form.action).query)["state"][0]
# The redirect goes where the manifest sent it, as GitHub does: a request with another state, with a non-ASCII state and with none.
other_requests = [f"state={urllib.parse.quote(state[::-1])}", f"state={urllib.parse.quote('é')}", ""]
(run / "wrong-state-status").write_text("\n".join(str(get(f"{redirect_url}?code={code}&{other}")[0]) for other in other_requests) + "\n")
(run / "redirect-status").write_text(str(get(f"{redirect_url}?code={code}&state={state}")[0]))
(run / "second-redirect-status").write_text(str(get(f"{redirect_url}?code={code}&state={state}")[0]))
BROWSER

make_fakes() { # <run directory> <fixture directory>
  local run="$1" fixture="$2"
  mkdir -p "${run}/bin"
  cat >"${run}/bin/gh" <<'FAKE'
#!/usr/bin/env bash
run=@RUN@
fixture=@FIXTURE@
echo "gh $*" >>"${run}/gh-calls"
{ echo "--- gh"; env; } >>"${run}/env-records"
answer() { [ -f "${fixture}/$1" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "${fixture}/$1"; }
case "$*" in
  "api repos/overnightworks/platform/environments/release-bump") answer environment ;;
  "api repos/overnightworks/platform/environments/release-bump/deployment-branch-policies") answer policies ;;
  "api repos/overnightworks/platform/environments/release-bump/secrets/public-key") answer public-key ;;
  "secret set RELEASE_BUMP_APP_PRIVATE_KEY --env release-bump --repo overnightworks/platform")
    [ ! -f "${fixture}/secret-set-fails" ] || { echo "gh: HTTP 403" >&2; exit 1; }
    sha256sum | cut -d' ' -f1 >"${run}/stored-digest"
    ;;
  *) echo "the fake gh has no answer for: $*" >&2; exit 97 ;;
esac
FAKE
  cat >"${run}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
run=@RUN@
fixture=@FIXTURE@
echo "curl $*" >>"${run}/curl-calls"
{ echo "--- curl"; env; } >>"${run}/env-records"
[ "$*" = "-q --config -" ] || { echo "the fake curl has no answer for: $*" >&2; exit 97; }
sent="$(sed -n 's|^url = "https://api.github.com/app-manifests/\([^/"]*\)/conversions"$|\1|p')"
fail_with_the_code() { echo "curl: (22) the conversion of ${sent} failed" >&2; exit 22; }
[ ! -f "${fixture}/curl-fails" ] || fail_with_the_code
[ "${sent}" = "$(cat "${fixture}/code")" ] || fail_with_the_code
cat "${fixture}/conversion"
FAKE
  cat >"${run}/bin/xdg-open" <<'FAKE'
#!/usr/bin/env bash
run=@RUN@
fixture=@FIXTURE@
echo "$1" >>"${run}/opened"
case "$1" in
  http://127.0.0.1:*/) python3 -I @BROWSER@ "$1" "${run}" "${fixture}" ;;
esac
FAKE
  sed -i "s|@RUN@|${run}|g; s|@FIXTURE@|${fixture}|g; s|@BROWSER@|${work}/browser.py|g" "${run}/bin/gh" "${run}/bin/curl" "${run}/bin/xdg-open"
  chmod +x "${run}/bin/gh" "${run}/bin/curl" "${run}/bin/xdg-open"
}

# new_run <id>: the run's directories and fakes, and the fixtures of a good run; a scenario overwrites what it breaks.
new_run() {
  run="${work}/runs/$1"
  fixture="${work}/fixtures/$1"
  mkdir -p "${run}/home" "${run}/tmp" "${fixture}"
  : >"${run}/gh-calls" && : >"${run}/curl-calls" && : >"${run}/opened" && : >"${run}/env-records"
  make_fakes "${run}" "${fixture}"
  printf '%s' "${code}" >"${fixture}/code"
  printf '%s' '{"name":"release-bump","can_admins_bypass":true,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' >"${fixture}/environment"
  printf '%s' '{"total_count":1,"branch_policies":[{"id":1,"name":"main","type":"branch"}]}' >"${fixture}/policies"
  printf '%s' '{"key_id":"1","key":"AAAA"}' >"${fixture}/public-key"
  conversion '.' >"${fixture}/conversion"
}

# conversion <yq expression>: the answer of a good conversion, changed by the expression.
conversion() {
  PEM="${pem}" CLIENT_SECRET="${client_secret}" WEBHOOK_SECRET="${webhook_secret}" SLUG="${app_name}" yq -n -o=json \
    '{"id": 4242, "slug": strenv(SLUG), "owner": {"login": "overnightworks"}, "client_id": "Iv1.fixture", "client_secret": strenv(CLIENT_SECRET), "webhook_secret": strenv(WEBHOOK_SECRET), "pem": strenv(PEM), "permissions": {"contents": "write", "pull_requests": "write", "metadata": "read"}, "events": []}' |
    yq -o=json "$1"
}

# in_world <command>...: the command with a home inside the run, the fakes first on PATH and a caller's environment that
# holds a login, a debug switch and a proxy a child must never see.
in_world() {
  env HOME="${run}/home" TMPDIR="${run}/tmp" PATH="${run}/bin:${PATH}" GH_TOKEN=caller-login GH_DEBUG=api \
    CURL_CA_BUNDLE=/nonexistent HTTPS_PROXY=http://127.0.0.1:9 "$@"
}

# drive <name>: the command in the checkout, its output and status kept in the run. A listener that waits for a redirect
# that never arrives ends at the cap, so the scenario fails instead of waiting for the listener's own deadline.
drive() {
  status=0
  (cd "${checkout}" && in_world timeout 120 mise run release:create-app "$@") >"${run}/out" 2>"${run}/err" || status=$?
}

# leaks <value>: the run, the gh login directory and the checkout hold the value anywhere.
leaks() { grep -rqF -- "$1" "${run}" "${work}/gh-config" "${checkout}"; }
no_leak() {
  local label value
  for label in code key client_secret webhook_secret; do
    case "${label}" in
      code) value="${code}" ;;
      key) value="${key_token}" ;;
      client_secret) value="${client_secret}" ;;
      webhook_secret) value="${webhook_secret}" ;;
    esac
    ! leaks "${value}" || fail "${scenario}: the ${label} reached an argument, an output, an environment or a file"
  done
  ! grep -qE '^(GH_TOKEN|GH_DEBUG|CURL_CA_BUNDLE|HTTPS_PROXY|FAKE_[A-Z_]*)=' "${run}/env-records" ||
    fail "${scenario}: a child of the command inherited a variable of the caller"
}

secret_sets() { calls "${run}/gh-calls" '^gh secret set'; }
stored() { [ -f "${run}/stored-digest" ]; }

# The scan sees a value planted in a file of a run.
scenario="the scan's control"
new_run control
printf '%s' "${key_token}" >"${run}/planted"
leaks "${key_token}" || fail "the scan did not see a planted key"
rm "${run}/planted"
echo "the no-leak scan sees a planted value"

# The good run: twice, since a repeated command stores the key again.
for scenario in stores-the-key stores-the-key-again; do
  new_run "${scenario}"
  drive "${app_name}"
  [ "${status}" -eq 0 ] || fail "${scenario}: exit ${status}: $(cat "${run}/err")"
  [ "$(secret_sets)" -eq 1 ] || fail "${scenario}: gh secret set ran $(secret_sets) times"
  grep -qxF "gh secret set RELEASE_BUMP_APP_PRIVATE_KEY --env release-bump --repo overnightworks/platform" "${run}/gh-calls" ||
    fail "${scenario}: the key went to another secret, environment or repository"
  [ "$(cat "${run}/stored-digest")" = "${pem_digest}" ] || fail "${scenario}: gh secret set's stdin was not exactly the key"
  [ "$(calls "${run}/curl-calls" .)" -eq 1 ] || fail "${scenario}: curl ran $(calls "${run}/curl-calls" .) times"
  [ "$(cat "${run}/wrong-state-status")" = $'400\n400\n400' ] || fail "${scenario}: a redirect with another or no state was not refused"
  [ "$(cat "${run}/redirect-status")" = 200 ] || fail "${scenario}: the matching redirect got $(cat "${run}/redirect-status")"
  [ "$(cat "${run}/second-redirect-status")" != 200 ] || fail "${scenario}: a second matching redirect was served"
  grep -qxF "${installation_page}" "${run}/opened" || fail "${scenario}: the installation page of the answer's slug was not opened"
  grep -qF "${app_name}" "${run}/out" && grep -qF "${installation_page}" "${run}/out" || fail "${scenario}: the output names no slug and link"
  ! grep -qF 'delete it and rerun' "${run}/err" || fail "${scenario}: a stored key was reported as a failure"
  # The manifest the page posts to GitHub.
  manifest_value() { yq -o=yaml "$1" "${run}/manifest.json"; }
  [ "$(manifest_value '.default_permissions | to_entries | map(.key + "=" + .value) | sort | join(",")')" = "contents=write,metadata=read,pull_requests=write" ] ||
    fail "${scenario}: the manifest asks for other rights than contents and pull requests write and metadata read"
  [ "$(manifest_value '.default_events | length')" -eq 0 ] || fail "${scenario}: the manifest subscribes to events"
  [ "$(manifest_value 'has("hook_attributes")')" = false ] || fail "${scenario}: the manifest holds a webhook"
  [ "$(manifest_value '.public')" = false ] || fail "${scenario}: the App is public"
  [ "$(manifest_value '.name')" = "${app_name}" ] || fail "${scenario}: the manifest names another App"
  grep -qE '^http://127\.0\.0\.1:[0-9]+/created$' <<<"$(manifest_value '.redirect_url')" || fail "${scenario}: the redirect is not on 127.0.0.1"
  grep -qE '^https://github\.com/organizations/overnightworks/settings/apps/new\?state=[A-Za-z0-9_-]{32,}$' "${fixture}/form-action" ||
    fail "${scenario}: the page does not post to the organisation's App form with a state"
  no_leak
  echo "${scenario}: the command stores exactly the key on release-bump of platform, serves only the matching redirect and leaks nothing"
done

# Refused before anything is served: the page is never opened, GitHub is asked nothing and the failure is no recovery.
refused() {
  [ "${status}" -ne 0 ] || fail "${scenario}: the command did not refuse"
  [ ! -s "${run}/opened" ] || fail "${scenario}: the page was opened"
  [ "$(calls "${run}/curl-calls" .)" -eq 0 ] && [ "$(secret_sets)" -eq 0 ] || fail "${scenario}: the command converted a code or stored a key"
  ! grep -qF 'delete it and rerun' "${run}/err" || fail "${scenario}: a refusal named an App to delete"
  no_leak
  echo "${scenario}: refused before the page opens"
}
declare -A environment_refusals=(
  [no-environment]="environment|-"
  [no-restriction-mode]='environment|{"name":"release-bump","deployment_branch_policy":null}'
  [protected-branches-mode]='environment|{"name":"release-bump","deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}'
  [no-policy]='policies|{"total_count":0,"branch_policies":[]}'
  [second-policy]='policies|{"total_count":2,"branch_policies":[{"id":1,"name":"main","type":"branch"},{"id":2,"name":"develop","type":"branch"}]}'
  [policy-for-another-branch]='policies|{"total_count":1,"branch_policies":[{"id":1,"name":"develop","type":"branch"}]}'
  [policy-for-a-tag-named-main]='policies|{"total_count":1,"branch_policies":[{"id":1,"name":"main","type":"tag"}]}'
  [no-right-to-store-a-secret]="public-key|-"
)
for scenario in "${!environment_refusals[@]}"; do
  new_run "${scenario}"
  fixture_file="${environment_refusals[${scenario}]%%|*}"
  fixture_content="${environment_refusals[${scenario}]#*|}"
  if [ "${fixture_content}" = - ]; then rm "${fixture}/${fixture_file}"; else printf '%s' "${fixture_content}" >"${fixture}/${fixture_file}"; fi
  drive "${app_name}"
  refused
done
for scenario in an-uppercase-name a-name-with-an-underscore a-name-with-a-leading-hyphen a-name-of-35-characters an-empty-name; do
  new_run "${scenario}"
  case "${scenario}" in
    an-uppercase-name) bad_name=Release-App ;;
    a-name-with-an-underscore) bad_name=release_app ;;
    a-name-with-a-leading-hyphen) bad_name=-release ;;
    a-name-of-35-characters) bad_name="$(printf 'a%.0s' {1..35})" ;;
    an-empty-name) bad_name="" ;;
  esac
  drive "${bad_name}"
  refused
done
scenario="no-name"
new_run "${scenario}"
drive
refused

# Failures after the page was served: the key is not stored and the command names the App GitHub may have made.
declare -A late_failures=(
  [another-slug]='conversion|.slug = "another-app"'
  [another-owner]='conversion|.owner.login = "someone-else"'
  [lesser-permission]='conversion|.permissions.contents = "read"'
  [extra-permission]='conversion|.permissions.issues = "read"'
  [missing-permission]='conversion|del(.permissions.metadata)'
  [subscribed-event]='conversion|.events = ["push"]'
  [no-key-in-the-answer]='conversion|del(.pem)'
  [failed-conversion]='curl-fails|-'
  [failed-store]='secret-set-fails|-'
)
for scenario in "${!late_failures[@]}"; do
  new_run "${scenario}"
  fixture_file="${late_failures[${scenario}]%%|*}"
  fixture_content="${late_failures[${scenario}]#*|}"
  if [ "${fixture_content}" = - ]; then : >"${fixture}/${fixture_file}"; else conversion "${fixture_content}" >"${fixture}/${fixture_file}"; fi
  drive "${app_name}"
  [ "${status}" -ne 0 ] || fail "${scenario}: the command exited 0"
  ! stored || fail "${scenario}: a key was stored"
  [ "$(secret_sets)" -le 1 ] || fail "${scenario}: gh secret set ran more than once"
  grep -qxF "${settings_page}" "${run}/err" || fail "${scenario}: the App's settings page is not named: $(cat "${run}/err")"
  grep -qF 'if it exists, delete it and rerun with a new name' "${run}/err" || fail "${scenario}: no recovery line"
  ! grep -qF "${installation_page}" "${run}/opened" || fail "${scenario}: the installation page was opened"
  no_leak
  echo "${scenario}: nothing is stored and the command names the App to delete"
done

# The listener alone: with no redirect it stores nothing and, once its deadline passes, exits non-zero.
scenario="the-deadline-passes-without-a-redirect"
new_run "${scenario}"
coproc serving { in_world python3 -I "${listener}" "${app_name}" 2 overnightworks/platform release-bump RELEASE_BUMP_APP_PRIVATE_KEY 2>"${run}/err"; }
serving_pid=$!
IFS= read -r -u "${serving[0]}" page_url
grep -qE '^http://127\.0\.0\.1:[0-9]+/$' <<<"${page_url}" || fail "${scenario}: the listener printed no address"
status=0
wait "${serving_pid}" || status=$?
[ "${status}" -ne 0 ] || fail "${scenario}: the listener exited 0 without a redirect"
[ "$(calls "${run}/curl-calls" .)" -eq 0 ] && [ "$(secret_sets)" -eq 0 ] || fail "${scenario}: the listener converted a code or stored a key"
no_leak
echo "${scenario}: the deadline stores nothing"
