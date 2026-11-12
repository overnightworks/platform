# The adoption plan once the state holds the objects: nothing is an import any more and the prior state lists every
# object, the settings in a child module, as `tofu show -json` prints it.
def listed: map({address, mode, type});
.resource_changes |= map(.change.importing = null)
| .prior_state = {format_version: "1.0", values: {root_module: {
    resources: [.resource_changes[] | select(.address | startswith("module.") | not)] | listed,
    child_modules: [{address: "module.settings", resources: [.resource_changes[] | select(.address | startswith("module.settings."))] | listed}]}}}
