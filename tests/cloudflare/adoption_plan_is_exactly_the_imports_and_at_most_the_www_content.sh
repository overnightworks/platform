#!/usr/bin/env bash
# Drive scripts/cloudflare_adoption_check.sh against synthetic plan JSON, as `tofu show -json` gives it: while the plan
# holds no object the state already holds (the adoption), it passes only as an import of every declared record, ruleset
# and setting, each at no-op, with at most one update, the content of the record www; every other plan fails naming each
# offending address with its action and no value. Once the state holds the objects, the adoption rules do not apply and
# an update of a ruleset needs --allow-ruleset-update.
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
# A plan of a state that holds the objects: nothing is an import any more.
adopted='.resource_changes |= map(.change.importing = null)'
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
case_of "every declared ruleset absent from the plan" '.resource_changes |= map(select(.type != "cloudflare_ruleset"))' 1 "cloudflare_ruleset.client_address" "cloudflare_ruleset.deny_public" "cloudflare_ruleset.apex_redirect"
case_of "a plan without any change" '.resource_changes = []' 1 "declared" "no import"
case_of "a plan without its configuration" 'del(.configuration)' 1 "no configuration"

# Every offending address is named, not the first.
case_of "three creates" '.resource_changes |= map(if .type == "cloudflare_ruleset" then (.change.actions = ["create"] | .change.importing = null) else . end)' 1 \
  "cloudflare_ruleset.client_address create" "cloudflare_ruleset.deny_public create" "cloudflare_ruleset.apex_redirect create"

# Once the state holds the objects, the adoption rules do not apply: a created record and an updated record pass.
case_of "a new host after the adoption" "${adopted}"' | .resource_changes += [{address: "cloudflare_dns_record.host[\"new.example.test\"]", mode: "managed", type: "cloudflare_dns_record", index: "new.example.test", change: {actions: ["create"], importing: null, before: null, after: {}, after_unknown: {}}}]' 0 "state holds"
case_of "no change after the adoption" "${adopted}" 0 "state holds"
case_of "an update of a record after the adoption" "${adopted}"' | (.resource_changes[] | select(.address == $a) | .change.actions) = ["update"]' 0 "state holds"

# After the adoption an update of the deny or the transform ruleset needs the flag, whose name the refusal holds.
for ruleset_address in "${deny}" "${transform}"; do
  check_arguments=()
  case_of "an update of ${ruleset_address} after the adoption" "${ruleset_update}" 1 "${ruleset_address} update" "--allow-ruleset-update"
  check_arguments=(--allow-ruleset-update)
  case_of "an update of ${ruleset_address} after the adoption with the flag" "${ruleset_update}" 0 "${ruleset_address} update"
  # The flag loosens nothing in the adoption.
  case_of "an update of ${ruleset_address} in the adoption with the flag" '(.resource_changes[] | select(.address == $ruleset) | .change.actions) = ["update"]' 1 "${ruleset_address} update"
done
check_arguments=(--unknown-flag)
case_of "an unknown flag" '.' 1 "usage"
