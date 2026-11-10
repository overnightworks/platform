# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034,SC2329 # the caller sets layer and reads the variables and functions set here
# Sourced by the scripts that prove the loader on the proof layer; defines functions only. prepare_loader_proof reads
# $layer (the proof layer), $PROBE_IMAGE, $RUNNER_TEMP and tests/postgres/writers from the working directory, and sets
# for its caller: layer_path, key_tables, key_table, dump, toc_dump, marker and output (and dump_dir, job_uid,
# git_replicas, app_pods, which writers_ran and loaded use). Needs failure.sh sourced.
sql() { kubectl --namespace "$1" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only \
  --no-align --set=ON_ERROR_STOP=1 --command="$2"; }

# empty_database: the database as a fresh claim holds it, its public schema dropped with every table and view in it
# and re-created as PostgreSQL creates it; fails when a relation outside the system schemas remains.
empty_database() {
  sql "$layer" 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner;
    GRANT USAGE ON SCHEMA public TO PUBLIC' > /dev/null
  [ "$(sql "$layer" "SELECT count(*) FROM pg_class JOIN pg_namespace ON pg_namespace.oid = relnamespace
    WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname NOT LIKE 'pg_toast%'")" = 0 ] ||
    fail "the database of $layer still holds a relation after its public schema was re-created"
  echo "the database of $layer holds no relation, as on a fresh claim"
}

prepare_loader_proof() {
# The writers: the Postgres base and a Deployment and a Job Flux applies from tests/postgres/writers, in place of
# the layer's own path and with the probe image, so the loader and the interrupts stop and restore real
# Flux-managed writers on a database no app writes. The root would revert the path, so it stays suspended until the
# proofs are done.
layer_path="$(kubectl --namespace flux-system get kustomization "$layer" -o jsonpath='{.spec.path}')"
mapfile -t app_pods < <(kubectl --namespace "$layer" get pods -o name | grep -vx 'pod/postgres-0' || true)
flux suspend kustomization flux-system
kubectl --namespace flux-system patch kustomization "$layer" --type merge --patch "$(
  NAME="${PROBE_IMAGE%%:*}" DIGEST="${PROBE_IMAGE#*@}" yq --null-input --output-format json '
    {"spec": {"path": "./tests/postgres/writers",
      "images": [{"name": "busybox", "newName": strenv(NAME), "digest": strenv(DIGEST)}]}}')"
flux reconcile kustomization "$layer" --timeout=5m
# Flux pruned the layer's apps; their pods' sessions end with them.
[ "${#app_pods[@]}" = 0 ] || kubectl --namespace "$layer" wait "${app_pods[@]}" --for=delete --timeout=3m
empty_database
# The check reads key-tables from the ConfigMap's volume, which the kubelet refreshes only after a while.
key_tables="$(kubectl --namespace "$layer" get configmap postgres -o jsonpath='{.data.key-tables}')"
mounted_key_tables() { kubectl --namespace "$layer" exec postgres-0 --container postgres -- \
  cat /etc/postgres-checks/key-tables; }
for _ in $(seq 120); do [ "$(mounted_key_tables)" = "$key_tables" ] && break; sleep 1; done
[ "$(mounted_key_tables)" = "$key_tables" ] || fail "Postgres in $layer does not see the writers' key-tables within 2 minutes"
job_uid=""
git_replicas="$(yq 'select(.kind == "Deployment") | .spec.replicas' tests/postgres/writers/writers.yaml)"
# writers_ran: the Deployment runs at its replicas from Git and the Job is a new one, Complete.
writers_ran() {
  kubectl --namespace "$layer" rollout status deployment/writer --timeout=5m
  [ "$(kubectl --namespace "$layer" get deployment writer -o jsonpath='{.spec.replicas}')" = "$git_replicas" ] ||
    fail "the Deployment writer does not run at the replicas of Git"
  kubectl --namespace "$layer" wait job/writer-job --for=condition=Complete --timeout=5m
  new_uid="$(kubectl --namespace "$layer" get job writer-job -o jsonpath='{.metadata.uid}')"
  [ "$new_uid" != "$job_uid" ] || fail "the Job writer-job is the one before the load, not a re-created one"
  job_uid="$new_uid"
}
writers_ran
echo "Flux applies the Deployment writer and the Job writer-job in $layer"

# The loader on a synthetic dump made here: a fresh and a repeated load, a truncated copy, a refusal on a
# suspension it did not make, and both interrupts. Its rows carry a marker no output may show.
dump_dir="$RUNNER_TEMP/dumps"
mkdir -m 0700 "$dump_dir"
dump="$dump_dir/synthetic.dump"
marker="synthetic-row-$(openssl rand -hex 4)"
key_table="${key_tables%% *}"
sql "$layer" 'CREATE DATABASE synthetic'
kubectl --namespace "$layer" exec --stdin postgres-0 --container postgres -- psql --no-psqlrc --quiet \
  --set=ON_ERROR_STOP=1 --set=key_table="$key_table" --set=marker="$marker" --dbname=synthetic <<'SQL'
CREATE TABLE :"key_table" (token text PRIMARY KEY, spend numeric);
CREATE TABLE spend_logs (id integer, payload text);
INSERT INTO :"key_table" SELECT :'marker' || '-' || i, i / 3.0 FROM generate_series(1, 7) i;
INSERT INTO spend_logs SELECT i, :'marker' || '-' || md5(i::text) FROM generate_series(1, 200000) i;
SQL
kubectl --namespace "$layer" exec postgres-0 --container postgres -- pg_dump --format=custom --dbname=synthetic \
  > "$dump"
# A second dump of the same tables with almost no rows and many empty ones, so its table of contents fills most
# of the file and pg_restore is still reading it at half.
toc_dump="$dump_dir/toc-heavy.dump"
kubectl --namespace "$layer" exec --stdin postgres-0 --container postgres -- psql --no-psqlrc --quiet \
  --set=ON_ERROR_STOP=1 --dbname=synthetic <<'SQL'
DELETE FROM spend_logs;
DO $$
BEGIN
  FOR i IN 1..500 LOOP
    EXECUTE format('CREATE TABLE toc_%s (a integer, b text, c text, d text, e text, f text, g text, h numeric)', i);
  END LOOP;
END
$$;
SQL
kubectl --namespace "$layer" exec postgres-0 --container postgres -- pg_dump --format=custom --dbname=synthetic \
  > "$toc_dump"
sql "$layer" 'DROP DATABASE synthetic'
output="$dump_dir/output"
loaded() {
  local status=0
  mise run db:load-dump "$@" > "$output" 2>&1 || status=$?
  cat "$output"
  ! grep -q "$marker" "$output" || fail "db:load-dump $* printed a row"
  return "$status"
}
}
