#!/bin/sh
# server_ready.sh: ends 0 once the server answers on 127.0.0.1 and 1, with one line on stderr, when none does within
# the bound. The postStart hook runs the scripts that declare the roles only after it, since a hook that fails or hangs
# keeps Postgres from running while a missing role harms no state.
set -eu
wait_seconds=300
attempts=0
# The first start's server listens on no TCP port, so the wait ends only when the final server answers.
until pg_isready --host=127.0.0.1 --quiet; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$wait_seconds" ]; then
    echo "server_ready.sh: no server answered on 127.0.0.1 within $wait_seconds seconds; the roles are not declared" >&2
    exit 1
  fi
  sleep 1
done
