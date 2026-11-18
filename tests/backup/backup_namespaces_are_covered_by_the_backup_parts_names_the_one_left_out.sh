#!/usr/bin/env bash
# backup_namespaces.sh --covered-by fails naming each backup namespace that no listed part applies, and passes once a
# part applies their layers, and fails when no layer includes the backup component.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
backup_namespaces="$(dirname "${BASH_SOURCE[0]}")/backup_namespaces.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# A part that applies the backup layer alone leaves every namespace that backs up out.
printf '%s\n' 'only_backup: {layers: [backup]}' 'holds_all: {layers: all}' > "$scratch/parts.yaml"
export PARTS_FILE="$scratch/parts.yaml"
if output="$("$backup_namespaces" --covered-by only_backup 2>&1)"; then fail "a part without any backup namespace passed"; fi
mapfile -t expected < <("$backup_namespaces" | cut -d' ' -f2)
for namespace in "${expected[@]}"; do
  [[ $output == *"$namespace"* ]] || fail "the refusal '$output' does not name $namespace"
done
echo "the check names every namespace the part leaves out: ${expected[*]}"

# A part that applies every layer holds every namespace that backs up.
"$backup_namespaces" --covered-by holds_all >/dev/null
echo "a part that applies every layer holds every backup namespace"

# A tree in which no layer includes the backup component has no namespace to cover, so the check refuses it.
if output="$(POSTGRES_BACKUP_COMPONENT="$scratch/no-layer-includes-this" "$backup_namespaces" --covered-by holds_all 2>&1)"; then
  fail "a tree without any backup namespace passed"
fi
[[ $output == *"no layer includes"* ]] || fail "the refusal '$output' does not say that no layer includes the component"
echo "the check refuses a tree in which no layer includes the backup component"
