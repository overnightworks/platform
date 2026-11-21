# shellcheck shell=bash
# Sourced by the scripts under tests/keycloak.

# realm_group_paths <realm file>: the path of every group the file declares, one per line, flattened from the nesting of
# `groups` and `subGroups`.
realm_group_paths() {
  yq --output-format json '.groups' "$1" | jq --raw-output '
    def group_paths($parent): .[] | ($parent + "/" + .name) as $path | $path, ((.subGroups // []) | group_paths($path));
    group_paths("")'
}
