#!/usr/bin/env bash
# `mise run presentator:load-database <file>`: replaces presentator's live SQLite file with the verified copy <file>
# while its web is stopped, so the file holds the old or the new database and never a mix. The copy is staged only in
# the loader Pod's emptyDir and loaded by sqlite_copy.py, which the web's image runs. It prints names, counts and
# outcomes, never a row.
# Usage: scripts/presentator_load_database.sh <file>
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
namespace=presentator kustomization=presentator deployment=web claim=database loader=presentator-load
lock=/tmp/presentator-load-database.lock
file="${1:?usage: presentator_load_database.sh <file>}"
say() { echo "presentator:load-database: $1"; }
fail() { echo "presentator:load-database: $1" >&2; exit 1; }

# The lock descriptor stays out of every kubectl and flux, so a killed run's children do not hold the lock. The command
# substitution that runs the load keeps it while its kubectl runs, since the remote load may still be running.
kubectl() { command kubectl "$@" 9>&-; }
flux() { command flux "$@" 9>&-; }

# The kernel frees the lock when this process ends, however it ends.
{ exec 9>>"$lock"; } 2>/dev/null || fail "cannot open the lock file $lock; nothing changed"
flock -n 9 || fail "another presentator:load-database holds $lock; nothing changed"

# A -wal or -journal beside the source holds changes that opening the copy read-only and immutable would ignore.
[ -r "$file" ] && [ -f "$file" ] || fail "no readable regular file given; nothing changed"
for sidecar in "$file-wal" "$file-journal"; do
  [ ! -s "$sidecar" ] || fail "${sidecar##*/} beside $file is not empty, so the copy is not a closed database; nothing changed"
done
size="$(stat --format=%s -- "$file")"
digest="$(sha256sum -- "$file" | cut -d' ' -f1)"
say "the copy $file: $size bytes"

in_namespace() { kubectl --namespace "$namespace" "$@"; }
key_table="$(in_namespace get configmap sqlite --output jsonpath='{.data.key-table}')" && [ -n "$key_table" ] ||
  fail "cannot read the key table from the ConfigMap sqlite in $namespace; nothing changed"
suspended="$(kubectl --namespace flux-system get kustomization "$kustomization" --output jsonpath='{.spec.suspend}')" ||
  fail "cannot read whether the Kustomization $kustomization is suspended; nothing changed"
# The loader is built from named fields of the web's template and nothing else: no label or annotation, so the web's
# ReplicaSet cannot adopt it and no backup execs in it; the web's image holds python3 and sqlite3.
# shellcheck disable=SC2016 # $spec and $web are yq's variables
manifest="$(in_namespace get deployment "$deployment" --output json | NAME="$loader" CLAIM="$claim" yq --input-format json \
  --output-format json '.spec.template.spec as $spec | $spec.containers[] | select(.name == "web") as $web |
    { "apiVersion": "v1", "kind": "Pod", "metadata": { "name": strenv(NAME) },
      "spec": { "restartPolicy": "Never", "automountServiceAccountToken": false, "enableServiceLinks": false,
        "terminationGracePeriodSeconds": 1, "imagePullSecrets": $spec.imagePullSecrets,
        "securityContext": $spec.securityContext,
        "containers": [{ "name": "loader", "image": $web.image, "command": ["sleep", "3600"], "env": $web.env,
          "securityContext": $web.securityContext,
          "volumeMounts": [($web.volumeMounts[] | select(.name == strenv(CLAIM))),
            { "name": "staging", "mountPath": "/staging" },
            { "name": "sqlite", "mountPath": "/sqlite", "readOnly": true }] }],
        "volumes": [($spec.volumes[] | select(.name == strenv(CLAIM))),
          { "name": "staging", "emptyDir": {} },
          { "name": "sqlite", "configMap": { "name": "sqlite" } }] } }')" ||
  fail "cannot build the loader Pod from the Deployment $deployment in $namespace; nothing changed"

by_run=false changed=false verified=false
stop_loader() { in_namespace delete pod "$loader" --ignore-not-found --wait >/dev/null; }
resume_flux() { flux resume kustomization "$kustomization" --wait; }
# A Ctrl-C reaches mise and this script, and mise forwards it once more, so the end ignores INT and runs once, to its end.
# Whatever ends the run deletes the loader. Before the load starts, the data is unchanged: a Kustomization this run
# suspended is resumed and one suspended already stays so; from there on the outcome is unknown or the load is not
# finished, and the Kustomization stays suspended with the web at 0.
end_run() {
  local status=$?
  trap - EXIT TERM
  trap '' INT
  stop_loader || echo "presentator:load-database: could not delete the loader Pod $loader; run kubectl -n $namespace delete pod $loader" >&2
  [ "$status" -ne 0 ] || return 0
  if [ "$verified" = true ]; then
    echo "presentator:load-database: the load is verified and the web may be serving it; finish with flux resume \
kustomization $kustomization and kubectl -n $namespace rollout status deployment/$deployment; do not load again" >&2
  elif [ "$changed" = true ]; then
    echo "presentator:load-database: whether the load changed the database is unknown, or the loaded data is not resumed on; \
the Kustomization $kustomization stays suspended and the web at 0: run the same command again" >&2
  elif [ "$by_run" = true ]; then
    echo "presentator:load-database: the database is unchanged; resuming the Kustomization $kustomization" >&2
    resume_flux || echo "presentator:load-database: could not resume the Kustomization $kustomization; run flux resume \
kustomization $kustomization" >&2
  else
    echo "presentator:load-database: the database is unchanged; the Kustomization $kustomization stays suspended as it was and the web at 0; resume it with flux \
resume kustomization $kustomization when you are done" >&2
  fi
}
trap end_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stop_loader || fail "cannot delete an earlier loader Pod $loader in $namespace; nothing changed"
if [ "$suspended" = true ]; then
  say "the Kustomization $kustomization was suspended already; it is resumed only after a verified load"
else
  # Set before the suspension, which a signal can apply before its client returns.
  by_run=true
  flux suspend kustomization "$kustomization"
fi

say "stopping the web of $namespace"
deployments="$(in_namespace get deployments --output name)"
readarray -t deployment_names <<<"$deployments"
[ -z "$deployments" ] || in_namespace scale "${deployment_names[@]}" --replicas=0
# A Failed or Succeeded Pod none of whose containers reports running holds no connection; nothing deletes it.
writers="$(in_namespace get pods --output yaml |
  yq '.items[] | select(.metadata.ownerReferences[]?.kind == "ReplicaSet" and ((.status.phase == "Failed" or .status.phase == "Succeeded") and ([.status.containerStatuses[]?, .status.initContainerStatuses[]?] | map(select(.state.running != null)) | length == 0)) == false) | "pod/" + .metadata.name')"
readarray -t writer_names <<<"$writers"
[ -z "$writers" ] || in_namespace wait "${writer_names[@]}" --for=delete --timeout=5m

in_namespace create --filename - <<<"$manifest" >/dev/null || fail "could not start the loader Pod $loader in $namespace"
in_namespace wait "pod/$loader" --for=condition=Ready --timeout=5m >/dev/null || fail "the loader Pod $loader is not Ready after 5 minutes"
in_namespace exec --stdin "$loader" --container loader -- sh -c 'cat >/staging/copy' <"$file" ||
  fail "could not stage the copy in the loader Pod $loader"
say "staged the copy in the loader Pod $loader; loading it"

# The remote program prints the key table's row count and nothing else; its own messages go nowhere, since a failure
# is named by its exit and no output may carry a value, while kubectl's lines reach the operator.
changed=true
load_status=0
# shellcheck disable=SC2016 # the remote shell expands the arguments, the variable and the file
rows="$(in_namespace exec "$loader" --container loader -- sh -c \
  'exec python3 -I /sqlite/sqlite_copy.py load /staging/copy "$1" "$2" "$PRESENTATOR_DATABASE" "$(cat /sqlite/key-table)" 2>/dev/null' \
  sh "$size" "$digest")" || load_status=$?
case "$load_status" in
  0) ;;
  6)
    changed=false
    fail "the load exited 6: the live database is busy; the database is unchanged" ;;
  7)
    changed=false
    fail "the load exited 7: the copy is refused; the database is unchanged" ;;
  *) fail "the load exited $load_status" ;;
esac
verified=true

say "verified: $rows rows in the key table $key_table; resuming the Kustomization $kustomization"
stop_loader
resume_flux
trap - INT
for name in "${deployment_names[@]}"; do
  in_namespace rollout status "$name" --timeout=5m
done
say "$namespace converged"
