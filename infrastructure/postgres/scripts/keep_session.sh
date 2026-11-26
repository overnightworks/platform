# keep_session.sh: sourced by app_role.sh and reader_role.sh, the scripts that declare a role at each start; defines
# as_login only, the one session of a keep.
# as_login <login> <psql option>...: psql as the login through the container's local trust. Every transaction runs
# under lock_timeout, statement_timeout and transaction_timeout, so a lock that any session holds rolls it back within
# seconds. client_min_messages keeps the NOTICE of a grant the role already holds out of the log, and
# log_min_error_statement keeps a statement's text, which may hold a password, out of it.
as_login() {
  login="$1"
  shift
  PGOPTIONS='-c lock_timeout=2s -c statement_timeout=10s -c transaction_timeout=30s -c client_min_messages=warning
    -c log_min_error_statement=panic' \
    psql --host=127.0.0.1 --username="$login" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 "$@"
}
