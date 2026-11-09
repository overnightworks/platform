#!/usr/bin/env bash
# Drive `mise run bootstrap:secrets` against a fake kubectl and curl on PATH, for a GitRepository whose first
# reconcile requests are handled with Ready=False. The task observes its whole first minute before it prints the deploy
# key block, so a request that turns Ready within the minute prints none, and one that never does prints it only after
# the reads that sufficed for the first.
# Usage: mise exec -- tests/secrets/bootstrap_secrets.sh
# Proves docs/commands.md BSEC-2, BSEC-3.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT
fake_bin="${work_directory}/bin"
mkdir "${fake_bin}"

# The state the fake kubectl keeps for the task: the last requested token and the count of status reads.
cat >"${fake_bin}/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
read_count() { cat "${FAKE_STATE}/reads" 2>/dev/null || echo 0; }
case "${arguments}" in
  *"get secret"*"--ignore-not-found"*) echo "secret/kept" ;;
  *"get secret"*"--output yaml"*)
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: platform-secrets\ndata:\n  known_hosts: %s\n' \
      "$(printf 'github.com ssh-ed25519 FAKEBLOB' | base64 --wrap=0)" ;;
  *annotate*) printf '%s' "${arguments##*=}" >"${FAKE_STATE}/token" ;;
  *lastHandledReconcileAt*)
    reads=$(($(read_count) + 1))
    echo "${reads}" >"${FAKE_STATE}/reads"
    if [ "${FAKE_READY_AT_READ}" -gt 0 ] && [ "${reads}" -ge "${FAKE_READY_AT_READ}" ]; then
      echo "$(cat "${FAKE_STATE}/token") True"
    else
      echo "$(cat "${FAKE_STATE}/token") False"
    fi ;;
  *identity*)
    echo "$(read_count)" >"${FAKE_STATE}/reads-at-key"
    printf 'ssh-ed25519 FAKEKEY' | base64 --wrap=0 ;;
  *artifact.revision*) echo main@sha1:fake ;;
  *lastAppliedRevision*) echo main@sha1:fake ;;
  *"Ready\")].message"*) echo "fake not ready" ;;
  *" wait "*) ;;
  *) echo "fake kubectl: unexpected ${arguments}" >&2; exit 1 ;;
esac
FAKE
printf '#!/bin/sh\necho %s\n' "'{\"ssh_keys\":[\"ssh-ed25519 FAKEBLOB\"]}'" >"${fake_bin}/curl"
chmod +x "${fake_bin}/kubectl" "${fake_bin}/curl"
key_file="${work_directory}/keys.txt"
: >"${key_file}"

# The task's clock is bash's SECONDS, so a sleep that advances it keeps the run instant.
sleep() { SECONDS=$((SECONDS + ${1%.*})); }
export -f sleep
# mise puts its own kubectl before PATH, so the task must not load it.
export PATH="${fake_bin}:${PATH}" MISE_DISABLE_TOOLS=kubectl SOPS_AGE_KEY_FILE="${key_file}"

# Runs the task with the reconcile turning Ready on status read $1 (0: never) and sets status, output_file, reads_at_key.
run_task() {
  export FAKE_STATE="${work_directory}/state-$1" FAKE_READY_AT_READ="$1"
  mkdir "${FAKE_STATE}"
  output_file="${work_directory}/output-$1"
  status=0
  (cd "${repository_root}" && mise run bootstrap:secrets) >"${output_file}" 2>&1 || status=$?
  reads_at_key="$(cat "${FAKE_STATE}/reads-at-key" 2>/dev/null || echo none)"
}
fail() { echo "bootstrap:secrets test: $1" >&2; sed 's/^/  /' "${output_file}" >&2; exit 1; }

ready_at_read=5
run_task "${ready_at_read}"
[ "${status}" = 0 ] || fail "a handled failure followed by Ready within the minute exited ${status}"
[ "${reads_at_key}" = none ] || fail "a handled failure followed by Ready within the minute fetched the deploy key"
if grep --quiet 'Key:   ' "${output_file}"; then fail "a handled failure followed by Ready within the minute printed the key block"; fi
grep --quiet 'GitRepository platform-secrets Ready at' "${output_file}" || fail "the Ready source was not reported"
# The operator reads only the task he ran, so the subtasks it calls print nothing on success.
if grep --quiet --invert-match '^bootstrap:secrets: ' "${output_file}"; then fail "a line came from another task"; fi

run_task 0
[ "${status}" != 0 ] || fail "a source that never turns Ready exited 0"
grep --quiet 'Key:   ssh-ed25519 FAKEKEY' "${output_file}" || fail "a source that never turns Ready printed no key block"
[ "${reads_at_key}" -ge "${ready_at_read}" ] ||
  fail "the key block came after ${reads_at_key} reads, before the ${ready_at_read} that sufficed for a Ready source"
echo "bootstrap:secrets test: held"
