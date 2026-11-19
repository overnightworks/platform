# shellcheck shell=bash
# Sourced by the scripts under tests/workloads/.
# parse_inventory_id <id> sets inventory_namespace, inventory_name, inventory_group and inventory_kind from an id of a
# Flux inventory, which writes <namespace>_<name>_<group>_<kind> with each ':' of the name as '__' (cli-utils'
# ParseObjMetadata). A namespace and a group hold no underscore, so the namespace ends at the first one and the group
# and the kind begin after the last two; the name between them is decoded.
parse_inventory_id() {
  local rest="$1"
  inventory_namespace="${rest%%_*}"
  rest="${rest#*_}"
  inventory_kind="${rest##*_}"
  rest="${rest%_*}"
  inventory_group="${rest##*_}"
  inventory_name="${rest%_*}"
  inventory_name="${inventory_name//__/:}"
}
