# shellcheck shell=bash
# Sourced by the cells that judge the state app_role.sh keeps; defines functions only. Reads a Postgres container
# postgres-0 of a namespace, whose server listens on the port the caller names: the Pod's own on 5432, a throwaway
# one on another. Needs failure.sh and loader_proof_setup.sh sourced.

# The schemas of sessions' temporary objects, whose tables, row types and functions belong to the session's role.
temporary_schemas="SELECT oid FROM pg_namespace WHERE nspname ~ '^pg_(toast_)?temp_'"

# The catalogs that name an owner, as "catalog|owner column|condition" of the rows of the app's database: a row above
# the objects initdb made (oid 16384), outside the public schema, which pg_database_owner owns, outside the schemas
# of sessions' temporary objects, outside an extension's members, has the app's role as its owner.
app_role_owner_catalogs=(
  "pg_class|relowner|o.relnamespace NOT IN ($temporary_schemas)"
  "pg_type|typowner|o.typnamespace NOT IN ($temporary_schemas)"
  "pg_proc|proowner|o.pronamespace NOT IN ($temporary_schemas)"
  "pg_namespace|nspowner|nspname <> 'public' AND o.oid NOT IN ($temporary_schemas)"
  'pg_collation|collowner|true' 'pg_conversion|conowner|true'
  'pg_operator|oprowner|true' 'pg_opclass|opcowner|true' 'pg_opfamily|opfowner|true' 'pg_ts_config|cfgowner|true'
  'pg_ts_dict|dictowner|true' 'pg_statistic_ext|stxowner|true' 'pg_language|lanowner|true'
  'pg_largeobject_metadata|lomowner|true' 'pg_foreign_data_wrapper|fdwowner|true' 'pg_foreign_server|srvowner|true'
  'pg_event_trigger|evtowner|true' 'pg_publication|pubowner|true'
  "pg_subscription|subowner|subdbid = (SELECT oid FROM pg_database WHERE datname = current_database())"
  "pg_database|datdba|datname = current_database()"
)

# server_psql <namespace> <port> <login> <psql option>...: psql over the container's loopback to the server on the
# port, as the login, which the container's local trust admits without a password.
server_psql() {
  local namespace="$1" port="$2" login="$3"
  shift 3
  postgres_psql "$namespace" --host=127.0.0.1 --port="$port" --username="$login" "$@"
}

# over_the_pod_address <namespace> <port> <login> <with|without>: the login's current_user over the Pod's own address,
# with the Secret's password read inside the container, which never prints it, or without one; fails when refused.
over_the_pod_address() {
  kubectl --namespace "$1" exec postgres-0 --container postgres -- sh -c '
    address="$(hostname -i | cut -d " " -f1)"
    if [ "$3" = with ]; then PGPASSWORD="$(cat /run/secrets/postgres/password)"; export PGPASSWORD; fi
    psql --host="$address" --port="$1" --username="$2" --no-password --no-psqlrc --tuples-only --no-align \
      --command="SELECT current_user"' sh "$2" "$3" "$4"
}

# app_role_failures <namespace> <port>: one line for each way the server on the port departs from the state app_role.sh
# keeps for the role named like the namespace: the bootstrap role named postgres without a password, the app's role as
# declared, its database and every object in it its own, and the network's answers to both roles.
app_role_failures() {
  local namespace="$1" port="$2" bootstrap comment declared foreign entry catalog column condition
  bootstrap="$(server_psql "$namespace" "$port" postgres \
    --command="SELECT format('%s:%s', rolname, rolpassword IS NULL) FROM pg_authid WHERE oid = 10")" ||
    { echo "the server on port $port cannot be read as postgres"; return 0; }
  [ "$bootstrap" = postgres:t ] || echo "the bootstrap role reads '$bootstrap', not postgres without a password"
  comment="$(kubectl --namespace "$namespace" exec postgres-0 --container postgres -- \
    sed -n "s/^comment='\(.*\)'\$/\1/p" /etc/postgres-roles/app_role.sh)"
  [ -n "$comment" ] || { echo "app_role.sh declares no comment"; return 0; }
  declared="$(server_psql "$namespace" "$port" postgres --command="SELECT coalesce(string_agg(name, ', ') FILTER (WHERE NOT ok), '')
    FROM pg_authid a, LATERAL (VALUES
      (a.rolcanlogin AND a.rolinherit AND NOT a.rolsuper AND NOT a.rolcreatedb AND NOT a.rolcreaterole
        AND NOT a.rolreplication AND NOT a.rolbypassrls, 'an attribute other than the declared ones'),
      (a.rolpassword IS NOT NULL, 'no password'),
      (shobj_description(a.oid, 'pg_authid') = '$comment', 'no declaration of app_role.sh'),
      (NOT EXISTS (SELECT FROM pg_auth_members WHERE member = a.oid), 'a membership'),
      ((SELECT datdba FROM pg_database WHERE datname = current_database()) = a.oid, 'not the owner of its database'),
      (has_database_privilege(a.oid, current_database(), 'CONNECT')
        AND has_database_privilege(a.oid, current_database(), 'TEMPORARY'), 'no CONNECT or TEMPORARY on its database'),
      (has_schema_privilege(a.oid, 'public', 'CREATE'), 'no CREATE on public'),
      (NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role_transfer'), 'app_role_transfer beside it')
    ) AS condition (ok, name)
    WHERE a.rolname = '$namespace'")" || { echo "the role $namespace cannot be read"; return 0; }
  [ -z "$declared" ] || echo "the role $namespace has: $declared"
  for entry in "${app_role_owner_catalogs[@]}"; do
    IFS='|' read -r catalog column condition <<<"$entry"
    foreign="$(server_psql "$namespace" "$port" postgres --command="SELECT count(*) FROM $catalog o
      WHERE o.oid >= 16384 AND $condition AND o.$column <> '$namespace'::regrole
        AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid = '$catalog'::regclass AND d.objid = o.oid AND d.deptype = 'e')")" ||
      { echo "$catalog cannot be read"; continue; }
    [ "$foreign" = 0 ] || echo "$foreign rows of $catalog have an owner other than $namespace"
  done
  [ "$(over_the_pod_address "$namespace" "$port" "$namespace" with 2>/dev/null)" = "$namespace" ] ||
    echo "$namespace does not log in over the Pod's address with the Secret's password"
  for password in with without; do
    if over_the_pod_address "$namespace" "$port" postgres "$password" >/dev/null 2>&1; then
      echo "postgres logged in over the Pod's address $password a password"
    fi
  done
}
