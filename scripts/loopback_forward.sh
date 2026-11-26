# shellcheck shell=bash
# Sourced by the tasks that reach a Service of the cluster through kubectl's port-forward on this PC's loopback (the
# task page:forward, scripts/live_check_report.sh and scripts/litellm_keys.sh): the one reader of what kubectl says and
# the one starter of a background forward.

# The longest a read of the cluster runs before it is cut, so one stuck call holds no task for long.
read_timeout_seconds=20

# service_port <service>: the first port of the Service, which sits in the namespace of its own name; nothing and a
# non-zero status when the read fails or outlasts read_timeout_seconds.
service_port() {
  timeout --foreground "$read_timeout_seconds" kubectl --namespace "$1" get service "$1" -o jsonpath='{.spec.ports[0].port}'
}

# forwarded_port <line>: the local port that kubectl's `Forwarding from 127.0.0.1:<port> -> <port>` line names, and
# nothing for any other line.
forwarded_port() {
  sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) ->.*/\1/p' <<<"$1"
}

# The longest a background forward lives; a command that runs longer sets a limit past its run before it connects.
forward_limit=10m
forward_pid=""
forward_port=""
# start_forward <namespace> <service> <port> <log>: forwards the Service in the background to a free local port, which it
# sets as forward_port once kubectl says it listens, with forward_pid; says nothing and returns 1 when it does not within
# 30 seconds or when kubectl ends first.
start_forward() {
  local line
  forward_port=""
  : >"$4"
  timeout "$forward_limit" kubectl --namespace "$1" port-forward "service/$2" ":$3" --address 127.0.0.1 >"$4" 2>&1 &
  forward_pid=$!
  for _ in $(seq 150); do
    while IFS= read -r line; do
      forward_port="$(forwarded_port "$line")"
      [ -z "$forward_port" ] || return 0
    done <"$4"
    kill -0 "$forward_pid" 2>/dev/null || break
    sleep 0.2
  done
  stop_forward
  return 1
}
# stop_forward: ends the forward of start_forward, if one runs.
stop_forward() {
  [ -z "$forward_pid" ] && return 0
  kill "$forward_pid" 2>/dev/null || true
  wait "$forward_pid" 2>/dev/null || true
  forward_pid=""
}
