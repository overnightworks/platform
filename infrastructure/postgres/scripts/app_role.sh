#!/bin/sh
# app_role.sh keep: the app's role of this server, its one declaration. The role is named like the database ($PGUSER
# and $PGDATABASE), logs in with the password of the Secret postgres, owns the database and every object in it and is
# no superuser, so a flaw in the app reaches its own data and not the server. The server's bootstrap role is named
# postgres and has no password, so only the container's local trust reaches it.
#   keep  converges whatever it finds, at each start of the container once server_ready.sh found the server, and ends 0
#         whatever it finds, since a hook that fails or hangs keeps Postgres from running; an app whose role is not
#         declared fails loud. Every transaction runs under lock_timeout, statement_timeout and transaction_timeout,
#         so a lock that any session holds rolls it back within seconds and the next start tries again.
#         0. A transient superuser app_role_transfer, left by an interrupted run, is dropped.
#         1. A server whose bootstrap role is the app's role, as the image made it with POSTGRES_USER set to it, gets
#            the bootstrap role renamed postgres without a password and the app's role created anew, still a
#            superuser, so the app logs in as before whatever step 2 does. The rename needs another superuser's
#            session, which app_role_transfer is; the app's sessions of the bootstrap role end after it.
#         2. As postgres, in one transaction: the app's role is created if missing, gets its password and the
#            database, and every object of another owner moves to it; the transaction fails unless the ownership check
#            then finds no other owner, and only then does the role become no superuser.
set -eu
role="$PGUSER"
database="$PGDATABASE"
password_file=/run/secrets/postgres/password
comment='declared by infrastructure/postgres/scripts/app_role.sh'
transfer_role=app_role_transfer
# shellcheck source=keep_session.sh
. "$(dirname "$0")/keep_session.sh"

# The name of the bootstrap role: postgres where it was renamed or made so, else the app's role.
bootstrap_name() {
  for login in postgres "$role"; do
    if name="$(as_login "$login" --command='SELECT rolname FROM pg_roles WHERE oid = 10' 2>/dev/null)"; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

# drop_transfer_role <superuser>
drop_transfer_role() {
  as_login "$1" --command="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '$transfer_role'" >/dev/null &&
    as_login "$1" --command="DROP ROLE IF EXISTS $transfer_role"
}

# settle <stage>: the SQL of steps 1 and 2 on stdin of psql. The password never reaches an argument, and a statement's
# text never reaches the server's log. Stage transfer renames the bootstrap role and leaves the app's role a superuser;
# stage settle moves every object to the app's role and makes it no superuser.
settle() {
  as_login "$1" --single-transaction --set=stage="$2" --set=role="$role" --set=database="$database" \
    --set=comment="$comment" --file=- <<'SQL'
SELECT :'stage' = 'transfer' AS transfer \gset
\set password `cat /run/secrets/postgres/password`
\if :transfer
  ALTER ROLE :"role" RENAME TO postgres;
\endif
ALTER ROLE postgres PASSWORD NULL;
WITH existing AS (SELECT oid FROM pg_roles WHERE rolname = :'role')
SELECT NOT EXISTS (SELECT FROM existing) AS missing,
  coalesce((SELECT shobj_description(oid, 'pg_authid') = :'comment' FROM existing), false) AS ours \gset
SELECT :'missing'::boolean OR :'ours'::boolean AS declared \gset
\if :missing
  CREATE ROLE :"role" LOGIN SUPERUSER;
\endif
\if :declared
  ALTER ROLE :"role" PASSWORD :'password';
  COMMENT ON ROLE :"role" IS :'comment';
  ALTER DATABASE :"database" OWNER TO :"role";
  \if :transfer
  \else
    SELECT oid AS app_oid FROM pg_roles WHERE rolname = :'role' \gset
    -- Outside the scope are the objects initdb made (oid below 16384), the system schemas, any session's temporary
    -- schemas and the members of an extension.
    CREATE FUNCTION pg_temp.in_scope(catalog regclass, object_oid oid, schema_oid oid) RETURNS boolean
      LANGUAGE sql STABLE AS $$
        SELECT object_oid >= 16384
          AND NOT EXISTS (SELECT FROM pg_namespace WHERE oid = schema_oid
            AND (nspname IN ('pg_catalog', 'information_schema', 'pg_toast') OR nspname ~ '^pg_(toast_)?temp_'))
          AND NOT EXISTS (SELECT FROM pg_depend WHERE classid = catalog AND objid = object_oid AND deptype = 'e')
      $$;
    SELECT format('ALTER %s %I.%I OWNER TO %I',
      CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE'
        WHEN 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, n.nspname, c.relname, :'role')
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S') AND c.relowner <> :app_oid
      AND pg_temp.in_scope('pg_class', c.oid, c.relnamespace)
      AND NOT (c.relkind = 'S' AND EXISTS (SELECT FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
        AND d.objid = c.oid AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i'))) \gexec
    SELECT format('ALTER %s %I.%I OWNER TO %I', CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, n.nspname,
      t.typname, :'role')
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typowner <> :app_oid AND pg_temp.in_scope('pg_type', t.oid, t.typnamespace)
      AND (t.typtype IN ('e', 'd', 'r')
        OR (t.typtype = 'c' AND EXISTS (SELECT FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c'))) \gexec
    SELECT format('ALTER ROUTINE %s OWNER TO %I', oid::regprocedure, :'role') FROM pg_proc
    WHERE proowner <> :app_oid AND pg_temp.in_scope('pg_proc', oid, pronamespace) \gexec
    SELECT format('ALTER SCHEMA %I OWNER TO %I', nspname, :'role') FROM pg_namespace
    WHERE nspowner <> :app_oid AND nspname <> 'public' AND pg_temp.in_scope('pg_namespace', oid, oid) \gexec
    -- The kinds the moves above do not reach, which the check refuses until the moves gain them.
    SELECT coalesce((SELECT kind FROM (
      SELECT 1 AS position, 'relation' AS kind FROM pg_class
        WHERE relowner <> :app_oid AND pg_temp.in_scope('pg_class', oid, relnamespace)
      UNION ALL SELECT 2, 'type' FROM pg_type
        WHERE typowner <> :app_oid AND pg_temp.in_scope('pg_type', oid, typnamespace)
      UNION ALL SELECT 3, 'routine' FROM pg_proc
        WHERE proowner <> :app_oid AND pg_temp.in_scope('pg_proc', oid, pronamespace)
      UNION ALL SELECT 4, 'schema' FROM pg_namespace
        WHERE nspowner <> :app_oid AND NOT (nspname = 'public' AND nspowner = 'pg_database_owner'::regrole)
          AND pg_temp.in_scope('pg_namespace', oid, oid)
      UNION ALL SELECT 5, 'collation' FROM pg_collation
        WHERE collowner <> :app_oid AND pg_temp.in_scope('pg_collation', oid, collnamespace)
      UNION ALL SELECT 6, 'conversion' FROM pg_conversion
        WHERE conowner <> :app_oid AND pg_temp.in_scope('pg_conversion', oid, connamespace)
      UNION ALL SELECT 7, 'operator' FROM pg_operator
        WHERE oprowner <> :app_oid AND pg_temp.in_scope('pg_operator', oid, oprnamespace)
      UNION ALL SELECT 8, 'operator class' FROM pg_opclass
        WHERE opcowner <> :app_oid AND pg_temp.in_scope('pg_opclass', oid, opcnamespace)
      UNION ALL SELECT 9, 'operator family' FROM pg_opfamily
        WHERE opfowner <> :app_oid AND pg_temp.in_scope('pg_opfamily', oid, opfnamespace)
      UNION ALL SELECT 10, 'text search configuration' FROM pg_ts_config
        WHERE cfgowner <> :app_oid AND pg_temp.in_scope('pg_ts_config', oid, cfgnamespace)
      UNION ALL SELECT 11, 'text search dictionary' FROM pg_ts_dict
        WHERE dictowner <> :app_oid AND pg_temp.in_scope('pg_ts_dict', oid, dictnamespace)
      UNION ALL SELECT 12, 'extended statistics object' FROM pg_statistic_ext
        WHERE stxowner <> :app_oid AND pg_temp.in_scope('pg_statistic_ext', oid, stxnamespace)
      UNION ALL SELECT 13, 'language' FROM pg_language
        WHERE lanowner <> :app_oid AND pg_temp.in_scope('pg_language', oid, 0)
      UNION ALL SELECT 14, 'large object' FROM pg_largeobject_metadata
        WHERE lomowner <> :app_oid AND pg_temp.in_scope('pg_largeobject_metadata', oid, 0)
      UNION ALL SELECT 15, 'foreign-data wrapper' FROM pg_foreign_data_wrapper
        WHERE fdwowner <> :app_oid AND pg_temp.in_scope('pg_foreign_data_wrapper', oid, 0)
      UNION ALL SELECT 16, 'foreign server' FROM pg_foreign_server
        WHERE srvowner <> :app_oid AND pg_temp.in_scope('pg_foreign_server', oid, 0)
      UNION ALL SELECT 17, 'event trigger' FROM pg_event_trigger
        WHERE evtowner <> :app_oid AND pg_temp.in_scope('pg_event_trigger', oid, 0)
      UNION ALL SELECT 18, 'publication' FROM pg_publication
        WHERE pubowner <> :app_oid AND pg_temp.in_scope('pg_publication', oid, 0)
      UNION ALL SELECT 19, 'subscription' FROM pg_subscription
        WHERE subowner <> :app_oid AND subdbid = (SELECT oid FROM pg_database WHERE datname = :'database')
      UNION ALL SELECT 20, 'database' FROM pg_database WHERE datname = :'database' AND datdba <> :app_oid
    ) found ORDER BY position LIMIT 1), '') AS unowned \gset
    SET LOCAL app_role.unowned = :'unowned';
    DO $$
    BEGIN
      IF current_setting('app_role.unowned') <> '' THEN
        RAISE EXCEPTION 'app_role.sh keep: the database holds a % of another owner, which this script does not move',
          current_setting('app_role.unowned');
      END IF;
    END
    $$;
    SELECT format('REVOKE %s FROM %I', roleid::regrole, :'role') FROM pg_auth_members WHERE member = :app_oid \gexec
    ALTER ROLE :"role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT;
  \endif
\else
  \warn app_role.sh keep: a role :role that this script did not declare exists; it is left as it is
\endif
SQL
}

# Step 1: the app's role is the bootstrap role. Whatever fails leaves the server as it was, or with the new role a
# superuser, so every login of the app works.
transfer() {
  as_login "$role" --command="CREATE ROLE $transfer_role SUPERUSER LOGIN" &&
    settle "$transfer_role" transfer &&
    as_login "$transfer_role" --command="SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE usesysid = 10 AND backend_type = 'client backend' AND pid <> pg_backend_pid()" >/dev/null &&
    as_login postgres --command="DROP ROLE $transfer_role"
}

keep() {
  [ -s "$password_file" ] || { echo "app_role.sh keep: $password_file is missing or empty; the role $role is not declared" >&2; return 0; }
  bootstrap="$(bootstrap_name)" || { echo "app_role.sh keep: neither postgres nor $role reaches the server; the role $role is not declared" >&2; return 0; }
  drop_transfer_role "$bootstrap" || echo "app_role.sh keep: dropping the role $transfer_role failed" >&2
  case "$bootstrap" in
    postgres) ;;
    "$role")
      if ! transfer; then
        echo "app_role.sh keep: renaming the bootstrap role $role to postgres failed; the role stays as it is" >&2
        as_login "$role" --command="DROP ROLE IF EXISTS $transfer_role" || true
        return 0
      fi ;;
    *) echo "app_role.sh keep: the bootstrap role is named $bootstrap, not postgres or $role; the role $role is not declared" >&2; return 0 ;;
  esac
  settle postgres settle ||
    echo "app_role.sh keep: declaring the role $role failed; it keeps its attributes and its objects as they are" >&2
}

case "${1-}" in
  keep) keep ;;
  *) echo "usage: app_role.sh keep" >&2; exit 2 ;;
esac
