#!/usr/bin/env bash
# Usage: tests/postgres/connections_stay_within_max_connections.sh <layer directory>...
# Needs kubectl and yq, and no cluster. Renders each layer directory (one namespace with its own Postgres) and judges
# that what can hold a connection to that Postgres at once fits: the sum over its Deployments that mount the Secret
# postgres of the pods they can have at once x connections per pod, plus the backup's dump, is at most max_connections
# less superuser_reserved_connections, both read from the Postgres StatefulSet's arguments. A Recreate Deployment has
# its replicas, since its old pods are gone before the new ones start. A RollingUpdate has 2 x replicas + the surge: a
# pod being stopped is no part of the surge and may hold its connections for as long as its stop takes, so every old pod
# may still be stopping while the surge pods run. Each surge pod also runs its migrate before its own pool opens,
# which adds 1 connection per surge pod where an init container mounts a volume that mounts the Secret postgres. A
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

# deployments <rendered>: one line per Deployment: name|replicas|strategy|surge|pool|overflow|declared|opens|migrates,
# where opens is the number of its volumes that mount the Secret postgres and migrates the number of its init containers
# that mount one of them.
deployments() {
  yq --no-doc 'select(.kind == "Deployment") | [
    .metadata.name,
    .spec.replicas // 1,
    .spec.strategy.type // "RollingUpdate",
    .spec.strategy.rollingUpdate.maxSurge // "25%",
    [.spec.template.spec.containers[].env[]? | select(.name == "DATABASE_POOL_SIZE") | .value][0] // "",
    [.spec.template.spec.containers[].env[]? | select(.name == "DATABASE_MAX_OVERFLOW") | .value][0] // "",
    .metadata.annotations["'"$declared_annotation"'"] // "",
    ([.spec.template.spec.volumes[]? | select(.secret.secretName == "postgres" or .projected.sources[]?.secret.name == "postgres")] | length),
    ([.spec.template.spec.volumes[]? | select(.secret.secretName == "postgres" or .projected.sources[]?.secret.name == "postgres") | .name] as $postgres_volumes |
      [.spec.template.spec.initContainers[]? | select(([.volumeMounts[]?.name] - ([.volumeMounts[]?.name] - $postgres_volumes)) | length > 0)] | length)
  ] | join("|")' "$1"
}

# server_limit <rendered> <setting>: the value the Postgres StatefulSet's arguments give the setting.
server_limit() {
  yq --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "postgres") | .spec.template.spec.containers[] | select(.name == "postgres") | .args[]' "$1" |
    sed -n "s/^$2=//p"
}

# judge <rendered>: prints one problem line for each breach and, last, one summary line for the render's namespace.
judge() {
  local rendered="$1" max reserved total=0 name replicas strategy surge pool overflow declared opens migrates per_pod pods migrate_connections namespace rows value
  namespace="$(yq --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "postgres") | .metadata.namespace' "$rendered")"
  max="$(server_limit "$rendered" max_connections)"
  reserved="$(server_limit "$rendered" superuser_reserved_connections)"
  if [ -z "$max" ] || [ -z "$reserved" ]; then
    echo "problem: $namespace: the Postgres StatefulSet gives no max_connections and superuser_reserved_connections"
    return
  fi
  rows="$(deployments "$rendered")" || {
    echo "problem: $namespace: the Deployments do not read from the render"
    return
  }
  while IFS='|' read -r name replicas strategy surge pool overflow declared opens migrates; do
    [ -n "$name" ] && [ "$opens" -gt 0 ] || continue
    for value in "$pool" "$overflow" "$declared"; do
      if [ -n "$value" ] && ! [[ $value =~ ^(0|[1-9][0-9]*)$ ]]; then
        echo "problem: $namespace: the Deployment $name declares '$value' connections, not a non-negative integer"
        continue 2
      fi
    done
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
      pods="$replicas"
      migrate_connections=0
    else
      if [[ $surge == *% ]]; then
        surge=$(((replicas * ${surge%\%} + 99) / 100))
      fi
      pods=$((2 * replicas + surge))
      migrate_connections=$((surge * (migrates > 0 ? 1 : 0)))
    fi
    total=$((total + pods * per_pod + migrate_connections))
  done <<<"$rows"
  total=$((total + backup_connections))
  if [ "$total" -gt $((max - reserved)) ]; then
    echo "problem: $namespace: up to $total connections (the Deployments' pods, those still stopping and the surge's migrates included, and the backup) exceed max_connections $max less $reserved reserved"
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
  local directory="$1" mutated="$work/mutant.yaml"
  kubectl kustomize "$repository_root/$directory" | yq "$3" >"$mutated"
  expect_problem "$2" "$3 of $directory" judge "$mutated"
}
personas='select(.kind == "Deployment" and .metadata.name == "personas")'
web='select(.kind == "Deployment" and .metadata.name == "web")'
postgres='select(.kind == "StatefulSet" and .metadata.name == "postgres") | .spec.template.spec.containers[0]'
mutant apps/personas "exceed max_connections" "($personas | .spec.replicas) = 3"
mutant apps/personas "exceed max_connections" "($personas | .spec.strategy.rollingUpdate.maxSurge) = 4"
mutant apps/personas "exceed max_connections" "($personas | .spec.strategy.rollingUpdate.maxSurge) = \"300%\""
mutant apps/personas "declares no connections per pod" "del($personas | .metadata.annotations)"
mutant apps/personas "exceed max_connections" "($postgres | .args[] | select(test(\"^max_connections=\"))) = \"max_connections=96\""
# The next two are max_connections values against personas' 157 connections: 100 leaves 97 slots, 60 short, and 159
# leaves 156, one connection short, so only the 159 mutant sits one connection beyond the budget.
mutant apps/personas "exceed max_connections" "($postgres | .args[] | select(test(\"^max_connections=\"))) = \"max_connections=100\""
mutant apps/personas "exceed max_connections" "($postgres | .args[] | select(test(\"^max_connections=\"))) = \"max_connections=159\""
mutant apps/personas "exceed max_connections" "($postgres | .args[] | select(test(\"^superuser_reserved_connections=\"))) = \"superuser_reserved_connections=50\""
mutant apps/personas "gives no max_connections" "del($postgres | .args)"
mutant apps/songmaker "exceed max_connections" "($web | .spec.template.spec.containers[0].env[] | select(.name == \"DATABASE_POOL_SIZE\") | .value) = \"250\""
mutant apps/songmaker "declares no connections per pod" "del($web | .spec.template.spec.containers[0].env[] | select(.name == \"DATABASE_MAX_OVERFLOW\"))"
mutant apps/songmaker "not a non-negative integer" "($web | .spec.template.spec.containers[0].env[] | select(.name == \"DATABASE_POOL_SIZE\") | .value) = \"5x\""
mutant apps/personas "not a non-negative integer" "($personas | .metadata.annotations.\"$declared_annotation\") = \"31x\""
mutant apps/songmaker "declares its connections twice" "($web | .metadata.annotations.\"$declared_annotation\") = \"16\""
echo "every mutant of the connection budget is red"
