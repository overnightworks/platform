#!/usr/bin/env bash
# Drive scripts/cloudflare_adoption_check.sh against synthetic plan JSON, as `tofu show -json` gives it: while the plan
# imports any object (the adoption, a half-finished one included), it passes only without a create or a delete, with
# every imported ruleset and setting at no-op, at most one update, the content of the record www, and every declared
# object the state does not hold among the imports; every other plan fails naming each offending address with its action
# and no value. A plan that cannot be read, an empty one included, fails. A plan without any import is a later plan, to
# which the adoption rules do not apply, which needs a prior state that already holds zone objects, and in which the
# update or the creation of a ruleset or a setting needs --allow-ruleset-update.
# Usage: tests/cloudflare/adoption_plan_is_exactly_the_imports_and_at_most_the_www_content.sh
# Proves docs/cloudflare-zone.md: the adoption check and the ruleset update flag.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${repository_root}/scripts/cloudflare_adoption_check.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT

# The plan of an adoption of three records, three rulesets and two settings, all at no-op; every id, address and value is invented, the
# secret value stands where a real plan holds the zone's own ids.
baseline="$(dirname "${BASH_SOURCE[0]}")/fixtures/adoption_plan.json"
secret_value=synthetic-secret-value

www='cloudflare_dns_record.host["www.example.test"]'
a_record='cloudflare_dns_record.host["a.example.test"]'
deny='cloudflare_ruleset.deny_public'
transform='cloudflare_ruleset.client_address'

# Each mutation turns the baseline into the plan of the case; $www, $a, $deny and $ruleset are the addresses above, and
# $ruleset is the one the case is about.
ruleset_address="${deny}"
update_www='(.resource_changes[] | select(.address == $www) | .change) |= (.actions = ["update"] | .after.content = "other-tunnel.cfargotunnel.com" | .after_unknown.modified_on = true)'
# A plan of a state that holds the objects: nothing is an import any more, and the plan's prior state lists every
# object, as `tofu show -json` prints it.
adopted="$(<"$(dirname "${BASH_SOURCE[0]}")/fixtures/adopted_plan.jq")"
ruleset_update="${adopted}"' | (.resource_changes[] | select(.address == $ruleset) | .change.actions) = ["update"]'

# case_of <name> <jq program over the baseline> <status> <text the output holds>...: the output never holds a value.
check_arguments=()
case_of() {
  local name="$1" mutation="$2" expected_status="$3" plan="${work_directory}/plan.json" text
  shift 3
  jq --arg www "${www}" --arg a "${a_record}" --arg deny "${deny}" --arg ruleset "${ruleset_address}" "${mutation}" "${baseline}" >"${plan}"
  check_status=0
  check_output="$("${check}" "${check_arguments[@]}" <"${plan}" 2>&1)" || check_status=$?
  echo "${name}: status ${check_status}"
  [ "${check_status}" -eq "${expected_status}" ] || fail "${name}: status ${check_status}, not ${expected_status}: ${check_output}"
  for text in "$@"; do
    grep -qF -- "${text}" <<<"${check_output}" || fail "${name}: the output does not hold '${text}': ${check_output}"
  done
  ! grep -qF -- "${secret_value}" <<<"${check_output}" || fail "${name}: the output holds a value of the plan"
}

# The pass: eight imports at no-op, listed with their counts and addresses.
case_of "adoption of every object" '.' 0 "8 imports" "8 no-op" "0 update" "${www}" "module.settings.cloudflare_zone_setting.hsts"
case_of "adoption with the content of www updated" "${update_www}" 0 "1 update" "content" "${www} import update"

# Each stop names the offending address and its action.
case_of "a create of a record" '(.resource_changes[] | select(.address == $a) | .change) |= (.actions = ["create"] | .importing = null)' 1 "${a_record} create"
case_of "a delete" '.resource_changes += [{address: "cloudflare_dns_record.host[\"c.example.test\"]", mode: "managed", type: "cloudflare_dns_record", index: "c.example.test", change: {actions: ["delete"], importing: null, before: {}, after: null, after_unknown: {}}}]' 1 'cloudflare_dns_record.host["c.example.test"] delete'
case_of "a forget" '(.resource_changes[] | select(.address == $a) | .change) |= (.actions = ["forget"] | .importing = null)' 1 "${a_record} forget"
case_of "a replacement" '(.resource_changes[] | select(.address == $a) | .change) |= (.actions = ["delete", "create"] | .importing = null)' 1 "${a_record} delete,create"
case_of "a ruleset that is not at no-op" '(.resource_changes[] | select(.address == $deny) | .change) |= (.actions = ["update"] | .after.id = "changed")' 1 "${deny} update"
case_of "a setting that is not at no-op" '(.resource_changes[] | select(.address == "module.settings.cloudflare_zone_setting.nel") | .change.actions) = ["update"]' 1 "module.settings.cloudflare_zone_setting.nel update"
case_of "an update of a record other than www" '(.resource_changes[] | select(.address == $a) | .change) |= (.actions = ["update"] | .after.content = "other-tunnel.cfargotunnel.com")' 1 "${a_record} update"
case_of "a second update" "${update_www}"' | .resource_changes += [(.resource_changes[] | select(.address == $www) | .address = "cloudflare_dns_record.host[\"www.second.example.test\"]" | .index = "www.second.example.test")]' 1 'cloudflare_dns_record.host["www.second.example.test"] update' "second update"
case_of "an update of another field of www" "${update_www}"' | (.resource_changes[] | select(.address == $www) | .change.after.proxied) = false' 1 "${www} update" "proxied"
case_of "an update of www that sets a declared field unknown before apply" "${update_www}"' | (.resource_changes[] | select(.address == $www) | .change.after_unknown.ttl) = true' 1 "${www} update" "ttl"
case_of "a declared setting absent from the plan" 'del(.resource_changes[] | select(.address == "module.settings.cloudflare_zone_setting.hsts"))' 1 "module.settings.cloudflare_zone_setting.hsts" "declared" "no import"
case_of "one instance of a record without its import" 'del(.resource_changes[] | select(.address == $a))' 1 "${a_record}" "declared" "no import"
case_of "an import that no declaration plans" '.resource_changes += [{address: "cloudflare_ruleset.undeclared", mode: "managed", type: "cloudflare_ruleset", name: "undeclared", change: {actions: ["no-op"], importing: {id: "synthetic"}, before: {}, after: {}, after_unknown: {}}}]' 1 "cloudflare_ruleset.undeclared" "declared nowhere"
case_of "a plan without its planned values" 'del(.planned_values)' 1 "no planned values"
case_of "every declared ruleset absent from the plan" '.resource_changes |= map(select(.type != "cloudflare_ruleset"))' 1 "cloudflare_ruleset.client_address" "cloudflare_ruleset.deny_public" "cloudflare_ruleset.apex_redirect"
case_of "a plan without any change" '.resource_changes = []' 1 "declared" "no import"
case_of "a plan without its configuration" 'del(.configuration)' 1 "no configuration"

# A half-finished adoption: the records and settings are in the state (no-op, imported nowhere) and the rulesets are
# still imports. The adoption rules go on applying to it.
half_finished='.resource_changes |= map(if .type == "cloudflare_ruleset" then . else .change.importing = null end)'
case_of "a half-finished adoption that imports the rest" "${half_finished}" 0 "3 imports" "3 no-op" "${deny}"
case_of "a half-finished adoption with the content of www updated" "${half_finished}"' | (.resource_changes[] | select(.address == $www) | .change) |= (.actions = ["update"] | .after.content = "other-tunnel.cfargotunnel.com" | .after_unknown.modified_on = true)' 0 "1 update" "content" "${www}"
case_of "a half-finished adoption with a created record" "${half_finished}"' | (.resource_changes[] | select(.address == $a) | .change.actions) = ["create"]' 1 "${a_record} create"
case_of "a half-finished adoption with a deleted record" "${half_finished}"' | (.resource_changes[] | select(.address == $a) | .change.actions) = ["delete"]' 1 "${a_record} delete"
case_of "a half-finished adoption with an imported ruleset updated" "${half_finished}"' | (.resource_changes[] | select(.address == $deny) | .change.actions) = ["update"]' 1 "${deny} update"
case_of "a half-finished adoption with a ruleset of the state updated" "${half_finished}"' | (.resource_changes[] | select(.address == $deny) | .change) |= (.importing = null | .actions = ["update"])' 1 "${deny} update"
case_of "a half-finished adoption with a record of the state updated" "${half_finished}"' | (.resource_changes[] | select(.address == $a) | .change.actions) = ["update"]' 1 "${a_record} update"
case_of "a half-finished adoption with a setting of the state updated" "${half_finished}"' | (.resource_changes[] | select(.address == "module.settings.cloudflare_zone_setting.nel") | .change.actions) = ["update"]' 1 "module.settings.cloudflare_zone_setting.nel update"
case_of "a half-finished adoption without the import of a ruleset" "${half_finished}"' | del(.resource_changes[] | select(.address == $deny))' 1 "${deny}" "declared" "no import"

# Every offending address is named, not the first.
case_of "three creates" '.resource_changes |= map(if .type == "cloudflare_ruleset" then (.change.actions = ["create"] | .change.importing = null) else . end)' 1 \
  "cloudflare_ruleset.client_address create" "cloudflare_ruleset.deny_public create" "cloudflare_ruleset.apex_redirect create"

# Once the state holds the objects, the adoption rules do not apply: a created record and an updated record pass.
case_of "a new host after the adoption" "${adopted}"' | .resource_changes += [{address: "cloudflare_dns_record.host[\"new.example.test\"]", mode: "managed", type: "cloudflare_dns_record", index: "new.example.test", change: {actions: ["create"], importing: null, before: null, after: {}, after_unknown: {}}}]' 0 "prior state holds 8 zone objects"
case_of "no change after the adoption" "${adopted}" 0 "prior state holds 8 zone objects"
case_of "an update of a record after the adoption" "${adopted}"' | (.resource_changes[] | select(.address == $a) | .change.actions) = ["update"]' 0 "prior state holds 8 zone objects"

# A plan that imports nothing needs a prior state that holds zone objects: with an empty or lost state, or lookups that
# found nothing, the first write must be the adoption, whatever the plan creates.
created='.resource_changes |= map(.change.actions = ["create"] | .change.importing = null)'
case_of "every object created with no prior state" "${created}" 1 "the first write must be the adoption" "prior state"
case_of "every object created with a prior state without a resource" "${created}"' | .prior_state = {format_version: "1.0", values: {root_module: {}}}' 1 "the first write must be the adoption"
case_of "every object created with a prior state of another provider only" "${created}"' | .prior_state = {values: {root_module: {resources: [{address: "terraform_data.other", mode: "managed", type: "terraform_data"}]}}}' 1 "the first write must be the adoption"
case_of "a prior state with an account-level Cloudflare resource only" "${created}"' | .prior_state = {values: {root_module: {resources: [{address: "cloudflare_zero_trust_tunnel_cloudflared.tunnel", mode: "managed", type: "cloudflare_zero_trust_tunnel_cloudflared"}]}}}' 1 "the first write must be the adoption"
check_arguments=(--allow-ruleset-update)
case_of "an account-level Cloudflare resource only with the flag" "${created}"' | .prior_state = {values: {root_module: {resources: [{address: "cloudflare_zero_trust_tunnel_cloudflared.tunnel", mode: "managed", type: "cloudflare_zero_trust_tunnel_cloudflared"}]}}}' 1 "the first write must be the adoption"
check_arguments=()
case_of "a prior state with a data source only" "${created}"' | .prior_state = {values: {root_module: {resources: [{address: "data.cloudflare_zone.zone", mode: "data", type: "cloudflare_zone"}]}}}' 1 "the first write must be the adoption"
check_arguments=(--allow-ruleset-update)
case_of "a prior state holding one setting in a child module only" "${created}"' | .prior_state = {values: {root_module: {child_modules: [{address: "module.settings", resources: [{address: "module.settings.cloudflare_zone_setting.nel", mode: "managed", type: "cloudflare_zone_setting"}]}]}}}' 0 "prior state holds 1 zone object;"
check_arguments=()
case_of "a prior state with objects and a created record" "${adopted}"' | (.resource_changes[] | select(.address == $a) | .change) |= (.actions = ["create"] | .before = null)' 0 "prior state holds 8 zone objects"
case_of "no change with no prior state" '.resource_changes |= map(.change.importing = null)' 1 "the first write must be the adoption"

# In a later plan the creation of a ruleset or a setting is refused like a ruleset update, unless the flag names it; a
# record may be created, which is how a host is added.
for created_address in "${deny}" "${transform}" "module.settings.cloudflare_zone_setting.nel"; do
  created_object="${adopted}"' | (.resource_changes[] | select(.address == "'"${created_address}"'") | .change) |= (.actions = ["create"] | .before = null)'
  check_arguments=()
  case_of "a creation of ${created_address} after the adoption" "${created_object}" 1 "${created_address} create" "--allow-ruleset-update"
  check_arguments=(--allow-ruleset-update)
  case_of "a creation of ${created_address} after the adoption with the flag" "${created_object}" 0 "${created_address} create"
  # The flag loosens nothing in the adoption.
  case_of "a creation of ${created_address} in the adoption with the flag" "${created_object}"' | (.resource_changes[] | select(.address == $a) | .change.importing) = {id: "synthetic"}' 1 "${created_address} create"
  check_arguments=()
done

# After the adoption an update of the deny or the transform ruleset needs the flag, whose name the refusal holds.
for ruleset_address in "${deny}" "${transform}"; do
  check_arguments=()
  case_of "an update of ${ruleset_address} after the adoption" "${ruleset_update}" 1 "${ruleset_address} update" "--allow-ruleset-update"
  check_arguments=(--allow-ruleset-update)
  case_of "an update of ${ruleset_address} after the adoption with the flag" "${ruleset_update}" 0 "${ruleset_address} update"
  # The flag loosens nothing in the adoption.
  case_of "an update of ${ruleset_address} in the adoption with the flag" '(.resource_changes[] | select(.address == $ruleset) | .change.actions) = ["update"]' 1 "${ruleset_address} update"
done
# A plan that cannot be read fails, whatever the flag: nothing, a blank, a document of no plan, text that is no JSON or a
# resource change without an address or without an action.
for flag in "" --allow-ruleset-update; do
  for unreadable in '' $'\n' '{}' 'null' '[]' '"plan"' '{"resource_changes":null}' '{"resource_changes":[]}' 'not json' \
    '{"resource_changes":[{"type":"cloudflare_dns_record","change":{"actions":[]}}]}' \
    '{"resource_changes":[{"address":"cloudflare_dns_record.host","type":"cloudflare_dns_record","change":{"actions":[]}}]}' \
    '{"resource_changes":[{"type":"cloudflare_dns_record","change":{"actions":["no-op"]}}]}' \
    '{"resource_changes":[{"address":"cloudflare_dns_record.host","type":"cloudflare_dns_record","change":{}}]}'; do
    unreadable_status=0
    unreadable_output="$(printf '%s' "${unreadable}" | "${check}" ${flag:+"${flag}"} 2>&1)" || unreadable_status=$?
    echo "unreadable plan '${unreadable}' with '${flag}': status ${unreadable_status}"
    [ "${unreadable_status}" -eq 1 ] || fail "unreadable plan '${unreadable}' with '${flag}': status ${unreadable_status}, not 1: ${unreadable_output}"
    ! grep -q "do not apply" <<<"${unreadable_output}" || fail "unreadable plan '${unreadable}' with '${flag}': it counts as a later plan: ${unreadable_output}"
  done
done
unreadable_status=0
"${check}" </dev/null >/dev/null 2>&1 || unreadable_status=$?
[ "${unreadable_status}" -eq 1 ] || fail "a closed stdin: status ${unreadable_status}, not 1"

check_arguments=(--unknown-flag)
case_of "an unknown flag" '.' 1 "usage"
