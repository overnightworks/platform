#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
umask 077
proof_dir="$RUNNER_TEMP/github-host-keys"
mkdir "$proof_dir"

# flux's real export of a throwaway deploy key, which the job never registers or applies.
export_deploy_key() {
  flux create secret git host-key-proof --ssh-key-algorithm=ed25519 --export --url="$(
    yq 'select(.kind == "GitRepository" and .metadata.name == "platform-secrets") | .spec.url' \
      clusters/pc/secrets.yaml)"
}
# The form kubectl get prints, which the PC's re-runs check.
as_data() { yq '.data = (.stringData | map_values(@base64)) | del(.stringData)'; }
# tee hands the manifest to the filter and through fd 3 to sha256sum, so the private key stays in pipes and
# only the digests of the filter's input and output reach a file; cmp, unlike diff, prints no content.
check_passes() {
  { tee /dev/fd/3 | mise run secrets:github-host-keys | sha256sum >"$proof_dir/$1.output"; } 3>&1 |
    sha256sum >"$proof_dir/$1.input" || fail "secrets:github-host-keys refused flux's export in its $1 form"
  cmp --silent "$proof_dir/$1.input" "$proof_dir/$1.output" ||
    fail "secrets:github-host-keys changed flux's export in its $1 form"
  echo "passed on unchanged: flux's export in its $1 form"
}
# Their stderr reaches the log only once it is known to hold no private key.
passes_status=0
{ export_deploy_key | check_passes stringData && export_deploy_key | as_data | check_passes data; } \
  2>"$proof_dir/stderr" || passes_status=$?
if grep --quiet 'PRIVATE KEY' "$proof_dir/stderr"; then fail "the checks' log would hold a private key"; fi
cat "$proof_dir/stderr"
[ "$passes_status" = 0 ] || fail "flux's export did not pass secrets:github-host-keys unchanged"

github_ed25519="$(mise run secrets:github-meta |
  yq -p json '.ssh_keys[] | select(test("^ssh-ed25519 "))')"
[ -n "$github_ed25519" ] || fail "$GITHUB_META_URL lists no ssh-ed25519 key"
check_refuses() {
  local status=0
  known_hosts="$2" yq --null-input '.apiVersion = "v1" | .kind = "Secret" |
      .metadata.name = "host-key-proof" | .stringData.known_hosts = strenv(known_hosts)' |
    mise run secrets:github-host-keys >"$proof_dir/refused" || status=$?
  [ "$status" = 1 ] || fail "secrets:github-host-keys exited $status, not 1, on $1"
  [ ! -s "$proof_dir/refused" ] || fail "secrets:github-host-keys passed $1 on"
  echo "refused with exit 1 and nothing passed on: $1"
}
zero_blob="$(head --bytes=51 /dev/zero | base64 --wrap=0)"
check_refuses "an all-zero ed25519 blob under github.com" "github.com ssh-ed25519 $zero_blob"
check_refuses "an empty known_hosts" ""
check_refuses "a @cert-authority line with GitHub's ed25519 key" "@cert-authority github.com $github_ed25519"
check_refuses "GitHub's own ed25519 key under evil.example" "evil.example $github_ed25519"
