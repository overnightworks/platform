#!/usr/bin/env bash
# Drive scripts/github_meta.sh and `mise run secrets:github-host-keys` against a fake curl that records its arguments and
# its stdin: a set GITHUB_META_TOKEN reaches curl's stdin as an Authorization header and no argument, output or trace,
# an unset or empty one leaves the read without any Authorization, and a token outside the Bearer alphabet is refused by
# the variable's name before curl starts.
# Usage: mise exec -- tests/secrets/github_meta_token_is_refused_or_reaches_only_curls_stdin.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
cd "$repository_root"
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

export FAKE_HOST_KEY="$host_key"
export MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
new_record() {
  FAKE_RECORD="$work_directory/$1"
  mkdir "$FAKE_RECORD"
  export FAKE_RECORD
}
# run_task <name> <env setting>...: the task with the token as given; the record directory is $work_directory/<name>.
run_task() {
  local name="$1"
  shift
  new_record "$name"
  printf '%s' "$manifest" | env "$@" PATH="$fake_bin:$PATH" mise run secrets:github-host-keys \
    >"$FAKE_RECORD/output" 2>"$FAKE_RECORD/errors" || fail "the task failed on $name: $(cat "$FAKE_RECORD/errors")"
  cmp --silent "$FAKE_RECORD/output" <(printf '%s' "$manifest") || fail "the task changed the manifest on $name"
}
check_curl_flags() {
  local flag
  for flag in --fail --silent --show-error --proto =https --tlsv1.2 "$GITHUB_META_URL"; do
    grep --quiet --fixed-strings --line-regexp -- "$flag" "$work_directory/$1/arguments" || fail "curl lost $flag on $1"
  done
}

run_task token GITHUB_META_TOKEN="$dummy_token"
grep --quiet --fixed-strings -- "Authorization: Bearer $dummy_token" "$work_directory/token/stdin" ||
  fail "the token did not reach curl's stdin"
! grep --quiet --fixed-strings -- "$dummy_token" "$work_directory/token/arguments" || fail "the token reached an argument"
! grep --quiet --fixed-strings -- "$dummy_token" "$work_directory/token/output" "$work_directory/token/errors" ||
  fail "the token reached an output"
check_curl_flags token
echo "a set token reaches curl's stdin and no argument or output"

for setting in unset empty; do
  if [ "$setting" = unset ]; then run_task "$setting" -u GITHUB_META_TOKEN; else run_task "$setting" GITHUB_META_TOKEN=; fi
  ! grep --quiet --ignore-case authorization "$work_directory/$setting/arguments" "$work_directory/$setting/stdin" ||
    fail "curl got an Authorization with the token $setting"
  check_curl_flags "$setting"
done
echo "an unset or empty token leaves curl without an Authorization and with the same flags"

# Each refused token: no exit 0, no stdout, no curl, and the variable's name in stderr without any part of the value.
check_refused() {
  local name="$1" token="$2" status=0 part
  new_record "$name"
  env GITHUB_META_TOKEN="$token" PATH="$fake_bin:$PATH" scripts/github_meta.sh \
    >"$FAKE_RECORD/output" 2>"$FAKE_RECORD/errors" || status=$?
  [ "$status" != 0 ] || fail "a token with $name was not refused"
  [ ! -s "$FAKE_RECORD/output" ] || fail "a token with $name printed on stdout"
  [ ! -e "$FAKE_RECORD/arguments" ] || fail "curl started for a token with $name"
  grep --quiet --fixed-strings GITHUB_META_TOKEN "$FAKE_RECORD/errors" || fail "the refusal for $name does not name GITHUB_META_TOKEN"
  for part in ghs_a 'a"b' 'url =' x.invalid; do
    ! grep --quiet --fixed-strings -- "$part" "$FAKE_RECORD/errors" || fail "the refusal for $name holds a part of the value"
  done
}
check_refused quote 'ghs_a"b'
check_refused newline $'ghs_a\nurl = https://x.invalid'
echo "a token outside the Bearer alphabet is refused by name before curl starts"

# The script and the task under bash -x: the trace holds no token.
new_record traced
printf '%s' "$manifest" | GITHUB_META_TOKEN="$dummy_token" PATH="$fake_bin:$PATH" \
  bash -x <(yq -p toml -oy '.tasks."secrets:github-host-keys".run' mise.toml) >"$FAKE_RECORD/output" 2>"$FAKE_RECORD/errors" ||
  fail "the traced task failed: $(cat "$FAKE_RECORD/errors")"
GITHUB_META_TOKEN="$dummy_token" PATH="$fake_bin:$PATH" bash -x scripts/github_meta.sh \
  >>"$FAKE_RECORD/output" 2>>"$FAKE_RECORD/errors" || fail "the traced meta read failed"
! grep --quiet --fixed-strings -- "$dummy_token" "$FAKE_RECORD/output" "$FAKE_RECORD/errors" ||
  fail "a run under bash -x printed the token"
echo "a run under bash -x prints no token"
