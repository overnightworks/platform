#!/usr/bin/env bash
# Judge the Cloudflare root's plan, as `tofu show -json <plan>` prints it on stdin, before anything is applied.
# While the plan holds no object the state already holds (the adoption), it must be exactly an import of every declared
# object, each at no-op, with at most one update: the content of the record www. Once the state holds the objects the
# adoption rules do not apply, and an update of a ruleset stops unless --allow-ruleset-update names it.
# The output holds addresses, actions and attribute names, never a value of the plan.
# Usage: scripts/cloudflare_adoption_check.sh [--allow-ruleset-update] < plan.json
# Exit: 0 the plan passes, 1 it does not or the call is wrong.
set -euo pipefail

fail() {
  echo "cloudflare_adoption_check: $1" >&2
  exit 1
}

allow_ruleset_update=false
case "$#:${1:-}" in
  0:) ;;
  1:--allow-ruleset-update) allow_ruleset_update=true ;;
  *) fail "usage: scripts/cloudflare_adoption_check.sh [--allow-ruleset-update] < plan.json" ;;
esac
command -v jq >/dev/null || fail "jq is not installed"

# The state holds an object when the plan neither imports it nor creates it: it is at no-op or updated in place.
# (Resource instances that a delete, a forget or a replacement touches say nothing about the state in this judgement,
# so such a plan stays an adoption and stops on that action.)
judgement="$(jq --argjson allow "${allow_ruleset_update}" '
  def strip_index: gsub("\\[[^\\]]*\\]"; "");
  def actions_text: .change.actions | join(",");
  def declared($prefix; $module):
    [($module.resources // [])[] | select(.mode == "managed") | {address: ($prefix + .address), expressions: (.expressions | if . == null then null else keys end)}]
    + ([($module.module_calls // {}) | to_entries[] | declared($prefix + "module." + .key + "."; .value.module)] | add // []);
  # The attributes that differ: a known value that changes, or a declared attribute that becomes unknown. The provider
  # recomputes its own attributes (a modification time) on every update, which no file of ours declares.
  def changed_attributes($declared):
    (.change.before // {}) as $before | (.change.after // {}) as $after | (.change.after_unknown // {}) as $unknown
    | [($before | keys[]), ($after | keys[]), ($unknown | keys[])] | unique
    | map(select(. as $key
        | if ($unknown[$key] // false) != false then $declared == null or ($declared | index($key)) != null
          else $before[$key] != $after[$key] end));
  def expressions_of($declared):
    . as $change | $declared | map(select(.address == ($change.address | strip_index))) | .[0].expressions;
  def is_www_record_update:
    .type == "cloudflare_dns_record" and .change.actions == ["update"] and ((.index // "") | type == "string" and startswith("www."));

  . as $plan
  | [($plan.resource_changes // [])[] | select((.mode // "managed") == "managed")] as $changes
  | ($changes | any(.change.importing == null and (.change.actions == ["no-op"] or .change.actions == ["update"]))) as $state_holds
  | if $state_holds then
      {
        adoption: false,
        listed: [$changes[] | select(.type == "cloudflare_ruleset" and (.change.actions | index("update"))) | {address, actions: actions_text}],
        stops: (if $allow then [] else [$changes[] | select(.type == "cloudflare_ruleset" and (.change.actions | index("update")))
          | {address, actions: actions_text, reason: "is a ruleset update; pass --allow-ruleset-update for a reviewed change"}] end)
      }
    elif $plan.configuration == null then
      {adoption: true, listed: [], stops: [{address: "(plan)", actions: "none", reason: "the plan carries no configuration, so the declared objects cannot be judged"}]}
    else
      declared(""; $plan.configuration.root_module) as $declared
      | [$changes[] | select(is_www_record_update and .change.importing != null)] as $updates
      | {
          adoption: true,
          listed: [$changes[] | select(.change.importing != null) | {address, actions: actions_text,
            changes: (if is_www_record_update then changed_attributes(expressions_of($declared)) else [] end)}],
          stops: (
            [$changes[] | select(.change.importing == null) | {address, actions: actions_text, reason: "is not an import; the adoption creates, deletes and replaces nothing"}]
            + [$changes[] | select(.change.importing != null and .change.actions != ["no-op"] and (is_www_record_update | not))
              | {address, actions: actions_text, reason: "is an import that is not at no-op"}]
            + [$updates | to_entries[] | select(.key > 0) | .value | {address, actions: actions_text, reason: "is a second update; the adoption allows one"}]
            + [$updates[] | . as $change | (changed_attributes(expressions_of($declared)) | map(select(. != "content"))) as $others
              | select($others | length > 0)
              | {address, actions: actions_text, reason: "changes \($others | join(", ")); the adoption allows only content"}]
            + [$declared[] | select(.address as $address | $changes | any(.address | strip_index == $address) | not)
              | {address, actions: "none", reason: "is declared and the plan holds no import for it"}]
          )
        }
    end
' 2>&1)" || fail "the plan could not be read: ${judgement}"

stops="$(jq -r '.stops[] | "\(.address) \(.actions): \(.reason)"' <<<"${judgement}")"
if [ -n "${stops}" ]; then
  echo "cloudflare_adoption_check: the plan is refused; nothing was applied:" >&2
  while IFS= read -r stop; do
    echo "  ${stop}" >&2
  done <<<"${stops}"
  exit 1
fi

if [ "$(jq -r .adoption <<<"${judgement}")" = true ]; then
  jq -r '"cloudflare_adoption_check: adoption plan: \(.listed | length) imports, \([.listed[] | select(.actions == "no-op")] | length) no-op, \([.listed[] | select(.actions != "no-op")] | length) update",
    (.listed[] | "  \(.address) import \(.actions)" + (if (.changes | length) > 0 then " (changes \(.changes | join(", ")))" else "" end))' <<<"${judgement}"
else
  echo "cloudflare_adoption_check: the state holds zone objects; the adoption rules do not apply"
  jq -r '.listed[] | "  \(.address) \(.actions) (--allow-ruleset-update)"' <<<"${judgement}"
fi
