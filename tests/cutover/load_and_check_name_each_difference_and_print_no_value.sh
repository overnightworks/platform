#!/usr/bin/env bash
# Drive scripts/cutover_load.sh, with the check it calls in tests/keycloak, against fake kubectl, mise, curl, flux, gh,
# date and a git that refuses every call, all first on PATH, and against fake pg_restore, pg_dump and psql that stand in
# Keycloak's Postgres container, where the real awk and sha256sum read planted COPY streams. Each difference between a
# dump and realm.yaml, between the copy and the dump or the evidence, and between the public issuer and the evidence is
# named and ends the run at exit 1, with `nothing loaded` for a refusal before the load; a usage error ends it at exit
# 2 before any call; and no output holds a planted secret, its digest or a private key. Every call is one of the reads
# or the two mise tasks the contract lists: the fakes refuse any other, and the cell turns red on each planted call.
# Usage: mise exec -- tests/cutover/load_and_check_name_each_difference_and_print_no_value.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
container_bin="$work_directory/container-bin"
postgres_checks="$work_directory/postgres-checks"
base="$work_directory/base"
mkdir "$fake_bin" "$container_bin" "$postgres_checks" "$base"
script="$repository_root/scripts/cutover_load.sh"
forward_port=34568
realm="$(yq '.realm' "$repository_root/infrastructure/keycloak/realm.yaml")"
issuer="https://auth.example.test/realms/$realm"
yq 'select(.kind == "ConfigMap" and .metadata.name == "postgres") | .data["table-digests.sh"]' \
  "$repository_root/infrastructure/postgres/postgres.yaml" >"$postgres_checks/table-digests.sh"
[ -s "$postgres_checks/table-digests.sh" ] || fail "the ConfigMap postgres holds no table-digests.sh"

# ---------------------------------------------------------------- the fakes
cat >"$work_directory/fake_lib.sh" <<'FAKE'
tool="$(basename "$0")"
scenario="$FAKE_SCENARIO"
state="$FAKE_STATE"
printf '%q ' "$@" >>"$FAKE_LOG/$tool"
echo >>"$FAKE_LOG/$tool"
{ printf '%s ' "$tool"; printf '%q ' "$@"; echo; } >>"$FAKE_LOG/events"
echo "${PATH%%:*}" >>"$FAKE_LOG/path"
refuse() {
  echo "$tool: $1: $*" >>"$FAKE_LOG/refused"
  echo "fake $tool refuses: $1" >&2
  exit 99
}
# A reader the scenario makes fail.
failing() { [ ! -e "$scenario/fail/$1" ] || exit 1; }
loaded() { [ -e "$state/loaded" ]; }
FAKE

write_fake() {
  { echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'; echo 'source "$FAKE_LIB"'; cat; } >"$1/$2"
  chmod +x "$1/$2"
}

# kubectl answers only what the contract lists. Before the load only the gate's read of the dump through the database's
# container passes. The container's own tools are the fakes of container-bin, and the container's sh is bash, which has
# the pipefail that the container's busybox sh has.
write_fake "$fake_bin" kubectl <<'FAKE'
[ "${1-}" = --namespace ] && [ "${2-}" = keycloak ] || refuse "kubectl without --namespace keycloak"
shift 2
verb="${1-}"
shift
case "$verb" in
  get)
    [ "$*" = "job config-cli -o json" ] || refuse "kubectl get form"
    loaded || refuse "kubectl get before the load"
    failing job
    cat "$scenario/job.json" ;;
  port-forward)
    [ "$*" = "--address 127.0.0.1 service/keycloak :http" ] || refuse "kubectl port-forward form"
    loaded || refuse "kubectl port-forward before the load"
    failing port-forward
    echo "Forwarding from 127.0.0.1:$FAKE_FORWARD_PORT -> 8080"
    exec sleep 3600 ;;
  exec)
    stdin_flag=false
    if [ "${1-}" = --stdin ]; then stdin_flag=true; shift; fi
    target="${1-}" container="${3-}"
    [ "${2-}" = --container ] && [ "${4-}" = -- ] || refuse "kubectl exec form"
    shift 4
    case "$target/$container" in
      postgres-0/postgres)
        if ! loaded; then
          { [ "$stdin_flag" = true ] && [ "${1-}" = sh ]; } || refuse "kubectl exec into the database before the load"
        fi
        # After the load, the programs are the body's: psql under env, or sh -c around pg_restore or pg_dump.
        if loaded; then
          program=("$@")
          if [ "${program[0]}" = env ]; then
            program=("${program[@]:1}")
            while [[ ${program[0]-} == *=* ]]; do program=("${program[@]:1}"); done
          fi
          case "${program[0]-}" in
            psql) ;;
            sh) { [ "${program[1]-}" = -c ] && [[ ${program[2]-} == *pg_restore* || ${program[2]-} == *pg_dump* ]]; } ||
              refuse "kubectl exec sh that runs neither pg_restore nor pg_dump" ;;
            *) refuse "kubectl exec program ${program[0]-}" ;;
          esac
        fi
        rewritten=()
        for argument in "$@"; do rewritten+=("${argument//\/etc\/postgres-checks\//$FAKE_POSTGRES_CHECKS/}"); done
        export PATH="$FAKE_CONTAINER_BIN:$PATH"
        if [ "$stdin_flag" = true ]; then exec "${rewritten[@]}"; else exec "${rewritten[@]}" </dev/null; fi ;;
      deployment/keycloak/keycloak)
        loaded || refuse "kubectl exec into Keycloak before the load"
        case "${1-}" in
          bash)
            { [ "${2-}" = -c ] && [[ ${3-} == *"config credentials"* ]]; } || refuse "kubectl exec bash form"
            failing sign-in
            touch "$state/signed-in" ;;
          rm)
            { [ $# = 4 ] && [ "$2 $3" = "-f --" ]; } || refuse "kubectl exec rm form"
            touch "$state/config-removed" ;;
          /opt/keycloak/bin/kcadm.sh)
            [ -e "$state/signed-in" ] || refuse "kcadm without a sign-in"
            [ "${2-}" = get ] || refuse "kcadm verb ${2-}"
            [ "${*: -2:1}" = --config ] || refuse "kcadm without --config"
            case "${3-}" in
              group-by-path/services/litellm/admin)
                failing admin-group
                [ -f "$scenario/admin-group-id" ] || exit 1
                cat "$scenario/admin-group-id" ;;
              groups/*/members)
                [ "${3#groups/}" = "$(cat "$scenario/admin-group-id")/members" ] || refuse "kcadm members of another group"
                offset=0
                arguments=("$@")
                for position in "${!arguments[@]}"; do
                  [ "${arguments[$position]}" != --offset ] || offset="${arguments[$((position + 1))]}"
                done
                sed -n "$((offset + 1)),$((offset + 100))p" "$scenario/admin-members" ;;
              *) refuse "kcadm path ${3-}" ;;
            esac ;;
          *) refuse "kubectl exec into Keycloak: ${1-}" ;;
        esac ;;
      *) refuse "kubectl exec target $target" ;;
    esac ;;
  *) refuse "kubectl verb $verb" ;;
esac
FAKE

write_fake "$fake_bin" mise <<'FAKE'
case "$*" in
  "run db:load-dump --compare keycloak $FAKE_DUMP")
    ! loaded || refuse "a second load in one run"
    if [ -e "$scenario/fail/mise-load" ]; then echo "db:load-dump: the load failed" >&2; exit 1; fi
    touch "$state/loaded"
    echo "db:load-dump: keycloak loaded; every table equal"
    ! [ -e "$scenario/no-newline" ] || printf 'db:load-dump: a last line without a newline' ;;
  "run keycloak:move-group $FAKE_EVIDENCE_DIRECTORY/keycloak-before-move-group-"*".dump")
    loaded || refuse "the move before the load"
    file="$3"
    [[ ${file##*/} =~ ^keycloak-before-move-group-[0-9]{8}T[0-9]{6}Z\.dump$ ]] || refuse "the move's file name"
    [ ! -e "$file" ] || refuse "the move's file exists, which move-group refuses"
    if [ -e "$scenario/fail/mise-move" ]; then echo "keycloak:move-group: a member could not join; db:load-dump keycloak $file rolls back" >&2; exit 1; fi
    : >"$file"
    echo "keycloak:move-group: keycloak dumped to $file; pg_dump's and pg_restore's messages, 0 lines, are in $file.dump.log"
    echo "keycloak:move-group: /services/agent-service/api: 3 members; /services/litellm: 5 members, every one of /services/agent-service/api among them" ;;
  *) refuse "mise form" ;;
esac
FAKE

# curl computes the method from its options as a real one does and answers only a URL the scenario serves.
write_fake "$fake_bin" curl <<'FAKE'
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --silent | --fail) ;;
    --max-time) shift ;;
    --request | -X | --data | --data-* | -d | --form | -F | --json | --upload-file | -T | --head | -I | --config | -K) refuse "curl option $1" ;;
    -*) refuse "curl option $1" ;;
    *) url="$1" ;;
  esac
  shift
done
key="$(printf '%s' "$url" | tr -c 'A-Za-z0-9\n' _)"
[ -f "$scenario/http/$key" ] || refuse "curl URL $url"
[ ! -e "$scenario/http/$key.fail" ] || exit 22
cat "$scenario/http/$key"
FAKE

for tool in flux gh git; do write_fake "$fake_bin" "$tool" <<'FAKE'
refuse "a call of $tool, which the commands never make"
FAKE
done

write_fake "$fake_bin" date <<'FAKE'
[ "$*" = "--utc +%Y%m%dT%H%M%SZ" ] || refuse "date form"
count=$(($(cat "$scenario/clock" 2>/dev/null || echo 0) + 1))
echo "$count" >"$scenario/clock"
printf '20261109T0000%02dZ\n' "$count"
FAKE

ln -s "$(command -v bash)" "$container_bin/sh"

write_fake "$container_bin" pg_restore <<'FAKE'
tables=()
for argument in "$@"; do
  case "$argument" in
    --data-only | --file=-) ;;
    --table=*) tables+=("${argument#--table=}") ;;
    *) refuse "pg_restore option $argument, which could connect or write" ;;
  esac
done
[ "${#tables[@]}" -gt 0 ] || refuse "pg_restore without a table"
cmp -s - "$FAKE_DUMP" || refuse "pg_restore reads another stream than the dump"
failing pg_restore
printf -- '--\n-- PostgreSQL database dump\n--\n\nSET statement_timeout = 0;\n\n'
for table in "${tables[@]}"; do
  [ ! -f "$scenario/dump-tables/$table" ] || cat "$scenario/dump-tables/$table"
done
FAKE

write_fake "$container_bin" pg_dump <<'FAKE'
loaded || refuse "pg_dump before the load"
[ $# -ge 3 ] && [ "$1 $2" = "--data-only --lock-wait-timeout=10s" ] || refuse "pg_dump form"
shift 2
for argument in "$@"; do
  [[ $argument == --table=* ]] || refuse "pg_dump option $argument"
  cat "$scenario/live-tables/${argument#--table=}"
done
FAKE

write_fake "$container_bin" psql <<'FAKE'
loaded || refuse "psql before the load"
[ $# = 5 ] && [ "$1 $2 $3 $4" = "--no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1" ] && [[ $5 == "--command=SELECT"* ]] ||
  refuse "psql form, which is one SELECT"
# One statement: nothing but white space follows a semicolon.
sql="${5#--command=}"
[[ $sql != *\;* ]] || [[ "${sql#*;}" =~ ^[[:space:]]*$ ]] || refuse "psql runs more than one statement"
case "$5" in
  *is_temporary_admin*) cat "$scenario/temporary-count" ;;
  *service_account_client_link*) cat "$scenario/live-service-accounts" ;;
  *) refuse "psql query" ;;
esac
FAKE

# ------------------------------------------------------ the healthy scenario
random_value() { head -c 24 /dev/urandom | base64 | tr -d '/+=\n'; }
digest_of() { printf '%s' "$1" | sha256sum | cut -d ' ' -f 1; }
secret_songmaker="$(random_value)" secret_presentator="$(random_value)" secret_master="$(random_value)"
secret_agent="$(random_value)" private_key="$(random_value)"
# What no output may hold: the planted secrets, their digests and the realm key's private part.
planted_values=("$secret_songmaker" "$secret_presentator" "$secret_master" "$secret_agent" "$private_key"
  "$(digest_of "$secret_songmaker")" "$(digest_of "$secret_presentator")" "$(digest_of "$secret_agent")")

# copy_table <directory> <table> <columns>: a COPY stream, the rows on stdin with " | " between the fields.
copy_table() {
  { printf 'COPY public.%s (%s) FROM stdin;\n' "$2" "$3"; sed 's/ | /\t/g'; printf '\\.\n'; } >"$1/$2"
}
copy_escape() { sed -e 's/\\/\\\\/g' <<<"$1"; }
# store_profile <directory> <profile json>: the component_config of the user-profile component, the profile in its one value,
# beside the realm key's private part, which the gate never prints.
store_profile() {
  {
    printf 'COPY public.component_config (id, component_id, name, value) FROM stdin;\n'
    printf 'cfg-profile\tcomp-profile\tkc.user.profile.config\t%s\n' "$(copy_escape "$2")"
    printf 'cfg-key\tcomp-rsa\tprivateKey\t%s\n' "$private_key"
    printf '\\.\n'
  } >"$1/component_config"
}
expected_profile="$(yq -o json -I0 '.userProfile | del(.attributes[] | select(.name == "agent_owner"))' \
  "$repository_root/infrastructure/keycloak/realm.yaml")"
# The dump stores the file's profile, compact and with Keycloak's default written out on one attribute.
stored_profile="$(jq -c '.attributes |= map(if .name == "email" then .multivalued = false else . end)' <<<"$expected_profile")"

build_base() {
  mkdir -p "$base/dump-tables" "$base/live-tables" "$base/http" "$base/fail"
  printf '%s\n' "realm-hall | $realm" 'realm-master | master' | copy_table "$base/dump-tables" realm 'id, name'
  printf '%s\n' "c-songmaker | songmaker | realm-hall | $secret_songmaker" "c-presentator | presentator | realm-hall | $secret_presentator" \
    'c-public | hopin-web | realm-hall | \N' "c-master | admin-cli | realm-master | $secret_master" |
    copy_table "$base/dump-tables" client 'id, client_id, realm_id, secret'
  copy_table "$base/dump-tables" client_scope 'id, name, realm_id' <<'ROWS'
s-profile | profile | realm-hall
s-email | email | realm-hall
ROWS
  # A group that carries a platform-only name below another group is no top-level group of that name.
  copy_table "$base/dump-tables" keycloak_group 'id, name, parent_group, realm_id' <<'ROWS'
g-apps | apps | \N | realm-hall
g-services | services | \N | realm-hall
g-nested | agents | g-apps | realm-hall
ROWS
  copy_table "$base/dump-tables" user_entity 'id, username, realm_id, service_account_client_link' <<'ROWS'
u-alice | alice | realm-hall | \N
u-bob | bob | realm-hall | \N
ROWS
  copy_table "$base/dump-tables" credential 'id, user_id, type' <<'ROWS'
cred-alice | u-alice | password
cred-bob | u-bob | password
ROWS
  copy_table "$base/dump-tables" user_group_membership 'group_id, user_id' <<'ROWS'
g-apps | u-alice
g-services | u-bob
ROWS
  copy_table "$base/dump-tables" user_attribute 'id, name, value, user_id' <<'ROWS'
ua-1 | locale | de | u-alice
ROWS
  copy_table "$base/dump-tables" component 'id, name, parent_id, provider_id, provider_type, realm_id, sub_type' <<'ROWS'
comp-profile | declarative-user-profile | realm-hall | declarative-user-profile | org.keycloak.userprofile.UserProfileProvider | realm-hall | \N
comp-rsa | rsa-generated | realm-hall | rsa-generated | org.keycloak.keys.KeyProvider | realm-hall | \N
ROWS
  store_profile "$base/dump-tables" "$stored_profile"
  # After config-cli the database holds the dump's rows and the service account of a declared client, with its membership.
  for table in user_entity credential user_group_membership user_attribute; do cp "$base/dump-tables/$table" "$base/live-tables/$table"; done
  append_live_row user_entity 'u-agent | service-account-agent-mozart | realm-hall | c-agent'
  append_live_row user_group_membership 'g-services | u-agent'
  echo u-agent >"$base/live-service-accounts"
  echo 0 >"$base/temporary-count"
  cp "$base/dump-tables/realm" "$base/dump-tables/client" "$base/live-tables/"
  append_live_row client "c-agent | agent-mozart | realm-hall | $secret_agent"
  jq -n '{spec: {backoffLimit: 6}, status: {failed: 1, conditions: [{type: "Complete", status: "True"}]}}' >"$base/job.json"
  echo group-admin-id >"$base/admin-group-id"
  printf 'u-alice\nu-bob\nu-carol\n' >"$base/admin-members"
  head -c 64 /dev/urandom >"$base/dump.bin"
  printf 'issuer %s\nkid kid-a\nkid kid-b\nhal-main %s\nplatform %s\nread-at 2026-11-09T08:00:00Z\n' \
    "$issuer" "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" >"$base/evidence"
}

# ------------------------------------------------------------- running cases
export MISE_DISABLE_TOOLS=kubectl,flux,flux2,gh KUBECONFIG=/nonexistent
# script_env <command>...: the environment the script inherits, with the fakes first on PATH.
script_env() {
  env HOME="$case_directory" PATH="$fake_bin:$PATH" FAKE_SCENARIO="$case_directory" FAKE_STATE="$case_directory/state" \
    FAKE_LOG="$case_directory/log" FAKE_LIB="$work_directory/fake_lib.sh" FAKE_FORWARD_PORT="$forward_port" \
    FAKE_CONTAINER_BIN="$container_bin" FAKE_POSTGRES_CHECKS="$postgres_checks/" FAKE_DUMP="$case_directory/dump.bin" \
    FAKE_EVIDENCE_DIRECTORY="$case_directory" "$@"
}
new_case() {
  case_directory="$work_directory/cases/$1"
  case_name="$1"
  mkdir -p "$work_directory/cases"
  cp -a "$base" "$case_directory"
  dump="$case_directory/dump.bin" evidence="$case_directory/evidence"
}
# add_row / append_live_row <table> <row>: a row, with " | " between the fields, before the end of the table's stream.
add_row_to() {
  local file="$1/$2"
  head -n -1 "$file" >"$file.new"
  printf '%s\n' "${3// | /$'\t'}" >>"$file.new"
  printf '\\.\n' >>"$file.new"
  mv "$file.new" "$file"
}
add_row() { add_row_to "$case_directory/dump-tables" "$1" "$2"; }
append_live_row() { add_row_to "$base/live-tables" "$1" "$2"; }
drop_rows() { grep -v -- "$2" "$case_directory/dump-tables/$1" >"$case_directory/dump-tables/$1.new" && mv "$case_directory/dump-tables/$1.new" "$case_directory/dump-tables/$1"; }
set_profile() { store_profile "$case_directory/dump-tables" "$1"; }
# serve <url>: what the fake curl answers for it; the body is stdin.
serve() { cat >"$case_directory/http/$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' _)"; }
fail_url() { touch "$case_directory/http/$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' _).fail"; }
discovery_url="http://127.0.0.1:$forward_port/realms/$realm/.well-known/openid-configuration"
certs_url="http://127.0.0.1:$forward_port/realms/$realm/protocol/openid-connect/certs"
serve_copy() {
  serve "$discovery_url" <<<"{\"issuer\":\"$issuer\"}"
  serve "$certs_url" <<<'{"keys":[{"kid":"kid-b"},{"kid":"kid-a"}]}'
}
serve_public() {
  serve "$issuer/.well-known/openid-configuration" <<<"{\"issuer\":\"$issuer\",\"jwks_uri\":\"$issuer/protocol/openid-connect/certs\"}"
  serve "$issuer/protocol/openid-connect/certs" <<<'{"keys":[{"kid":"kid-b"},{"kid":"kid-a"}]}'
}

# What the scripts must not hold, outside comments: a PATH assignment, command -p, and an absolute, $HOME or ~ path in command
# position (after a line start, a separator, a keyword, exec or timeout), which would bypass the fakes; a slash that opens
# an awk regular expression is none. The commands' own script also must not run env, which the copy check's command line
# for the container does.
path_pattern='(^|[^A-Za-z_])PATH=|command[[:space:]]+-p|(^|[;&|!{]|\$\(|[[:space:]](then|do|else|exec|timeout [0-9]+))[[:space:]]*"?(/[A-Za-z]|\$HOME|\$\{HOME|~)'
env_pattern='(^|[;&|!{]|\$\(|[[:space:]](then|do|else|exec))[[:space:]]*env[[:space:]]'
# logs_clean [<tree>]: every call was one of the contract's, from the fakes first on PATH by bare name, and none of the
# tree's scripts could bypass them.
logs_clean() {
  local tree="${1:-$repository_root}" file
  [ ! -s "$case_directory/log/refused" ] || { reason="a call was refused: $(head -n 1 "$case_directory/log/refused")"; return 1; }
  if [ -f "$case_directory/log/path" ] && grep -qvxE "$fake_bin|$container_bin" "$case_directory/log/path"; then
    reason="a fake ran with another first PATH entry: a script changed PATH"
    return 1
  fi
  [ ! -s "$case_directory/log/git" ] || { reason="git was called"; return 1; }
  grep -vE '^[[:space:]]*#' "$tree/scripts/cutover_load.sh" | grep -qE "$env_pattern" &&
    { reason="the script runs env, which would bypass the fakes"; return 1; }
  for file in scripts/cutover_load.sh scripts/keycloak_kcadm.sh tests/keycloak/restored_copy_keeps_its_keys_and_people.sh; do
    grep -vE '^[[:space:]]*#' "$tree/$file" | grep -qE "$path_pattern" &&
      { reason="$file assigns PATH, uses command -p or calls an executable by an absolute, \$HOME or ~ path"; return 1; }
  done
  return 0
}
output_clean() {
  local value
  for value in "${planted_values[@]}"; do
    ! grep -qF -- "$value" <<<"$output" || { reason="the output holds a planted secret, digest or key"; return 1; }
  done
}
# run_script <script> <argument>...: sets status and output, stdout and stderr together.
run_script() {
  local script_under_test="$1"
  shift
  rm -rf "$case_directory/log" "$case_directory/state"
  mkdir "$case_directory/log" "$case_directory/state"
  status=0
  output="$(script_env "$script_under_test" "$@" 2>&1)" || status=$?
}
run_case() {
  run_script "$script" "$@"
  logs_clean || fail "$case_name: $reason"
  output_clean || fail "$case_name: $reason: $output"
}
run_load() { run_case load "$dump" "$evidence"; }
expect_status() { [ "$status" = "$1" ] || fail "$case_name: exit $status, not $1: $output"; }
expect_line() { grep -qE "$1" <<<"$output" || fail "$case_name: no line matches '$1' in: $output"; }
expect_no_line() { ! grep -qE "$1" <<<"$output" || fail "$case_name: a line matches '$1' in: $output"; }
empty_logs() {
  [ -z "$(find "$case_directory/log" -type f -size +0)" ] || fail "$case_name: a fake was called: $(find "$case_directory/log" -type f -size +0)"
}
event() { grep -nE -m 1 -- "$1" "$case_directory/log/events" | cut -d : -f 1; }
calls_of() { cat "$case_directory/log/$1" 2>/dev/null || true; }
# refused_before_the_load <pattern>: the run ended at exit 1 naming the finding, with `nothing loaded` and no mise call.
refused_before_the_load() {
  expect_status 1
  expect_line "$1"
  expect_line '; nothing loaded$'
  [ ! -e "$case_directory/log/mise" ] || fail "$case_name: a mise call after a refusal: $(calls_of mise)"
}

build_base

# ------------------------------------------------------ interception
new_case interception
serve_copy
for tool in kubectl mise curl flux gh git date; do
  [ "$(script_env bash -c 'command -v "$1"' _ "$tool")" = "$fake_bin/$tool" ] || fail "$tool does not resolve to its fake in the script's environment"
done
[ "$KUBECONFIG" = /nonexistent ] || fail "KUBECONFIG is not /nonexistent"

# ------------------------------------------------------ case 1: healthy, in every stored form of the profile
new_case healthy
serve_copy
run_load
expect_status 0
expect_line '^cutover:load: the gate passed'
expect_line "^key ids of $realm: copy kid-a kid-b, evidence kid-a kid-b, equal\$"
for table in user_entity credential user_group_membership user_attribute; do expect_line "^$table: .*, equal\$"; done
expect_line '^1 service accounts of declared clients were added since the dump'
expect_line '^songmaker: client secret equal$'
expect_line '^presentator: client secret equal$'
expect_line '^agent-mozart: client secret not in the dump, not compared$'
expect_no_line 'DIFFERS'
expect_no_line 'admin-cli|hopin-web'
expect_line '^cutover:load: /services/litellm/admin: 3 members$'
expect_line '^keycloak:move-group: /services/agent-service/api: 3 members; /services/litellm: 5 members'
expect_line '^cutover:load: the copy holds hal.s issuer, key ids, people, memberships and client secrets; 3 members in /services/agent-service/api moved to /services/litellm$'
load_line="$(event '^mise run db:load-dump')" job_line="$(event 'get job config-cli')" admin_line="$(event 'kcadm.sh get group-by-path/services/litellm/admin')"
move_line="$(event '^mise run keycloak:move-group')" first_restore="$(event '^pg_restore')"
[ "$first_restore" -lt "$load_line" ] && [ "$load_line" -lt "$job_line" ] && [ "$job_line" -lt "$admin_line" ] && [ "$admin_line" -lt "$move_line" ] ||
  fail "healthy: the calls are out of order: $(cat "$case_directory/log/events")"
[ -z "$(head -n "$((load_line - 1))" "$case_directory/log/events" | grep -vE '^(kubectl .* exec --stdin postgres-0 |pg_restore )')" ] ||
  fail "healthy: a call other than the gate's read of the dump came before the load"
[ "$(wc -l <"$case_directory/log/mise")" = 2 ] || fail "healthy: mise ran other than the load and the move: $(calls_of mise)"
grep -q 'config-removed' <(ls "$case_directory/state") || fail "healthy: kcadm's sign-in file was not removed"
first_file="$(grep -o 'keycloak-before-move-group-[0-9TZ]*\.dump' "$case_directory/log/mise")"
run_load
expect_status 0
second_file="$(grep -o 'keycloak-before-move-group-[0-9TZ]*\.dump' "$case_directory/log/mise")"
[ -n "$first_file" ] && [ "$first_file" != "$second_file" ] || fail "healthy: a rerun used the same move-group file: $first_file, $second_file"

new_case last-line-without-newline
serve_copy
touch "$case_directory/no-newline"
run_load
expect_status 0
expect_line '^db:load-dump: a last line without a newline$'

# ------------------------------------------------------ case 2: the profile, each difference named alone
# profile_case <name> <jq program on the stored profile> <the one finding>
profile_case() {
  new_case "profile-$1"
  serve_copy
  set_profile "$(jq -c "$2" <<<"$stored_profile")"
  run_load
  refused_before_the_load "^cutover:load: profile $3\$"
  [ "$(grep -c '^cutover:load: profile ' <<<"$output")" = 1 ] || fail "$case_name: another difference was named: $output"
}
profile_case extra-attribute '.attributes += [{name: "nickname"}]' 'attribute nickname is extra'
profile_case changed-attribute '(.attributes[] | select(.name == "email") | .validations.length.max) = 100' 'attribute email is different'
profile_case missing-attribute 'del(.attributes[] | select(.name == "lastName"))' 'attribute lastName is missing'
profile_case agent-owner '.attributes += [{name: "agent_owner", multivalued: false, permissions: {view: ["admin"], edit: ["admin"]}}]' 'attribute agent_owner is extra'
profile_case extra-key '. + {unmanagedAttributePolicy: "ENABLED"}' 'key unmanagedAttributePolicy is extra'
profile_case missing-group 'del(.groups)' 'group user-metadata is missing'

# ------------------------------------------------------ case 3: each platform-only object, alone
object_case() {
  new_case "object-$1-$2"
  serve_copy
  add_row "$3" "$4"
  run_load
  refused_before_the_load "^cutover:load: the dump holds $1 $2, which only realm.yaml declares\$"
  [ "$(grep -c '^cutover:load: the dump holds ' <<<"$output")" = 1 ] || fail "$case_name: another object was named: $output"
}
object_case client agent-mozart client 'c-agent | agent-mozart | realm-hall | \N'
object_case user service-account-agent-mozart user_entity 'u-sa | service-account-agent-mozart | realm-hall | c-agent'
object_case scope agent-identity client_scope 's-agent | agent-identity | realm-hall'
object_case group agents keycloak_group 'g-agents | agents | \N | realm-hall'
object_case group agent-adders keycloak_group 'g-adders | agent-adders | \N | realm-hall'
object_case group agent-owners keycloak_group 'g-owners | agent-owners | \N | realm-hall'
# The same names in the realm master are no object of the realm.
new_case object-in-another-realm
serve_copy
add_row client 'c-other | agent-mozart | realm-master | \N'
run_load
expect_status 0

# ------------------------------------------------------ case 4: a dump the gate cannot read refuses
new_case no-profile-component-config
serve_copy
grep -v 'cfg-profile' "$case_directory/dump-tables/component_config" >"$case_directory/x" && mv "$case_directory/x" "$case_directory/dump-tables/component_config"
run_load
refused_before_the_load "^cutover:load: the dump holds no readable user profile of realm $realm\$"
new_case no-profile-component
serve_copy
drop_rows component 'comp-profile'
run_load
refused_before_the_load "^cutover:load: the dump holds no readable user profile of realm $realm\$"
# More than one storage form or value is no readable profile, whatever it holds: the gate never picks one.
unreadable_profile_case() {
  new_case "$1"
  serve_copy
  "$2"
  run_load
  refused_before_the_load "^cutover:load: the dump holds no readable user profile of realm $realm\$"
}
pieces_only() {
  drop_rows component_config cfg-profile
  add_row component_config "cfg-piece-0 | comp-profile | config-piece-0 | $(copy_escape "$stored_profile")"
  add_row component_config 'cfg-count | comp-profile | config-pieces-count | 1'
}
whole_and_pieces() { add_row component_config "cfg-piece-0 | comp-profile | config-piece-0 | $(copy_escape "$expected_profile")"; }
whole_twice() { add_row component_config "cfg-twice | comp-profile | kc.user.profile.config | $(copy_escape "$expected_profile")"; }
two_components() { add_row component 'comp-profile-2 | declarative-user-profile | realm-hall | declarative-user-profile | org.keycloak.userprofile.UserProfileProvider | realm-hall | \N'; }
unreadable_profile_case profile-in-pieces-only pieces_only
unreadable_profile_case profile-whole-and-pieces whole_and_pieces
unreadable_profile_case profile-whole-twice whole_twice
unreadable_profile_case profile-two-components two_components
new_case no-realm
serve_copy
drop_rows realm "$realm"
run_load
refused_before_the_load "^cutover:load: the dump holds no realm $realm\$"
new_case pg_restore-fails
serve_copy
touch "$case_directory/fail/pg_restore"
run_load
refused_before_the_load '^cutover:load: reading the dump through Keycloak.s Postgres failed; nothing loaded$'

# ------------------------------------------------------ case 5: the load fails
new_case load-fails
serve_copy
touch "$case_directory/fail/mise-load"
run_load
expect_status 1
expect_line '^db:load-dump: the load failed$'
expect_line "the way back is the operator's cd ~/srv/hal && hal start keycloak\$"
expect_no_line 'the copy is loaded'
[ "$(wc -l <"$case_directory/log/mise")" = 1 ] || fail "load-fails: mise ran after the failed load"
[ "$(wc -l <"$case_directory/log/kubectl")" = 1 ] || fail "load-fails: kubectl ran after the failed load: $(calls_of kubectl)"

# ------------------------------------------------------ case 6: the copy against the dump and the evidence
copy_case() {
  new_case "copy-$1"
  serve_copy
  "$2"
  run_load
  expect_status 1
  expect_line "$3"
  expect_line "the way back is the operator's cd ~/srv/hal && hal start keycloak\$"
  [ "$(wc -l <"$case_directory/log/mise")" = 1 ] || fail "$case_name: the move ran: $(calls_of mise)"
}
config_cli_incomplete() { jq '.status.conditions = []' "$case_directory/job.json" >"$case_directory/x" && mv "$case_directory/x" "$case_directory/job.json"; }
other_key_id() { serve "$certs_url" <<<'{"keys":[{"kid":"kid-a"},{"kid":"kid-c"}]}'; }
other_issuer() { serve "$discovery_url" <<<'{"issuer":"https://other.example.test/realms/x"}'; }
other_table() { sed -i 's/cred-bob\tu-bob\tpassword/cred-bob\tu-bob\tpassword2/' "$case_directory/live-tables/credential"; }
temporary_administrator() { echo 2 >"$case_directory/temporary-count"; }
copy_case config-cli-incomplete config_cli_incomplete "config-cli.s Job has not completed"
copy_case other-key-id other_key_id "^key ids of $realm: .*DIFFERS\$"
copy_case other-issuer other_issuer "^issuer of $realm: copy https://other.example.test/realms/x, evidence $issuer, DIFFERS\$"
copy_case other-table other_table '^credential: .*DIFFERS$'
copy_case temporary-administrator temporary_administrator 'are temporary administrators: DIFFERS'

# ------------------------------------------------------ case 7: a client secret
secret_case() {
  new_case "secret-$1"
  serve_copy
  "$2"
  run_load
  expect_status 1
  expect_line "^$3: client secret DIFFERS\$"
  expect_line '^cutover:load: the check of the copy against the dump and the evidence exited 1'
  [ "$(wc -l <"$case_directory/log/mise")" = 1 ] || fail "$case_name: the move ran"
}
other_secret() { sed -i "s/\t$secret_songmaker\$/\t$(random_value)/" "$case_directory/live-tables/client"; }
missing_client() { sed -i '/\tpresentator\t/d' "$case_directory/live-tables/client"; }
secret_case differs other_secret songmaker
secret_case client-missing missing_client presentator
# A secret whose stored text holds an escaped newline or ends in one is compared as stored and never printed in part.
planted_values+=(LEAKEDTAILVALUE OTHERTAILVALUE)
secret_text_case() {
  new_case "secret-text-$1"
  serve_copy
  sed -i "s/\t$secret_songmaker\$/\t$2/" "$case_directory/dump-tables/client"
  sed -i "s/\t$secret_songmaker\$/\t$3/" "$case_directory/live-tables/client"
  run_load
  expect_status "$4"
  if [ "$4" = 0 ]; then expect_line '^songmaker: client secret equal$'; else expect_line '^songmaker: client secret DIFFERS$'; fi
  [ "$(grep -c 'client secret DIFFERS' <<<"$output")" = "$4" ] || fail "$case_name: another client was named: $output"
}
secret_text_case newline-equal 'firstpart\\nLEAKEDTAILVALUE' 'firstpart\\nLEAKEDTAILVALUE' 0
secret_text_case newline-differs 'firstpart\\nLEAKEDTAILVALUE' 'firstpart\\nOTHERTAILVALUE' 1
secret_text_case trailing-newline-equal 'abc\\n' 'abc\\n' 0
secret_text_case trailing-newline-differs 'abc\\n' 'abc' 1
new_case secret-none-in-the-dump
serve_copy
sed -i 's/\t'"$secret_songmaker"'$/\t\\N/; s/\t'"$secret_presentator"'$/\t\\N/' "$case_directory/dump-tables/client"
run_load
expect_status 1
expect_line 'the dump holds no client secret of .*DIFFERS'

# ------------------------------------------------------ cases 8 and 9: the admin group and the move
new_case admin-group-missing
serve_copy
rm "$case_directory/admin-group-id"
run_load
expect_status 1
expect_line "^cutover:load: $realm holds no /services/litellm/admin or Keycloak cannot be read"
[ ! -e "$case_directory/log/mise" ] || [ "$(wc -l <"$case_directory/log/mise")" = 1 ] || fail "admin-group-missing: the move ran"
new_case move-fails
serve_copy
touch "$case_directory/fail/mise-move"
run_load
expect_status 1
expect_line '^keycloak:move-group: a member could not join'
expect_line "the way back is the operator's cd ~/srv/hal && hal start keycloak\$"

# ------------------------------------------------------ case 10: usage errors end at exit 2 before any call
expect_usage() { expect_status 2; expect_line 'usage: '; empty_logs; }
new_case usage-no-argument
run_case load
expect_usage
new_case usage-no-evidence
run_case load "$dump"
expect_usage
new_case usage-no-command
run_case
expect_usage
new_case usage-unknown-command
run_case copy "$dump"
expect_usage
new_case usage-dump-is-a-directory
run_case load "$case_directory/dump-tables" "$evidence"
expect_status 2
empty_logs
new_case usage-no-issuer
grep -v '^issuer ' "$evidence" >"$case_directory/x" && mv "$case_directory/x" "$evidence"
run_load
expect_status 2
empty_logs
new_case usage-two-issuers
echo "issuer https://other.example.test" >>"$evidence"
run_load
expect_status 2
empty_logs
new_case usage-no-kid
grep -v '^kid ' "$evidence" >"$case_directory/x" && mv "$case_directory/x" "$evidence"
run_load
expect_status 2
empty_logs
new_case usage-unknown-key
echo "token not-a-key-of-the-evidence" >>"$evidence"
run_load
expect_status 2
expect_no_line 'not-a-key-of-the-evidence'
empty_logs
new_case usage-check-no-evidence-file
run_case check "$case_directory/absent"
expect_status 2
empty_logs

# ------------------------------------------------------ case 11: cutover:check
new_case check-equal
serve_public
run_case check "$evidence"
expect_status 0
expect_line "^cutover:check: issuer: public $issuer, evidence $issuer, equal\$"
expect_line '^cutover:check: key ids: public kid-a kid-b, evidence kid-a kid-b, equal$'
check_case() {
  new_case "check-$1"
  serve_public
  "$2"
  run_case check "$evidence"
  expect_status 1
  expect_line "$3"
}
public_other_key() { serve "$issuer/protocol/openid-connect/certs" <<<'{"keys":[{"kid":"kid-a"},{"kid":"kid-c"}]}'; }
public_other_issuer() { serve "$issuer/.well-known/openid-configuration" <<<"{\"issuer\":\"https://other.example.test\",\"jwks_uri\":\"$issuer/protocol/openid-connect/certs\"}"; }
public_discovery_fails() { fail_url "$issuer/.well-known/openid-configuration"; }
public_keys_fail() { fail_url "$issuer/protocol/openid-connect/certs"; }
check_case other-key-id public_other_key '^cutover:check: key ids: public kid-a kid-c, evidence kid-a kid-b, DIFFERS$'
check_case other-issuer public_other_issuer "^cutover:check: issuer: public https://other.example.test, evidence $issuer, DIFFERS\$"
check_case discovery-fails public_discovery_fails '^cutover:check: the discovery of .* cannot be read$'
check_case keys-fail public_keys_fail '^cutover:check: the key set at .* cannot be read$'
[ ! -e "$case_directory/log/mise" ] && [ ! -e "$case_directory/log/kubectl" ] || fail "check: it called mise or kubectl"

# ------------------------------------------------------ planted forbidden calls turn the cell red
# plant <label> <file in the tree> <line>...: a scratch copy of the tree's scripts in which the file makes the calls right
# after its anchor line (`set -euo pipefail`, or the first line of the kcadm library's code, or plant_anchor), run on the
# healthy scenario.
plant() {
  local label="$1" file="$2" tree="$work_directory/planted-$1" copied line anchor="${plant_anchor:-set -euo pipefail}"
  shift 2
  [ "$file" != scripts/keycloak_kcadm.sh ] || anchor='kcadm_path=/opt/keycloak/bin/kcadm.sh'
  mkdir -p "$tree/scripts" "$tree/tests/keycloak" "$tree/infrastructure/keycloak"
  cp -p "$repository_root/scripts/cutover_load.sh" "$repository_root/scripts/keycloak_kcadm.sh" "$tree/scripts/"
  cp -p "$repository_root/tests/keycloak/restored_copy_keeps_its_keys_and_people.sh" "$tree/tests/keycloak/"
  cp -p "$repository_root/tests/failure.sh" "$tree/tests/"
  cp -p "$repository_root/infrastructure/keycloak/realm.yaml" "$tree/infrastructure/keycloak/"
  copied="$tree/$file"
  {
    while IFS= read -r line; do
      printf '%s\n' "$line"
      [ "$line" != "$anchor" ] || printf '%s\n' "$@"
    done <"$repository_root/$file"
  } >"$copied.new"
  mv "$copied.new" "$copied"
  chmod +x "$copied"
  new_case "planted-$label"
  serve_copy
  run_script "$tree/scripts/cutover_load.sh" load "$dump" "$evidence"
  if logs_clean "$tree"; then fail "planted $label: the cell stayed green"; fi
  echo "planted $label turns the cell red: $reason"
}
cutover_load=scripts/cutover_load.sh restored_copy=tests/keycloak/restored_copy_keeps_its_keys_and_people.sh
plant gate-connects "$cutover_load" 'kubectl --namespace keycloak exec --stdin postgres-0 --container postgres -- pg_restore --data-only --table=realm --dbname=keycloak </dev/null || true'
plant scale-before-the-load "$cutover_load" 'kubectl --namespace keycloak scale deployment keycloak --replicas=0 || true'
plant write-before-the-load "$cutover_load" 'kubectl --namespace keycloak exec postgres-0 --container postgres -- psql --command="SELECT 1" || true'
plant delete-old "$cutover_load" 'mise run keycloak:move-group --delete-old "$PWD/x.dump" || true'
plant kcadm-write "$cutover_load" 'kubectl --namespace keycloak exec deployment/keycloak --container keycloak -- /opt/keycloak/bin/kcadm.sh delete groups/x || true'
plant absolute-path "$cutover_load" '/usr/bin/true'
plant changed-path "$cutover_load" 'PATH="/usr/sbin:$PATH"; kubectl --version || true'
plant git-call "$cutover_load" 'git status || true'
plant public-fetch-in-the-copy-check "$restored_copy" "curl --silent --fail --max-time 20 $issuer/.well-known/openid-configuration || true"
plant curl-post-in-the-copy-check "$restored_copy" "curl --silent --request POST $discovery_url || true"
plant absolute-path-in-the-copy-check "$restored_copy" '/usr/bin/curl --silent http://127.0.0.1:1 || true'
plant absolute-path-in-the-kcadm-library scripts/keycloak_kcadm.sh '/usr/bin/true'
plant_anchor='  phase=after_load' plant psql-two-statements "$cutover_load" 'kubectl --namespace keycloak exec postgres-0 --container postgres -- env PGCONNECT_TIMEOUT=10 psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 "--command=SELECT 1; DELETE FROM client" || true'
plant_anchor='  phase=after_load' plant other-program-after-the-load "$cutover_load" 'kubectl --namespace keycloak exec postgres-0 --container postgres -- rm -rf /var/lib/postgresql || true'
plant env-in-the-script "$cutover_load" 'env FOO=1 true'

echo "cutover:load and cutover:check name each difference and print no value: profile, objects, unreadable dumps, load, copy, secrets, admin group, move, usage, check, interception and read-only held"
