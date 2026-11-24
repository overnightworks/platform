# shellcheck shell=bash
# Sourced by the tasks that reach a Service of the cluster through kubectl's port-forward on this PC's loopback (the
# task page:forward and scripts/live_check_report.sh): the one reader of what kubectl says.

# service_port <service>: the first port of the Service, which sits in the namespace of its own name.
service_port() {
  kubectl --namespace "$1" get service "$1" -o jsonpath='{.spec.ports[0].port}'
}

# forwarded_port <line>: the local port that kubectl's `Forwarding from 127.0.0.1:<port> -> <port>` line names, and
# nothing for any other line.
forwarded_port() {
  sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) ->.*/\1/p' <<<"$1"
}
