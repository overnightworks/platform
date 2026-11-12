#!/usr/bin/env bash
# Judge the Cloudflare root's plan, as `tofu show -json <plan>` prints it on stdin, before anything is applied.
# While the plan imports any object (the adoption, a half-finished one included), it passes only without a create or a
# delete, with every imported ruleset and setting at no-op, at most one update, the content of the record www, and every
# declared object the state does not hold among the imports. A plan that cannot be read, an empty one or one with a
# resource change without an address or an action included, fails. Only a plan without any import is a later plan, to
# which the adoption rules do not apply and in which an update of a ruleset stops unless --allow-ruleset-update names it.
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

# The adoption rules apply while the plan imports any object, a half-finished adoption included: then the plan creates
# and deletes nothing, imports every ruleset and setting at no-op, updates at most the content of the record www, and
# imports every declared object the state does not hold (an object the state holds is at no-op without an import).
# A plan without any import is a later plan.
# (Resource instances that a delete, a forget or a replacement touches say nothing about the state in this judgement,
# so such a plan stays an adoption and stops on that action.)
judgement="$(jq --slurp --argjson allow "${allow_ruleset_update}" '
  def strip_index: gsub("\\[[^\\]]*\\]"; "");
  def actions_text: .change.actions | join(",");
  # The declared instances: every managed resource the plan holds after the apply, a for_each key included.
  def planned($module):
    [($module.resources // [])[] | select(.mode == "managed") | .address]
    + ([($module.child_modules // [])[] | planned(.)] | add // []);
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
  def unreadable($reason): {adoption: false, listed: [], stops: [{address: "(plan)", actions: "none", reason: $reason}]};

  (.[0] // null) as $plan
  | if length != 1 or ($plan | type) != "object" or ($plan.resource_changes | type) != "array" then
      unreadable("the plan is empty or holds no list of resource changes, so it cannot be judged")
    else
      [$plan.resource_changes[] | select((.mode // "managed") == "managed")] as $changes
      | if ($changes | all(((.address | type) == "string" and (.address | length) > 0)
          and ((.change.actions | type) == "array" and (.change.actions | length) > 0 and (.change.actions | all(type == "string"))))) | not then
          unreadable("a resource change of the plan has no address or no action, so it cannot be judged")
        else
      (($plan.planned_values // null) | if . == null then [] else planned(.root_module // {}) end) as $instances
      | if ($changes | length) == 0 and ($instances | length) == 0 then
          unreadable("the plan holds no resource, so it cannot be judged")
        elif ($changes | any(.change.importing != null) | not) then
          {
            adoption: false,
            listed: [$changes[] | select(.type == "cloudflare_ruleset" and (.change.actions | index("update"))) | {address, actions: actions_text}],
            stops: (
              [$instances[] | select(. as $address | $changes | any(.address == $address) | not)
                | {address: ., actions: "none", reason: "is declared and the plan holds no import for it"}]
              + (if $allow then [] else [$changes[] | select(.type == "cloudflare_ruleset" and (.change.actions | index("update")))
                | {address, actions: actions_text, reason: "is a ruleset update; pass --allow-ruleset-update for a reviewed change"}] end))
          }
        elif $plan.configuration == null or $plan.planned_values == null then
          unreadable("the plan carries no configuration or no planned values, so the declared objects cannot be judged")
          | .adoption = true
        else
          declared(""; $plan.configuration.root_module) as $declared
          | [$changes[] | select(is_www_record_update)] as $updates
          | {
              adoption: true,
              listed: [$changes[] | select(.change.importing != null or is_www_record_update) | {address, actions: actions_text, imported: (.change.importing != null),
                changes: (if is_www_record_update then changed_attributes(expressions_of($declared)) else [] end)}],
              stops: (
                [$changes[] | select(.change.importing == null and .change.actions != ["no-op"] and (is_www_record_update | not))
                  | {address, actions: actions_text, reason: "is not an import or at no-op; the adoption creates, deletes, updates and replaces nothing else"}]
                + [$changes[] | select(.change.importing != null and .change.actions != ["no-op"] and (is_www_record_update | not))
                  | {address, actions: actions_text, reason: "is an import that is not at no-op"}]
                + [$updates | to_entries[] | select(.key > 0) | .value | {address, actions: actions_text, reason: "is a second update; the adoption allows one"}]
                + [$updates[] | . as $change | (changed_attributes(expressions_of($declared)) | map(select(. != "content"))) as $others
                  | select($others | length > 0)
                  | {address, actions: actions_text, reason: "changes \($others | join(", ")); the adoption allows only content"}]
                + [$instances[] | select(. as $address | $changes | any(.address == $address) | not)
                  | {address: ., actions: "none", reason: "is declared and the plan holds no import for it"}]
                + [$changes[] | select(.change.importing != null and (.address as $address | $instances | index($address) | not))
                  | {address, actions: actions_text, reason: "is imported and declared nowhere"}]
              )
            }
        end
        end
    end
' 2>&1)" || fail "the plan could not be read"
[ -n "${judgement}" ] && jq -e '.stops | type == "array"' >/dev/null 2>&1 <<<"${judgement}" || fail "the plan could not be read"

stops="$(jq -r '.stops[] | "\(.address) \(.actions): \(.reason)"' <<<"${judgement}")"
if [ -n "${stops}" ]; then
  echo "cloudflare_adoption_check: the plan is refused; nothing was applied:" >&2
  while IFS= read -r stop; do
    echo "  ${stop}" >&2
  done <<<"${stops}"
  exit 1
fi

if [ "$(jq -r .adoption <<<"${judgement}")" = true ]; then
  jq -r '"cloudflare_adoption_check: adoption plan: \([.listed[] | select(.imported)] | length) imports, \([.listed[] | select(.actions == "no-op")] | length) no-op, \([.listed[] | select(.actions != "no-op")] | length) update",
    (.listed[] | "  \(.address) \(if .imported then "import " else "" end)\(.actions)" + (if (.changes | length) > 0 then " (changes \(.changes | join(", ")))" else "" end))' <<<"${judgement}"
else
  echo "cloudflare_adoption_check: the state holds zone objects; the adoption rules do not apply"
  jq -r '.listed[] | "  \(.address) \(.actions) (--allow-ruleset-update)"' <<<"${judgement}"
fi
