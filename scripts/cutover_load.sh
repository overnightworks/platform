#!/usr/bin/env bash
# The commands behind `mise run cutover:load <dump> <evidence>` and `mise run cutover:check <evidence>`. The evidence
# is the file `cutover:preflight --evidence` wrote: the public issuer and its key ids before the outage.
#   load   refuses a dump that differs from realm.yaml's user profile or holds an object only realm.yaml declares, before
#          anything is loaded; else loads it (db:load-dump --compare keycloak), checks the copy against the dump and the
#          evidence, reads the admin group and moves the members of the old AI group without deleting it
#   check  compares the public issuer and its key ids with the evidence
# Exit 0: everything held. 1: a refusal or a difference, named; a refusal before the load ends in `nothing loaded`, a
# failure after it names the way back. 2: a usage error before any call. Every line is a name, a count, a key id or
# `equal` or `DIFFERS`; a dump holds keys and hashes, so no line holds a row, a secret, a digest or a token.
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# shellcheck source=keycloak_kcadm.sh
source "$root/scripts/keycloak_kcadm.sh"
realm="$(yq '.realm' "$root/infrastructure/keycloak/realm.yaml")"
exec {kcadm_diagnostics_fd}>/dev/null
# A kubectl call ends past the deadline; the container's own timeout, below it, ends pg_restore.
deadline=2m
container_deadline=100
# The objects realm.yaml declares and hal's own realm file does not, as <kind>:<name>. One in the dump was made in hal's
# console, and config-cli would merge the file's declaration into it unseen. Keycloak's built-in scopes profile and email
# are no such object: every realm has them.
console_objects="client:agent-mozart user:service-account-agent-mozart scope:agent-identity group:agents group:agent-adders group:agent-owners"
# The AI group's admin subgroup, whose members come with the dump; litellm_keys.sh owns the literal.
admin_group=/services/litellm/admin

command_name="${1:-}"
task_name="cutover:$command_name"
phase=none
# fail <what>: the run's one failure line; it says what the run left behind.
fail() {
  local suffix=""
  case "$phase" in
    before_load) suffix="; nothing loaded" ;;
    loading) suffix="; the database may be partly loaded, its lines above say what db:load-dump changed; the way back is the operator's cd ~/srv/hal && hal start keycloak" ;;
    after_load) suffix="; the copy is loaded and not proven; the way back is the operator's cd ~/srv/hal && hal start keycloak" ;;
  esac
  echo "$task_name: $1$suffix" >&2
  exit 1
}
say() { echo "$task_name: $1"; }
usage() {
  echo "cutover:${command_name:-load|check}: $1; usage: cutover:load <dump> <evidence> or cutover:check <evidence>" >&2
  exit 2
}

# read_evidence <file>: sets evidence_issuer and evidence_kids (sorted), or ends with a usage error when the file is not in the
# format cutover:preflight writes: one issuer, at least one key id and no other key than hal-main, platform and read-at.
read_evidence() {
  local key value issuers=0
  case "$1" in /*) ;; *) usage "the evidence path $1 is not absolute" ;; esac
  { [ -f "$1" ] && [ -r "$1" ]; } || usage "no readable evidence file $1"
  evidence_issuer="" evidence_kids=""
  while IFS=' ' read -r key value || [ -n "$key" ]; do
    case "$key" in
      issuer) issuers=$((issuers + 1)); evidence_issuer="$value" ;;
      kid) evidence_kids+="$value"$'\n' ;;
      hal-main | platform | read-at) ;;
      *) usage "$1 holds a key that the evidence of cutover:preflight does not have" ;;
    esac
  done <"$1"
  { [ "$issuers" = 1 ] && [ -n "$evidence_issuer" ] && [ -n "${evidence_kids//$'\n'/}" ]; } ||
    usage "$1 holds not exactly one issuer and at least one key id"
  evidence_kids="$(sort <<<"${evidence_kids%$'\n'}")"
}

# The awk program the gate runs in the database's container over the dump's COPY streams, which pg_restore writes to
# stdout without connecting. It prints no-realm, then the console-made objects as `object <kind> <name>`, then
# default-profile, unreadable-profile or the realm's stored user profile between profile-begin and profile-end. Keycloak 26
# stores the profile as one component of the realm with exactly one config value kc.user.profile.config
# (DeclarativeUserProfileProvider's UP_COMPONENT_CONFIG_KEY); a realm without that component, or whose value is missing or
# blank, has Keycloak's built-in default profile, which is default-profile. Its migration to 23 merges the older
# config-piece-<n> values into the key only for a realm whose user profile was enabled, so pieces can remain. Any other
# state, a second component or value, or a leftover piece, is an unreadable profile. It buffers the rows it needs, so the
# order of the tables in the dump does not matter, and it holds component_config's other values, among them the realm
# keys' private parts, without printing any.
gate_program='function unescape(text,   result, position, character) {
    result = ""
    for (position = 1; position <= length(text); position++) {
      character = substr(text, position, 1)
      if (character == "\\") {
        position++; character = substr(text, position, 1)
        if (character == "n") character = "\n"; else if (character == "t") character = "\t"; else if (character == "r") character = "\r"
      }
      result = result character
    }
    return result
  }
  copying && /^\\[.]$/ { copying = 0; next }
  copying {
    split($0, cell, "\t")
    if (table == "realm") { if (cell[column["name"]] == realm) realm_id = cell[column["id"]] }
    else if (table == "component") {
      if (cell[column["provider_type"]] == "org.keycloak.userprofile.UserProfileProvider") { components++; component_id[components] = cell[column["id"]]; component_realm[components] = cell[column["realm_id"]] }
    } else if (table == "component_config") {
      if (cell[column["name"]] ~ /^(kc[.]user[.]profile[.]config$|config-piece)/) { configs++; config_component[configs] = cell[column["component_id"]]; config_name[configs] = cell[column["name"]]; config_value[configs] = cell[column["value"]] }
    } else {
      rows++; row_table[rows] = table; row_realm[rows] = cell[column["realm_id"]]
      row_name[rows] = cell[column[table == "client" ? "client_id" : table == "user_entity" ? "username" : "name"]]
      row_parent[rows] = cell[column["parent_group"]]
    }
    next
  }
  /^COPY / {
    table = $2; sub(/^[^.]*[.]/, "", table)
    header = $0; sub(/^[^(]*[(]/, "", header); sub(/[)].*/, "", header)
    split("", column); columns = split(header, names, /, */)
    for (i = 1; i <= columns; i++) column[names[i]] = i
    copying = 1
  }
  END {
    if (realm_id == "") { print "no-realm"; exit }
    kinds["client"] = "client"; kinds["user_entity"] = "user"; kinds["client_scope"] = "scope"; kinds["keycloak_group"] = "group"
    for (i = 1; i <= rows; i++) {
      if (row_realm[i] != realm_id) continue
      top_level = row_table[i] != "keycloak_group" || row_parent[i] == "\\N" || row_parent[i] == "" || row_parent[i] == " "
      if (top_level) present[kinds[row_table[i]] ":" row_name[i]] = 1
    }
    count = split(wanted, wanted_list, " ")
    for (i = 1; i <= count; i++) if (wanted_list[i] in present) { kind_and_name = wanted_list[i]; sub(":", " ", kind_and_name); print "object " kind_and_name }
    profile_component = ""; matches = 0
    for (i = 1; i <= components; i++) if (component_realm[i] == realm_id) { matches++; profile_component = component_id[i] }
    wholes = 0; others = 0; whole = ""
    for (i = 1; i <= configs; i++) {
      if (config_component[i] != profile_component) continue
      if (config_name[i] == "kc.user.profile.config") { wholes++; whole = config_value[i] } else others++
    }
    text = unescape(whole)
    if (matches == 0 || (matches == 1 && others == 0 && (wholes == 0 || (wholes == 1 && (whole == "\\N" || text ~ /^[ \t\n\r]*$/))))) print "default-profile"
    else if (matches == 1 && wholes == 1 && others == 0) print "profile-begin\n" text "\nprofile-end"
    else print "unreadable-profile"
  }'

# profile_differences <stored profile> <expected profile>: one line per attribute, group or other top-level key that is
# missing, extra or different, by its name. An attribute without multivalued is not multivalued.
profile_differences() {
  jq -rn --argjson stored "$1" --argjson expected "$2" '
    def by_name($list): ($list // []) | map({key: .name, value: .}) | from_entries;
    def normal: (.attributes //= []) | (.groups //= []) | .attributes |= map(.multivalued //= false);
    def differences($kind; $stored; $expected):
      (($expected | keys[]) as $name | select($stored | has($name) | not) | "\($kind) \($name) is missing"),
      (($stored | keys[]) as $name | select($expected | has($name) | not) | "\($kind) \($name) is extra"),
      (($expected | keys[]) as $name | select(($stored | has($name)) and $stored[$name] != $expected[$name]) | "\($kind) \($name) is different");
    ($stored | if type == "object" then . else error("no object") end | normal) as $s | ($expected | normal) as $e
    | differences("attribute"; by_name($s.attributes); by_name($e.attributes)),
      differences("group"; by_name($s.groups); by_name($e.groups)),
      differences("key"; $s | del(.attributes, .groups); $e | del(.attributes, .groups))'
}

# gate <dump>: refuses before anything is loaded when the dump's user profile differs from realm.yaml's, apart from the
# attribute agent_owner, which only the platform sets, or when it holds an object only realm.yaml declares. A realm that
# stores no profile has Keycloak's built-in default, which default-user-profile.json holds as Keycloak 26.8.1 ships it
# (services/src/main/resources/org/keycloak/userprofile/config/keycloak-default-user-profile.json at the tag 26.8.1); the
# gate compares that file instead, and a profile it cannot read, or that is no JSON object, refuses.
gate() {
  local read_dump status findings=0 line kind name stored expected differences
  read_dump="$(timeout "$deadline" kubectl --namespace keycloak exec --stdin postgres-0 --container postgres -- sh -c \
    'set -o pipefail; timeout "$2" pg_restore --data-only --table=realm --table=client --table=client_scope \
      --table=keycloak_group --table=user_entity --table=component --table=component_config --file=- 2>/dev/null |
      awk -v realm="$3" -v wanted="$4" "$1"' sh "$gate_program" "$container_deadline" "$realm" "$console_objects" \
    <"$1" 2>/dev/null)" || fail "reading the dump through Keycloak's Postgres failed"
  if grep -qx no-realm <<<"$read_dump"; then say "the dump holds no realm $realm"; findings=$((findings + 1)); fi
  while read -r kind name; do
    say "the dump holds $kind $name, which only realm.yaml declares"
    findings=$((findings + 1))
  done < <(sed -n 's/^object \([a-z]*\) \(.*\)$/\1 \2/p' <<<"$read_dump")
  # The status is the first line that is no object line; the stored profile follows it and never decides.
  status="$(grep -vm1 '^object ' <<<"$read_dump" || true)"
  if [ "$status" = unreadable-profile ]; then
    say "the dump holds no readable user profile of realm $realm"
    findings=$((findings + 1))
  elif [ "$status" = default-profile ] || [ "$status" = profile-begin ]; then
    if [ "$status" = default-profile ]; then
      say "the dump stores no user profile of realm $realm, so Keycloak's default applies"
      stored="$(cat "$root/infrastructure/keycloak/default-user-profile.json")"
    else
      stored="$(sed -n '/^profile-begin$/,/^profile-end$/p' <<<"$read_dump" | sed '1d;$d')"
    fi
    expected="$(yq -o json -I0 '.userProfile | del(.attributes[] | select(.name == "agent_owner"))' "$root/infrastructure/keycloak/realm.yaml")"
    differences="$(profile_differences "$stored" "$expected" 2>/dev/null)" || fail "the dump's stored user profile is no JSON object"
    while IFS= read -r line; do
      [ -z "$line" ] || { say "profile $line"; findings=$((findings + 1)); }
    done <<<"$differences"
  elif [ "$status" != no-realm ]; then
    say "the read of the dump returned no answer"
    findings=$((findings + 1))
  fi
  [ "$findings" = 0 ] || fail "the gate refuses the dump with $findings findings"
  say "the gate passed: the user profile that applies equals realm.yaml's apart from agent_owner, and it holds no console-made object"
}

# run_step <what> <command>...: runs the command and passes its lines on unchanged as they come, keeps them in step_output,
# and ends the run naming the step when it exits non-zero. The loop runs in this shell through lastpipe.
shopt -s lastpipe
run_step() {
  local what="$1" step_status=0 line
  shift
  step_output=""
  "$@" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "$line"; step_output+="$line"$'\n'; done || step_status=$?
  [ "$step_status" = 0 ] || fail "$what exited $step_status"
}

# group_member_count <group path>: sets members to the count of the group's members, paged as keycloak:move-group pages.
group_member_count() {
  local group_id offset=0 page
  group_id="$(kcadm get "group-by-path$1" --target-realm "$realm" --fields id --format csv --noquotes)" ||
    fail "$realm holds no $1 or Keycloak cannot be read"
  members=0
  while :; do
    page="$(kcadm get "groups/$group_id/members" --target-realm "$realm" --fields id --format csv --noquotes \
      --offset "$offset" --limit 100)" || fail "the members of $1 cannot be read"
    [ -n "$page" ] || break
    members=$((members + $(grep -c . <<<"$page")))
    offset=$((offset + 100))
  done
}

load() {
  local dump="$1" evidence_directory move_file moved
  read_evidence "$2"
  { [ -f "$dump" ] && [ -r "$dump" ]; } || usage "no readable dump file $dump"
  phase=before_load
  gate "$dump"
  phase=loading
  run_step "db:load-dump" mise run db:load-dump --compare keycloak "$dump"
  phase=after_load
  run_step "the check of the copy against the dump and the evidence" \
    "$root/tests/keycloak/restored_copy_keeps_its_keys_and_people.sh" "$dump" "$2"
  trap remove_config EXIT
  sign_in_kcadm
  group_member_count "$admin_group"
  say "$admin_group: $members members"
  evidence_directory="$(cd "$(dirname "$2")" && pwd)"
  move_file="$evidence_directory/keycloak-before-move-group-$(date --utc +%Y%m%dT%H%M%SZ).dump"
  run_step "keycloak:move-group" mise run keycloak:move-group "$move_file"
  moved="$(sed -n 's/^keycloak:move-group: \([^:]*\): \([0-9][0-9]*\) members;.*/\1 \2/p' <<<"$step_output" | head -n 1)"
  [ -n "$moved" ] || fail "keycloak:move-group's count of the old group cannot be read, though it exited 0"
  say "the copy holds hal's issuer, key ids, people, memberships and client secrets; ${moved#* } members in ${moved% *} moved to /services/litellm"
}

# check <evidence>: the public issuer and key ids against the evidence's. It cannot tell which Keycloak answers, as hal
# and the copy hold the same keys; after the publish only the copy runs.
check() {
  local discovery jwks_uri public_issuer public_kids verdict=equal
  read_evidence "$1"
  discovery="$(timeout 20 curl --silent --fail "$evidence_issuer/.well-known/openid-configuration")" ||
    fail "the discovery of $evidence_issuer cannot be read"
  public_issuer="$(jq -r '.issuer // ""' <<<"$discovery")" && jwks_uri="$(jq -r '.jwks_uri // ""' <<<"$discovery")" ||
    fail "the discovery of $evidence_issuer is no JSON object"
  [ -n "$jwks_uri" ] || fail "the discovery of $evidence_issuer names no jwks_uri"
  public_kids="$(timeout 20 curl --silent --fail "$jwks_uri" | jq -r '.keys[]?.kid' | sort)" || fail "the key set at $jwks_uri cannot be read"
  [ "$public_issuer" = "$evidence_issuer" ] || verdict=DIFFERS
  say "issuer: public $public_issuer, evidence $evidence_issuer, $verdict"
  verdict=equal
  [ -n "$public_kids" ] && [ "$public_kids" = "$evidence_kids" ] || verdict=DIFFERS
  say "key ids: public ${public_kids//$'\n'/ }, evidence ${evidence_kids//$'\n'/ }, $verdict"
  [ "$public_issuer" = "$evidence_issuer" ] && [ "$verdict" = equal ] || fail "the public answer differs from the evidence"
  say "the public issuer and key ids equal the evidence"
}

case "$command_name" in
  load) [ $# = 3 ] || usage "needs a dump and an evidence file"; load "$2" "$3" ;;
  check) [ $# = 2 ] || usage "needs an evidence file"; check "$2" ;;
  *) usage "needs the command load or check" ;;
esac
