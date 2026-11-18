#!/usr/bin/env bash
# Usage: tests/postgres/connections_stay_within_max_connections.sh <layer directory>...
# Needs kubectl and yq, and no cluster. Renders each layer directory (one namespace with its own Postgres) and judges
# that what can hold a connection to that Postgres at once fits: the sum over its Deployments that mount the Secret
# postgres of (replicas + the rollout's surge) x connections per pod, plus the backup's dump, is at most
# max_connections less superuser_reserved_connections, both read from the Postgres StatefulSet's arguments. A
# Deployment declares its connections per pod once: the pool and overflow its container sets (the process holds at most
# pool + overflow + 1, its init-time engines being the 1), or, where the app fixes them, the annotation below. The
# restore test restores into a throwaway server of its own and holds none. It then renders apps/songmaker and
# apps/personas with one value each changed to break exactly one rule, and fails unless the judgement names that rule.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

[ $# -ge 1 ] || fail "usage: $0 <layer directory>..."
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
declared_annotation=hallucinai.de/postgres-connections-per-pod
# pg_dump holds one connection: k8up's backup command and the files layer's PreBackupPod are the only dumps.
backup_connections=1
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# deployments <rendered>: one line per Deployment: name|replicas|strategy|surge|pool|overflow|declared|opens, where opens
# is the number of its volumes that mount the Secret postgres.
deployments() {
  yq --no-doc 'select(.kind == "Deployment") | [
    .metadata.name,
    .spec.replicas // 1,
    .spec.strategy.type // "RollingUpdate",
    .spec.strategy.rollingUpdate.maxSurge // "25%",
    [.spec.template.spec.containers[].env[]? | select(.name == "DATABASE_POOL_SIZE") | .value][0] // "",
    [.spec.template.spec.containers[].env[]? | select(.name == "DATABASE_MAX_OVERFLOW") | .value][0] // "",
    .metadata.annotations["'"$declared_annotation"'"] // "",
    ([.spec.template.spec.volumes[]? | select(.secret.secretName == "postgres" or .projected.sources[]?.secret.name == "postgres")] | length)
  ] | join("|")' "$1"
}

# server_limit <rendered> <setting>: the value the Postgres StatefulSet's arguments give the setting.
server_limit() {
  yq --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "postgres") | .spec.template.spec.containers[] | select(.name == "postgres") | .args[]' "$1" |
    sed -n "s/^$2=//p"
}

# judge <rendered>: prints one problem line for each breach and, last, one summary line for the render's namespace.
judge() {
  local rendered="$1" max reserved total=0 name replicas strategy surge pool overflow declared opens per_pod pods namespace
  namespace="$(yq --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "postgres") | .metadata.namespace' "$rendered")"
  max="$(server_limit "$rendered" max_connections)"
  reserved="$(server_limit "$rendered" superuser_reserved_connections)"
  if [ -z "$max" ] || [ -z "$reserved" ]; then
    echo "problem: $namespace: the Postgres StatefulSet gives no max_connections and superuser_reserved_connections"
    return
  fi
  while IFS='|' read -r name replicas strategy surge pool overflow declared opens; do
    [ -n "$name" ] && [ "$opens" -gt 0 ] || continue
    if [ -n "$pool$overflow" ] && [ -n "$declared" ]; then
      echo "problem: $namespace: the Deployment $name declares its connections twice, as a pool and as an annotation"
      continue
    elif [ -n "$pool" ] && [ -n "$overflow" ]; then
      per_pod=$((pool + overflow + 1))
    elif [ -n "$declared" ]; then
      per_pod="$declared"
    else
      echo "problem: $namespace: the Deployment $name opens the Postgres and declares no connections per pod (DATABASE_POOL_SIZE with DATABASE_MAX_OVERFLOW, or $declared_annotation)"
      continue
    fi
    if [ "$strategy" = Recreate ]; then
      surge=0
    elif [[ $surge == *% ]]; then
      surge=$(((replicas * ${surge%\%} + 99) / 100))
    fi
    pods=$((replicas + surge))
    total=$((total + pods * per_pod))
  done < <(deployments "$rendered")
  total=$((total + backup_connections))
  if [ "$total" -gt $((max - reserved)) ]; then
    echo "problem: $namespace: up to $total connections (the Deployments' pods with their surge and the backup) exceed max_connections $max less $reserved reserved"
  fi
  echo "$namespace: up to $total connections of $((max - reserved)) (max_connections $max, $reserved reserved)"
}

for directory in "$@"; do
  rendered="$work/$(basename "$directory").yaml"
  kubectl kustomize "$repository_root/$directory" >"$rendered" || fail "$directory does not render"
  verdict="$(judge "$rendered")"
  problems="$(grep '^problem: ' <<<"$verdict" || true)"
  [ -z "$problems" ] || fail "$directory: ${problems//$'\n'/; }"
  echo "$verdict"
done

# mutant <layer directory> <expected problem text> <yq expression>: a copy of the render changed by the expression
# must make the judgement name the rule.
mutant() {
  local directory="$1" expected="$2" mutated="$work/mutant.yaml" problems
  kubectl kustomize "$repository_root/$directory" | yq "$3" >"$mutated"
  problems="$(judge "$mutated" | grep '^problem: ' || true)"
  grep -qF -- "$expected" <<<"$problems" ||
    fail "the mutant '$3' of $directory made the judgement report '${problems:-nothing}', not '$expected'"
  echo "the mutant '$3' of $directory is red: ${problems%%$'\n'*}"
}
personas='select(.kind == "Deployment" and .metadata.name == "personas")'
web='select(.kind == "Deployment" and .metadata.name == "web")'
postgres='select(.kind == "StatefulSet" and .metadata.name == "postgres") | .spec.template.spec.containers[0]'
mutant apps/personas "exceed max_connections" "($personas | .spec.replicas) = 3"
mutant apps/personas "exceed max_connections" "($personas | .spec.strategy.rollingUpdate.maxSurge) = 2"
mutant apps/personas "exceed max_connections" "($personas | .spec.strategy.rollingUpdate.maxSurge) = \"100%\""
mutant apps/personas "declares no connections per pod" "del($personas | .metadata.annotations)"
mutant apps/personas "exceed max_connections" "($postgres | .args[] | select(test(\"^max_connections=\"))) = \"max_connections=96\""
mutant apps/personas "exceed max_connections" "($postgres | .args[] | select(test(\"^superuser_reserved_connections=\"))) = \"superuser_reserved_connections=7\""
mutant apps/personas "gives no max_connections" "del($postgres | .args)"
mutant apps/songmaker "exceed max_connections" "($web | .spec.template.spec.containers[0].env[] | select(.name == \"DATABASE_POOL_SIZE\") | .value) = \"60\""
mutant apps/songmaker "declares no connections per pod" "del($web | .spec.template.spec.containers[0].env[] | select(.name == \"DATABASE_MAX_OVERFLOW\"))"
mutant apps/songmaker "declares its connections twice" "($web | .metadata.annotations.\"$declared_annotation\") = \"16\""
echo "every mutant of the connection budget is red"
