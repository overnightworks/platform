# shellcheck shell=bash
# shellcheck disable=SC2154 # task_name, realm and username belong to the sourcing script.
# Sourced by the tasks that read a person and write a group membership through kcadm in Keycloak's own container,
# signed in as config-cli, so no secret reaches the caller's shell. The caller sets task_name, realm, the functions
# fail (which ends the task) and, in attempted, the writes it sent or may have sent; it sets an EXIT trap that calls
# remove_config before sign_in_kcadm runs.
kcadm_path=/opt/keycloak/bin/kcadm.sh
config_file=""
unreadable="Keycloak cannot be read"
keycloak_exec() { kubectl --namespace keycloak exec "$@"; }
remove_config() {
  [ -z "$config_file" ] || keycloak_exec deployment/keycloak --container keycloak -- rm -f -- "$config_file" ||
    echo "$task_name: could not remove $config_file in Keycloak's container" >&2
}
# sign_in_kcadm: kcadm signs in once with the secret in Keycloak's environment variable KC_CLI_CLIENT_SECRET, never in
# an argument list that another host user could read, and keeps its token in a private file of the container that
# remove_config deletes.
sign_in_kcadm() {
  config_file="/tmp/kcadm-$(</proc/sys/kernel/random/uuid).config"
  keycloak_exec deployment/keycloak --container keycloak -- bash -c 'umask 077 && : >"$0" &&
    KC_CLI_CLIENT_SECRET="$KC_BOOTSTRAP_ADMIN_CLIENT_SECRET" exec '"$kcadm_path"' config credentials --config "$0" \
      --server http://localhost:8080 --realm master --client "$KC_BOOTSTRAP_ADMIN_CLIENT_ID"' "$config_file" >/dev/null ||
    fail "Keycloak cannot be signed in to"
}
# kcadm_stderr: where kcadm's diagnostics go. They can quote a request URL that holds a person's id, so a task that never
# prints one sets /dev/null.
kcadm_stderr=/dev/stderr
kcadm() { keycloak_exec --stdin deployment/keycloak --container keycloak -- "$kcadm_path" "$@" --config "$config_file" 2>"$kcadm_stderr"; }
# find_person <username>: sets person_id. Keycloak's search leaves out service accounts, and a value in quotes matches a
# username, email or name exactly, so only the entries whose username is the requested one, which Keycloak stores in
# lowercase, are the person. Another user's email or name can match too and a page holds at most 100, so every page is
# read until a short one.
find_person() {
  local wanted_username="${1,,}" person_ids="" offset=0 page matched person_count
  while :; do
    page="$(kcadm get users --target-realm "$realm" --query "search=\"$1\"" --offset "$offset" --limit 100)" ||
      fail "$unreadable"
    matched="$(WANTED="$wanted_username" yq -p json -r '.[] | select(.username == strenv(WANTED)) | .id' <<<"$page")" ||
      fail "$unreadable"
    [ -z "$matched" ] || person_ids+="$matched"$'\n'
    [ "$(yq -p json 'length' <<<"$page")" -ge 100 ] || break
    offset=$((offset + 100))
  done
  person_count="$(grep -c . <<<"$person_ids" || true)"
  [ "$person_count" -gt 0 ] || fail "no person named $1 in $realm"
  [ "$person_count" = 1 ] || fail "Keycloak returned $person_count users named $1"
  person_id="${person_ids%$'\n'}"
}
# ensure_member <group path>: adds the person unless already a member, recording the write before it is sent.
ensure_member() {
  local group_id member_of
  group_id="$(kcadm get "group-by-path$1" --target-realm "$realm" --fields id --format csv --noquotes)" ||
    fail "$realm holds no $1 or Keycloak cannot be read"
  member_of="$(kcadm get "users/$person_id/groups" --target-realm "$realm" --fields id --format csv --noquotes)" ||
    fail "$unreadable"
  ! grep -qxF "$group_id" <<<"$member_of" || return 0
  attempted+=("$username in $1")
  kcadm update "users/$person_id/groups/$group_id" --target-realm "$realm" --set "realm=$realm" \
    --set "userId=$person_id" --set "groupId=$group_id" --no-merge || fail "$username could not join $1"
}
