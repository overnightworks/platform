#!/bin/sh
# reader_role.sh keep | read: the role reader of this server's database, its one declaration and its one session.
#   keep  declares the role: no password, no right but pg_read_all_data's, so the server refuses it every write and
#         every object. It runs at each start of the container and ends 0 whatever it finds, since a hook that fails
#         or hangs keeps Postgres from running while a missing role harms no state; read then refuses.
#   read  runs the SQL on stdin as the role through the container's local trust, in a read-only session whose
#         timeouts it sets itself, after it has found the session to be the declared role.
set -eu
here="$(dirname "$0")"
role=reader
comment='declared by infrastructure/postgres/scripts/reader_role.sh'
connections="$(cat "$here/connections")"
wait_seconds=300

keep() {
  # The hook's own stderr reaches no log; the container's does.
  [ ! -w /proc/1/fd/2 ] || exec 2>/proc/1/fd/2
  attempts=0
  # The first start's server listens on no TCP port, so the wait ends only when the final server answers.
  until pg_isready --host=127.0.0.1 --quiet; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$wait_seconds" ]; then
      echo "reader_role.sh keep: no server answered on 127.0.0.1 within $wait_seconds seconds; the role $role is not declared" >&2
      return 0
    fi
    sleep 1
  done
  # client_min_messages keeps the NOTICE of a grant the role already holds out of the log.
  if ! PGOPTIONS='-c lock_timeout=2s -c statement_timeout=10s -c client_min_messages=warning' \
    psql --host=127.0.0.1 --no-psqlrc --quiet \
    --set=ON_ERROR_STOP=1 --single-transaction --set=role="$role" --set=comment="$comment" \
    --set=connections="$connections" --set=database="$PGDATABASE" --file=- <<'SQL'
WITH existing AS (SELECT oid FROM pg_roles WHERE rolname = :'role')
SELECT NOT EXISTS (SELECT FROM existing) AS missing,
  coalesce((SELECT shobj_description(oid, 'pg_authid') = :'comment' FROM existing), false) AS ours \gset
SELECT :'missing'::boolean OR :'ours'::boolean AS declared \gset
\if :missing
  CREATE ROLE :"role";
\endif
\if :declared
  ALTER ROLE :"role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT PASSWORD NULL
    CONNECTION LIMIT :connections;
  COMMENT ON ROLE :"role" IS :'comment';
  ALTER ROLE :"role" RESET ALL;
  ALTER ROLE :"role" IN DATABASE :"database" RESET ALL;
  GRANT pg_read_all_data TO :"role";
  REVOKE TEMPORARY ON DATABASE :"database" FROM PUBLIC;
\else
  \warn reader_role.sh keep: a role :role that this script did not declare exists; it is left as it is
\endif
SQL
  then
    echo "reader_role.sh keep: declaring the role $role failed; read refuses until the next start declares it" >&2
  fi
}

read_as_role() {
  PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=10s -c lock_timeout=2s
    -c idle_in_transaction_session_timeout=10s -c transaction_timeout=30s'
  export PGOPTIONS
  key="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  {
    # Without pg_read_all_data the role cannot read pg_authid, so that case is named before the query that needs it.
    cat <<'SQL'
\set membership_failed 'the role is not a member of pg_read_all_data alone'
SELECT pg_has_role(current_user, 'pg_read_all_data', 'MEMBER') AS member \gset
\if :member
WITH declared AS (SELECT * FROM pg_authid WHERE rolname = current_user)
SELECT coalesce(string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE), '') AS failed
FROM declared, LATERAL (VALUES
  (current_user = :'role', 'the session is not the role'),
  (shobj_description(declared.oid, 'pg_authid') IS NOT DISTINCT FROM :'comment', 'the role carries no declaration of reader_role.sh'),
  (rolcanlogin AND rolinherit AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication
    AND NOT rolbypassrls, 'the role has an attribute other than the declared ones'),
  (rolpassword IS NULL, 'the role has a password'),
  (rolconnlimit = :connections, 'the role has another connection limit'),
  ((SELECT array_agg(DISTINCT roleid::regrole::text) FROM pg_auth_members WHERE member = declared.oid)
    = ARRAY['pg_read_all_data'], :'membership_failed'),
  (current_setting('transaction_read_only') = 'on', 'the transaction is not read-only'),
  (NOT EXISTS (SELECT FROM pg_namespace WHERE has_schema_privilege(oid, 'CREATE')), 'the role can create in a schema'),
  (NOT has_database_privilege(current_database(), 'CREATE') AND NOT has_database_privilege(current_database(), 'TEMPORARY'),
    'the role can create in the database or use temporary objects')
) AS condition (ok, name) \gset
\else
\set failed :membership_failed
\endif
SQL
    # From here the session runs no meta-command of the SQL until its key is given, which only this script knows: \!
    # and \copy would run a shell in this container, where local trust reaches the superuser.
    printf '\\restrict %s\n' "$key"
    cat <<'SQL'
SET LOCAL reader.failed = :'failed';
DO $$
BEGIN
  IF current_setting('reader.failed') <> '' THEN
    RAISE EXCEPTION 'reader_role.sh read: the session is not the declared role: %', current_setting('reader.failed');
  END IF;
END
$$;
SQL
    cat
  } | psql --no-psqlrc --quiet --username="$role" --set=ON_ERROR_STOP=1 --single-transaction --set=role="$role" \
    --set=comment="$comment" --set=connections="$connections" --file=-
}

case "${1-}" in
  keep) keep ;;
  read) read_as_role ;;
  *) echo "usage: reader_role.sh keep | read" >&2; exit 2 ;;
esac
