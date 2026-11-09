#!/usr/bin/env bash
# Drive `mise run secrets:github-host-keys` against a fake curl that records its arguments and its stdin: a set
# GITHUB_META_TOKEN reaches curl's stdin as an Authorization header and no argument, output or trace, and an unset or
# empty one leaves the read without any Authorization.
# Usage: mise exec -- tests/secrets/github_meta_token_reaches_only_curls_stdin.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
mkdir "$fake_bin"
dummy_token="ghs_$(head --bytes=24 /dev/urandom | base64 --wrap=0 | tr '+/=' 'abc')"
host_key="ssh-ed25519 AAAAfakehostkeyblob"
manifest="$(HOST_KEY="$host_key" yq --null-input '.apiVersion = "v1" | .kind = "Secret" |
  .metadata.name = "host-key-proof" | .stringData.known_hosts = "github.com " + strenv(HOST_KEY)')"

cat >"$fake_bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$FAKE_RECORD/arguments"
case " $* " in *" --config - "*) cat >"$FAKE_RECORD/stdin" ;; *) : >"$FAKE_RECORD/stdin" ;; esac
printf '{"ssh_keys":["%s"]}\n' "$FAKE_HOST_KEY"
FAKE
chmod +x "$fake_bin/curl"

# run_task <name> <token setting>...: the task with the token as given, then its trace; sets the record directory.
export FAKE_HOST_KEY="$host_key"
export MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
run_task() {
  local name="$1"
  shift
  FAKE_RECORD="$work_directory/$name"
  mkdir "$FAKE_RECORD"
  export FAKE_RECORD
  printf '%s' "$manifest" | env "$@" PATH="$fake_bin:$PATH" mise run secrets:github-host-keys \
    >"$FAKE_RECORD/output" 2>"$FAKE_RECORD/errors" || fail "the task failed on $name: $(cat "$FAKE_RECORD/errors")"
  cmp --silent "$FAKE_RECORD/output" <(printf '%s' "$manifest") || fail "the task changed the manifest on $name"
}

run_task token GITHUB_META_TOKEN="$dummy_token"
grep --quiet --fixed-strings -- "Authorization: Bearer $dummy_token" "$work_directory/token/stdin" ||
  fail "the token did not reach curl's stdin"
! grep --quiet --fixed-strings -- "$dummy_token" "$work_directory/token/arguments" || fail "the token reached an argument"
! grep --quiet --fixed-strings -- "$dummy_token" "$work_directory/token/output" "$work_directory/token/errors" ||
  fail "the token reached an output"
for flag in --fail --proto --tlsv1.2; do
  grep --quiet --fixed-strings --line-regexp -- "$flag" "$work_directory/token/arguments" || fail "curl lost $flag"
done
echo "a set token reaches curl's stdin and no argument or output"

for setting in unset empty; do
  if [ "$setting" = unset ]; then run_task "$setting" -u GITHUB_META_TOKEN; else run_task "$setting" GITHUB_META_TOKEN=; fi
  ! grep --quiet --ignore-case authorization "$work_directory/$setting/arguments" "$work_directory/$setting/stdin" ||
    fail "curl got an Authorization with the token $setting"
done
echo "an unset or empty token leaves curl without an Authorization"

# The task's script under bash -x, with the tasks it calls as mise runs them: the trace holds no token.
FAKE_RECORD="$work_directory/traced"
mkdir "$FAKE_RECORD"
export FAKE_RECORD
for task in secrets:github-meta secrets:github-host-keys; do
  yq -p toml -oy ".tasks.\"$task\".run" "$repository_root/mise.toml" >"$work_directory/${task#secrets:}.sh"
done
printf '%s' "$manifest" | GITHUB_META_TOKEN="$dummy_token" PATH="$fake_bin:$PATH" \
  bash -x "$work_directory/github-host-keys.sh" >"$FAKE_RECORD/output" 2>"$FAKE_RECORD/errors" ||
  fail "the traced task failed: $(cat "$FAKE_RECORD/errors")"
GITHUB_META_TOKEN="$dummy_token" PATH="$fake_bin:$PATH" bash -x "$work_directory/github-meta.sh" \
  >>"$FAKE_RECORD/output" 2>>"$FAKE_RECORD/errors" || fail "the traced meta read failed"
! grep --quiet --fixed-strings -- "$dummy_token" "$FAKE_RECORD/output" "$FAKE_RECORD/errors" ||
  fail "a run under bash -x printed the token"
echo "a run under bash -x prints no token"
