#!/usr/bin/env bash
# Proves the default storage class, each Postgres namespace's claim and Kustomization, that a deleted Kustomization
# leaves its claim, volume and Namespace, that db:load-dump loads, repeats, stops on a table only the database holds,
# fails on a truncated dump and after a materialized view or an INT after its commit, and that Keycloak's egress policy
# admits its Postgres alone. Needs the variables the P7a step sets, PROBE_IMAGE and RUNNER_TEMP.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=loader_proof_setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/loader_proof_setup.sh"
# The loader and the interrupt test run as on the PC, against this cluster.
export KUBECONFIG="$HOME/.kube/config"

# A1: one default class with Retain; each Postgres Ready as its image's postgres user on a bound claim of it.
default_classes="$(kubectl get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')"
[ "$(grep -c . <<<"$default_classes")" = 1 ] || fail "the cluster has not exactly one default class: '$default_classes'"
reclaim_policy="$(kubectl get storageclass "$default_classes" -o jsonpath='{.reclaimPolicy}')"
[ "$reclaim_policy" = Retain ] || fail "the default class $default_classes reclaims with $reclaim_policy, not Retain"
echo "the one default class $default_classes retains released volumes"
for namespace in $POSTGRES_NAMESPACES; do
  kubectl --namespace "$namespace" wait pod/postgres-0 --for=condition=Ready --timeout=5m
  read -r uid postgres_uid < <(kubectl --namespace "$namespace" exec postgres-0 --container postgres -- \
    sh -c 'echo "$(id -u) $(id -u postgres)"')
  [ "$uid" = "$postgres_uid" ] && [ "$uid" != 0 ] ||
    fail "Postgres in $namespace runs as uid $uid, not as the image's postgres user $postgres_uid"
  claim="$(kubectl --namespace "$namespace" get pod postgres-0 \
    -o jsonpath='{.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')"
  state="$(kubectl --namespace "$namespace" get pvc "$claim" \
    -o jsonpath='{.status.phase}|{.spec.storageClassName}|{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}')"
  [ "$state" = "Bound|$default_classes|disabled" ] ||
    fail "the claim $namespace/$claim reads '$state', not Bound on $default_classes with prune disabled"
  # The provisioner creates the volume only after the helper pod, which admission judged, made its directory.
  volume="$(kubectl --namespace "$namespace" get pvc "$claim" -o jsonpath='{.spec.volumeName}')"
  path="$(kubectl get pv "$volume" -o jsonpath='{.spec.hostPath.path}{.spec.local.path}')"
  [[ $path == */"$namespace/$claim" ]] || fail "the volume $volume of $namespace/$claim lies at '$path', not at <namespace>/<claim>"
  kubectl --namespace "$namespace" exec postgres-0 --container postgres -- \
    pg_isready --username="$namespace" --dbname="$namespace"
  echo "Postgres in $namespace is Ready as uid $uid on $claim, bound to $volume at $path; pg_isready passes as $namespace"
done

# A1b: each Postgres namespace's Kustomization, named like it as db:load-dump assumes, holds the base's objects of the
# namespace and depends on every layer in POSTGRES_LAYER_DEPENDENCIES; no other Kustomization holds an object of
# the namespace but the Secrets platform-secrets serves.
inventory_ids() { kubectl --namespace flux-system get kustomization "$1" \
  -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}'; }
all_kustomizations="$(kubectl --namespace flux-system get kustomizations -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
[ -n "$all_kustomizations" ] || fail "flux-system holds no Kustomization"
for namespace in $POSTGRES_NAMESPACES; do
  held="$(inventory_ids "$namespace")"
  while IFS= read -r id; do
    grep -qxF "$id" <<<"$held" || fail "the Kustomization $namespace does not hold $id of $POSTGRES_BASE"
  done < <(NAMESPACE="$namespace" yq --no-doc \
    'strenv(NAMESPACE) + "_" + .metadata.name + "_" + ((.apiVersion | select(contains("/")) | sub("/.*", "")) // "") + "_" + .kind' \
    "$POSTGRES_BASE/postgres.yaml")
  while IFS= read -r other; do
    [ "$other" != "$namespace" ] || continue
    other_ids="$(inventory_ids "$other")"
    foreign="$(grep "^${namespace}_" <<<"$other_ids" || true)"
    [ "$other" != "${SECRETS_LAYER#*/}" ] || foreign="$(grep -v '__Secret$' <<<"$foreign" || true)"
    [ -z "$foreign" ] || fail "the Kustomization $other holds ${foreign//$'\n'/ } of namespace $namespace, which $namespace owns"
  done <<<"$all_kustomizations"
  dependencies="$(kubectl --namespace flux-system get kustomization "$namespace" -o jsonpath='{.spec.dependsOn[*].name}')"
  for dependency in $POSTGRES_LAYER_DEPENDENCIES; do
    [[ " $dependencies " == *" $dependency "* ]] || fail "the Kustomization $namespace does not depend on $dependency"
  done
  echo "the Kustomization $namespace holds the objects of $POSTGRES_BASE, alone but for Secrets, and depends on $POSTGRES_LAYER_DEPENDENCIES"
done

# A2: a deleted Kustomization takes its inventory with it and leaves the claim, its volume and the Namespace.
layer="$PROOF_LAYER"
row="prune-proof-$(openssl rand -hex 8)"
sql "$layer" "CREATE TABLE prune_proof (value text); INSERT INTO prune_proof VALUES ('$row')"
claim="$(kubectl --namespace "$layer" get pod postgres-0 \
  -o jsonpath='{.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')"
kept="$(kubectl --namespace "$layer" get pvc "$claim" -o jsonpath='{.metadata.uid}|{.spec.volumeName}')"
old_pod="$(kubectl --namespace "$layer" get pod postgres-0 -o jsonpath='{.metadata.uid}')"
inventory="$(kubectl --namespace flux-system get kustomization "$layer" \
  -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}')"
for kind in apps_StatefulSet _Service networking.k8s.io_NetworkPolicy; do
  grep -q "_$kind\$" <<<"$inventory" || fail "the inventory of $layer holds no $kind"
done
kubectl --namespace flux-system delete kustomization "$layer" --wait --timeout=3m
kubectl --namespace "$layer" wait pod/postgres-0 --for=delete --timeout=3m
while IFS=_ read -r namespace name group kind; do
  [ -z "$(kubectl get "$kind${group:+.$group}" "$name" ${namespace:+"--namespace=$namespace"} --ignore-not-found -o name)" ] ||
    fail "$kind $namespace/$name outlived the deletion of the Kustomization $layer"
  echo "gone with the Kustomization $layer: $kind $namespace/$name"
done <<<"$inventory"
[ "$(kubectl --namespace "$layer" get pvc "$claim" -o jsonpath='{.metadata.uid}|{.spec.volumeName}')" = "$kept" ] ||
  fail "the claim $layer/$claim is not the one before the deletion"
kubectl get "persistentvolume/${kept#*|}" "namespace/$layer" -o name
echo "the claim $layer/$claim, its volume ${kept#*|} and the Namespace $layer remain"
flux reconcile kustomization flux-system --timeout=5m
kubectl --namespace flux-system wait kustomization "$layer" --for=create --timeout=1m
kubectl --namespace flux-system wait kustomization "$layer" --for=condition=Ready --timeout=5m
kubectl --namespace "$layer" wait pod/postgres-0 --for=condition=Ready --timeout=5m
[ "$(kubectl --namespace "$layer" get pod postgres-0 -o jsonpath='{.metadata.uid}')" != "$old_pod" ] ||
  fail "the Postgres pod of $layer is the one before the deletion"
[ "$(sql "$layer" 'SELECT value FROM prune_proof')" = "$row" ] || fail "the new Postgres pod of $layer lost the row"
echo "the root re-created the Kustomization $layer, and its new Postgres pod reads the row written before"
sql "$layer" 'DROP TABLE prune_proof'

prepare_loader_proof
loaded --compare "$layer" "$dump" || fail "the fresh load exited non-zero"
writers_ran
grep -qxF "$key_table: 7 rows, 7 COPY lines in the dump, equal" "$output" &&
  grep -qxF 'public.spend_logs: 200000 rows loaded, 200000 in the dump, equal' "$output" ||
  fail "the fresh load did not verify $key_table and spend_logs equal"
loaded --compare "$layer" "$dump" || fail "the repeated load exited non-zero"
writers_ran
echo "a fresh and a repeated load verified every table equal, printed no row and restored the writers"

# A table the database holds and the dump does not survives pg_restore --clean: the load must not resume.
sql "$layer" 'CREATE TABLE extra_empty (id integer)'
if loaded --compare "$layer" "$dump"; then fail "a table only in the database did not stop the load"; fi
grep -qxF 'public.extra_empty: 0 rows loaded, 0 in the dump, DIFFERS' "$output" ||
  fail "the load did not name the table only the database holds"
held_back() {
  [ "$(kubectl --namespace flux-system get kustomization "$layer" -o jsonpath='{.spec.suspend}')" = true ] &&
    [ "$(kubectl --namespace "$layer" get deployment writer -o jsonpath='{.spec.replicas}')" = 0 ]
}
held_back || fail "the Kustomization $layer resumed or its writer runs on data that differs from the dump"
sql "$layer" 'DROP TABLE extra_empty'
loaded --resume "$layer" || fail "--resume exited non-zero"
writers_ran
echo "a table only in the database left $layer suspended with its writers at 0 until --resume"

truncated="$dump_dir/truncated.dump"
head -c "$(($(stat -c %s "$dump") / 2))" "$dump" > "$truncated"
if loaded --compare "$layer" "$truncated"; then fail "the truncated load exited 0"; fi
[ "$(kubectl --namespace flux-system get kustomization "$layer" -o jsonpath='{.spec.suspend}')" != true ] ||
  fail "the Kustomization $layer stayed suspended after the failed load"
writers_ran
[ "$(sql "$layer" "SELECT count(*) FROM \"$key_table\"")" = 7 ] || fail "the failed load changed $key_table"
[ "$(stat -c %a "$truncated.load.log")" = 600 ] || fail "$truncated.load.log is not at 0600"
echo "the truncated copy failed to load, the data is unchanged and the Kustomization $layer resumed"

# A materialized view's rows are not in pg_dump's output, so the same failed load cannot prove them unchanged.
sql "$layer" 'CREATE MATERIALIZED VIEW stored_rows AS SELECT 1 AS one'
if loaded "$layer" "$truncated"; then fail "the truncated load exited 0 beside a materialized view"; fi
grep -qF 'is unknown' "$output" && ! grep -qF unchanged "$output" ||
  fail "a failed load beside a materialized view did not report an unknown outcome"
held_back || fail "the Kustomization $layer resumed beside a materialized view the fingerprint cannot cover"
sql "$layer" 'DROP MATERIALIZED VIEW stored_rows'
loaded --resume "$layer" || fail "--resume exited non-zero"
writers_ran
echo "a failed load beside a materialized view left $layer suspended with its writers at 0 until --resume"

# An INT after the restore committed, before the loader saw kubectl's status. The wrapper lets the real
# kubectl run to its end and sends the INT only after the load's exec returned 0, which pg_restore
# --single-transaction gives only after its COMMIT; the emptied key table differs from the dump's.
sql "$layer" "DELETE FROM \"$key_table\""
after_commit="$dump_dir/interrupt-after-commit"
mkdir "$after_commit"
cat > "$after_commit/kubectl" <<'WRAPPER'
#!/usr/bin/env bash
"$REAL_KUBECTL" "$@" || exit
case "$*" in *"pg_restore --clean"*) kill -INT "$PPID"; exit 130 ;; esac
WRAPPER
chmod +x "$after_commit/kubectl"
real_kubectl="$(mise which kubectl)"
if REAL_KUBECTL="$real_kubectl" PATH="$after_commit:$PATH" MISE_DISABLE_TOOLS=kubectl \
  loaded "$layer" "$dump"; then
  fail "the load interrupted after its commit exited 0"
fi
[ "$(sql "$layer" "SELECT count(*) FROM \"$key_table\"")" = 7 ] ||
  fail "the restore had not committed when the INT came, so the cell missed the window after the commit"
grep -qF 'is unknown' "$output" && grep -qF -- "--resume $layer" "$output" &&
  ! grep -qF unchanged "$output" ||
  fail "the load interrupted after its commit did not report an unknown outcome naming --resume"
held_back || fail "the Kustomization $layer resumed or its writer runs after an INT after the commit"
loaded --resume "$layer" || fail "--resume exited non-zero"
writers_ran
echo "an INT after the commit left $layer suspended with its writers at 0, named --resume and claimed nothing"

# The layer's own path again, on an emptied database, so its apps start as on a fresh claim: the root, resumed, would
# revert the path, and Flux prunes the writers.
empty_database
kubectl --namespace flux-system patch kustomization "$layer" --type merge \
  --patch "{\"spec\": {\"path\": \"$layer_path\", \"images\": null}}"
flux resume kustomization flux-system --wait
flux reconcile kustomization "$layer" --timeout=5m
kubectl --namespace flux-system wait kustomization "$layer" --for=condition=Ready --timeout=5m
kubectl --namespace "$layer" wait deployment/writer job/writer-job --for=delete --timeout=2m
echo "the layer $layer is its own again and Ready on an emptied database, and Flux pruned the writers"

# Keycloak's egress: a Pod with Keycloak's labels reaches DNS and its Postgres only; one without them is free.
keycloak_labels="$(kubectl --namespace "$EGRESS_NAMESPACE" get networkpolicy keycloak-egress \
  -o jsonpath='{.spec.podSelector.matchLabels}')"
postgres_port="$(kubectl --namespace "$EGRESS_NAMESPACE" get service postgres -o jsonpath='{.spec.ports[0].port}')"
postgres_target="postgres.$EGRESS_NAMESPACE.svc.cluster.local:$postgres_port"
service_port="$(kubectl --namespace "${CLUSTER_SERVICE%/*}" get service "${CLUSTER_SERVICE#*/}" \
  -o jsonpath='{.spec.ports[0].port}')"
service_target="${CLUSTER_SERVICE#*/}.${CLUSTER_SERVICE%/*}.svc.cluster.local:$service_port"
# egress_probe <name> <labels as JSON>: sets probe_log to one "<target> open|closed" line per target.
egress_probe() {
  NAME="$1" LABELS="$2" IMAGE="$PROBE_IMAGE" TARGETS="$postgres_target $service_target $OUTSIDE_TARGET" yq --null-input '
    {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME), "labels": (strenv(LABELS) | from_yaml)},
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": false,
       "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "probe", "image": strenv(IMAGE),
         "command": ["sh", "-c", "for target; do if nc -z -w 5 \"${target%:*}\" \"${target##*:}\"; then echo \"$target open\"; else echo \"$target closed\"; fi; done", "sh"] + (strenv(TARGETS) | split(" ")),
         "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}}]}}' |
    kubectl --namespace "$EGRESS_NAMESPACE" create -f -
  kubectl --namespace "$EGRESS_NAMESPACE" wait "pod/$1" --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m
  probe_log="$(kubectl --namespace "$EGRESS_NAMESPACE" logs "pod/$1")"
  printf '%s\n' "$probe_log"
  kubectl --namespace "$EGRESS_NAMESPACE" delete pod "$1" --wait --timeout=2m
}
egress_probe keycloak-egress-probe "$keycloak_labels"
[ "$probe_log" = "$postgres_target open"$'\n'"$service_target closed"$'\n'"$OUTSIDE_TARGET closed" ] ||
  fail "a Pod with Keycloak's labels $keycloak_labels does not reach exactly its Postgres"
egress_probe free-egress-probe '{}'
[ "$probe_log" = "$postgres_target open"$'\n'"$service_target open"$'\n'"$OUTSIDE_TARGET open" ] ||
  fail "a Pod without Keycloak's labels does not reach every target, so the probe proves no policy"
echo "a Pod with Keycloak's labels resolves names and reaches its Postgres, neither $CLUSTER_SERVICE nor $OUTSIDE_TARGET"
