#!/usr/bin/env bash
# Proves docs/app.md's sticky cookie through Traefik on two throwaway pods: the nginx image and command of legal's
# Deployment, and the annotations of legal's Service, which the cell reads from legal.yaml. A Pod in the tunnel's
# namespace sends the requests. Needs STICKY_NAMESPACE (the throwaway namespace) and TUNNEL_NAMESPACE.
set -euo pipefail
# shellcheck source=../client_pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../client_pod.sh"

legal=infrastructure/legal/legal.yaml
host=sticky.invalid
run="$RANDOM$RANDOM"
client_names=()
cleanup() {
  local cell_status=$? name
  for name in "${client_names[@]}"; do
    delete_object --namespace "$TUNNEL_NAMESPACE" delete pod "$name" --ignore-not-found --wait --timeout=2m
  done
  delete_object delete namespace --ignore-not-found --wait --timeout=2m "$STICKY_NAMESPACE"
  end_deletions "$cell_status"
}
trap 'cleanup' EXIT

annotations="$(yq 'select(.kind == "Service") | .metadata.annotations' "$legal")"
annotation() { yq ".\"traefik.ingress.kubernetes.io/service.sticky.cookie$1\"" <<<"$annotations"; }
cookie_name="$(annotation .name)"
image="$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$legal")"
command_json="$(yq --output-format json --indent 0 'select(.kind == "Deployment") | .spec.template.spec.containers[0].command' "$legal")"

kubectl create namespace "$STICKY_NAMESPACE"
kubectl label namespace "$STICKY_NAMESPACE" pod-security.kubernetes.io/enforce=restricted
manifest="$(cat <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pods
spec:
  replicas: 2
  selector:
    matchLabels: {app: pods}
  template:
    metadata:
      labels: {app: pods}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: nginx
          image: "@IMAGE@"
          command: @COMMAND@
          ports:
            - {name: http, containerPort: 8080}
          readinessProbe:
            httpGet: {path: /, port: http}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: temporary, mountPath: /tmp}
      volumes:
        - {name: temporary, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata:
  name: pods
spec:
  selector: {app: pods}
  ports:
    - {name: http, port: 8080, targetPort: http}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pods
spec:
  ingressClassName: traefik
  rules:
    - host: "@HOST@"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: pods
                port: {number: 8080}
YAML
)"
manifest="${manifest//@IMAGE@/$image}"
manifest="${manifest//@COMMAND@/$command_json}"
manifest="${manifest//@HOST@/$host}"
ANNOTATIONS="$annotations" yq '(select(.kind == "Service") | .metadata.annotations) = (strenv(ANNOTATIONS) | from_yaml)' <<<"$manifest" |
  kubectl --namespace "$STICKY_NAMESPACE" apply -f -
kubectl --namespace "$STICKY_NAMESPACE" wait deployment/pods --for=condition=Available --timeout=3m
mapfile -t pods < <(kubectl --namespace "$STICKY_NAMESPACE" get pods --selector app=pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ "${#pods[@]}" = 2 ] || fail "the Deployment pods runs ${#pods[@]} pods, not two"

web_port="$(kubectl --namespace traefik get service traefik -o jsonpath='{.spec.ports[?(@.name=="web")].port}')"
traefik_origin="http://traefik.traefik.svc:${web_port}"
counter=0

# ask <path> [<cookie value>]: a client Pod asks Traefik for the path with the host, with the cookie when given; sets
# reply to the response with its headers, without carriage returns, and answer_status to its status.
# shellcheck disable=SC2034 # reply and answer_status are what the cells below read.
ask() {
  local path="$1" cookie_arguments=()
  [ -z "${2:-}" ] || cookie_arguments=(--header "Cookie: $cookie_name=$2")
  counter=$((counter + 1))
  client_names+=("sticky-client-$counter")
  request_body "$TUNNEL_NAMESPACE" "sticky-client-$counter" "$host" "$traefik_origin$path" --include "${cookie_arguments[@]}"
  [ "$exit_code" = 0 ] || fail "the request for $path ended with curl's exit code $exit_code"
  reply="$(tr -d '\r' <<<"$status")"
  answer_status="$(awk 'NR == 1 { print $2 }' <<<"$reply")"
}

# cookie_header: the Set-Cookie line of the last reply, which may be none.
cookie_header() { grep -i '^set-cookie:' <<<"$reply" || true; }

# The pods are Ready, so a 404 only means Traefik has not read the Ingress yet.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  ask "/warm-$run-$attempt"
  [ "$answer_status" != 404 ] || { sleep 3; continue; }
  [ -n "$(cookie_header)" ] || { sleep 3; continue; }
  break
done
[ "$answer_status" = 200 ] || fail "a Pod in $TUNNEL_NAMESPACE got '$answer_status' through Traefik for $host, not 200"
echo "Traefik routes $host to the two pods"

# Requests with no cookie reach both pods: two distinct cookie values come back.
values=()
for attempt in 1 2 3 4 5 6; do
  ask "/fresh-$run-$attempt"
  value="$(cookie_header | sed -n "s/^[Ss]et-[Cc]ookie: $cookie_name=\([^;]*\).*/\1/p")"
  [ -n "$value" ] || fail "the answer to a request with no cookie set no cookie named $cookie_name"
  values+=("$value")
done
mapfile -t distinct < <(printf '%s\n' "${values[@]}" | sort -u)
[ "${#distinct[@]}" -ge 2 ] || fail "six requests with no cookie got ${#distinct[@]} cookie value, not two"
echo "requests with no cookie got ${#distinct[@]} distinct cookie values"

# pod_hits <path>: the pods' names that logged a request for the path, each with its count.
pod_hits() {
  local pod hits
  for pod in "${pods[@]}"; do
    hits="$(kubectl --namespace "$STICKY_NAMESPACE" logs "$pod" | grep -cF "\"GET $1 " || true)"
    [ "$hits" = 0 ] || echo "$pod $hits"
  done
}

# run_with_cookie <label> <value>: five requests with the cookie reach one pod alone, which is named on stdout.
run_with_cookie() {
  local attempt hits
  for attempt in 1 2 3 4 5; do ask "/$1-$run" "$2"; done
  hits="$(pod_hits "/$1-$run")"
  [ "$(wc -l <<<"$hits")" = 1 ] && [ "${hits##* }" = 5 ] ||
    fail "five requests with the cookie $1 reached '${hits//$'\n'/, }', not one pod alone"
  echo "${hits% *}"
}
first_pod="$(run_with_cookie first "${distinct[0]}" | tail -n 1)"
second_pod="$(run_with_cookie second "${distinct[1]}" | tail -n 1)"
[ "$first_pod" != "$second_pod" ] || fail "the two cookie values both reached $first_pod"
echo "five requests with each of two cookies reached one pod each, $first_pod and $second_pod"

# The Set-Cookie follows the annotations and is host-only and session-long.
ask "/attributes-$run"
header="$(cookie_header)"
grep -qiE "^set-cookie: $cookie_name=" <<<"$header" || fail "the Set-Cookie '$header' does not name $cookie_name"
[ "$(annotation .secure)" != true ] || grep -qi '; Secure\(;\|$\)' <<<"$header" || fail "the Set-Cookie '$header' is not Secure"
[ "$(annotation .httponly)" != true ] || grep -qi '; HttpOnly\(;\|$\)' <<<"$header" || fail "the Set-Cookie '$header' is not HttpOnly"
grep -qi "; SameSite=$(annotation .samesite)\(;\|\$\)" <<<"$header" || fail "the Set-Cookie '$header' does not carry SameSite=$(annotation .samesite)"
grep -qi '; Path=/\(;\|$\)' <<<"$header" || fail "the Set-Cookie '$header' does not carry Path=/"
! grep -qiE '; (Domain|Max-Age|Expires)=' <<<"$header" || fail "the Set-Cookie '$header' carries a Domain, Max-Age or Expires"
echo "the Set-Cookie names $cookie_name with the annotated SameSite, Secure, HttpOnly and Path=/, and no Domain, Max-Age or Expires"
