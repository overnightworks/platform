#!/usr/bin/env bash
# pods_stay_within_their_levels.sh <rendered manifest>: holds presentator's pods to the levels they may run at, on any
# cluster with `kubectl` and `yq` and no layer of ours. The argument is `kubectl kustomize` of apps/presentator, or of
# an overlay that changes only its images or class. Each Pod template of the render becomes a Pod, created with
# --dry-run=server in throwaway Namespaces that enforce the level: every template but the build worker's at
# restricted, the worker's at baseline once the init container's NET_ADMIN is removed from the copy. The rest of the
# contract is read from the render, and each rule is proven by mutants: a copy of the render changed to break exactly
# that rule must make the check name it, or the script fails.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=../no_network/pod.sh
source "$(dirname "${BASH_SOURCE[0]}")/../no_network/pod.sh"

[ $# -eq 1 ] && [ -f "$1" ] || fail "usage: $0 <rendered manifest>"
rendered="$1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
restricted_namespace=presentator-levels-restricted
baseline_namespace=presentator-levels-baseline

work="$(mktemp -d)"
created_namespaces=()
remove_objects() {
  local cell_status=$?
  rm -rf "$work"
  for namespace in "${created_namespaces[@]}"; do
    delete_object delete namespace --wait --timeout=2m "$namespace"
  done
  end_deletions "$cell_status"
}
trap remove_objects EXIT

# A Pod of every template: a Deployment, StatefulSet or other workload, a CronJob or a Pod itself; k8up's PodConfig is a
# partial template merged over its Job pods, with a container and no image, so it is none.
SPECS='(select(.kind != "PodConfig") | .spec.template.spec // .spec.jobTemplate.spec.template.spec // (select(.kind == "Pod") | .spec))'
ANNOTATIONS='(.spec.template.metadata.annotations // .spec.jobTemplate.spec.template.metadata.annotations // (select(.kind == "Pod") | .metadata.annotations))'
POD_OF="$SPECS as \$spec | $ANNOTATIONS as \$annotations | select(\$spec != null) | {\"apiVersion\": \"v1\", \"kind\": \"Pod\", \"metadata\": ({\"name\": .metadata.name} + (if \$annotations == null then {} else {\"annotations\": \$annotations} end)), \"spec\": \$spec}"
WORKER_KEY=StatefulSet/build-worker
WORKER_DOCUMENT=".kind + \"/\" + .metadata.name == \"$WORKER_KEY\""
WORKER="select($WORKER_DOCUMENT) | .spec.template.spec"
WEB='select(.kind == "Deployment" and .metadata.name == "web") | .spec.template.spec'
WORKER_CONTAINER="$WORKER | .containers[] | select(.name == \"worker\")"
NET_ADMIN_HOLDER='select((.securityContext.capabilities.add // []) | any_c(. == "NET_ADMIN")) | .name'

# The Namespaces and the ServiceAccounts the Pods name, which the API server's admission needs to exist.
for level in restricted baseline; do
  namespace="presentator-levels-$level"
  kubectl create namespace "$namespace"
  created_namespaces+=("$namespace")
  kubectl label namespace "$namespace" "pod-security.kubernetes.io/enforce=$level"
  kubectl -n "$namespace" wait serviceaccount/default --for=create --timeout=1m
  for account in $(yq --no-doc "$SPECS | .serviceAccountName | select(. != null)" "$rendered"); do
    kubectl -n "$namespace" create serviceaccount "$account"
  done
done

# admit <namespace> <Pod>: succeeds when --dry-run=server creates the Pod there; admit_output holds the answer.
admit() { admit_output="$(kubectl -n "$1" create --dry-run=server -f - <<<"$2" 2>&1)"; }

# judge_levels <manifest>: prints a problem line for each Pod that its level refuses and for a worker that the
# unchanged copy's NET_ADMIN does not make baseline refuse.
judge_levels() {
  local manifest="$1" name pod copy
  for name in $(yq --no-doc "select($SPECS != null) | .kind + \"/\" + .metadata.name" "$manifest"); do
    pod="$(yq "select(.kind + \"/\" + .metadata.name == \"$name\") | $POD_OF" "$manifest")"
    if [ "$name" = "$WORKER_KEY" ]; then
      copy="$(yq 'del(.spec.initContainers[].securityContext.capabilities.add[] | select(. == "NET_ADMIN"))' <<<"$pod")"
      admit "$baseline_namespace" "$copy" ||
        echo "problem: the worker without its init's NET_ADMIN is refused at baseline: $admit_output"
      if admit "$baseline_namespace" "$pod"; then
        echo "problem: the worker with its init's NET_ADMIN is admitted at baseline, so NET_ADMIN is not what makes it need an exception"
      elif [[ $admit_output != *NET_ADMIN* ]]; then
        echo "problem: baseline refuses the worker without naming NET_ADMIN: $admit_output"
      fi
    else
      admit "$restricted_namespace" "$pod" ||
        echo "problem: the Pod ${name#*/} is refused at restricted: $admit_output"
    fi
  done
}

# Each rule below reads the render with yq over one document at a time. found prints the problem when the expression
# prints anything; exactly prints it unless the values the expression prints, as one-line JSON joined by commas, are
# the expected text.
found() { [ -z "$(yq --no-doc "$3" "$1" 2>&1)" ] || echo "problem: $2"; }
exactly() { [ "$(yq --no-doc -o=json -I=0 "$3" "$1" 2>&1 | paste -sd,)" = "$4" ] || echo "problem: $2"; }

# judge_structure <manifest>: prints a problem line for each rule of the contract that the render breaks.
judge_structure() {
  local manifest="$1" probe_image reference actual web_group worker_group
  # NET_ADMIN sits in the one finishing init container.
  exactly "$manifest" "a container other than remove-link holds NET_ADMIN" \
    "$WORKER | [.initContainers[], .containers[]][] | $NET_ADMIN_HOLDER" '"remove-link"'
  exactly "$manifest" "the worker has a container besides worker" "$WORKER | .containers[].name" '"worker"'
  exactly "$manifest" "the worker has an init container besides remove-link" "$WORKER | .initContainers[].name" '"remove-link"'
  found "$manifest" "an init container of the worker restarts, which makes it a sidecar that runs beside the worker" \
    "$WORKER | .initContainers[] | select(has(\"restartPolicy\"))"
  # remove-link is the init container of tests/no_network/pod.sh, with the image its cell runs.
  probe_image="$(yq '.jobs.cluster.env.PROBE_IMAGE' "$root/.github/workflows/ci.yml")"
  reference="$(no_network_pod remove-link "$probe_image" init | yq '.spec.initContainers[0] | sort_keys(..) | to_json(0)')"
  actual="$(yq "$WORKER | .initContainers[0] | sort_keys(..) | to_json(0)" "$manifest")"
  [ "$actual" = "$reference" ] || echo "problem: remove-link differs from the init container of tests/no_network/pod.sh"
  # The worker adds exactly the capabilities of a controller that drops to its build users.
  exactly "$manifest" "the worker does not add exactly SETUID, SETGID and KILL" \
    "$WORKER_CONTAINER | .securityContext.capabilities.add | sort | join(\",\")" '"KILL,SETGID,SETUID"'
  exactly "$manifest" "the worker does not drop ALL capabilities" \
    "$WORKER_CONTAINER | .securityContext.capabilities.drop[]" '"ALL"'
  # Nothing of the host or the other pods is shared.
  found "$manifest" "a container of the worker is privileged" \
    "$WORKER | [.initContainers[], .containers[]][] | select(.securityContext.privileged == true)"
  for field in hostPID hostIPC hostNetwork shareProcessNamespace; do
    found "$manifest" "the worker sets $field" "$WORKER | select(.$field == true)"
  done
  # The worker keeps its seccomp profile and no privilege escalation.
  exactly "$manifest" "the worker's seccompProfile is not RuntimeDefault" \
    "$WORKER_CONTAINER | .securityContext.seccompProfile.type" '"RuntimeDefault"'
  exactly "$manifest" "the worker allows privilege escalation" \
    "$WORKER_CONTAINER | .securityContext.allowPrivilegeEscalation" 'false'
  # A worker container ends its pod at every exit: its own restart policy is Never, which no rule overrides.
  exactly "$manifest" "the worker container's restartPolicy is not exactly Never" "$WORKER_CONTAINER | .restartPolicy" '"Never"'
  found "$manifest" "the worker container has restartPolicyRules" "$WORKER_CONTAINER | select(has(\"restartPolicyRules\"))"
  # No pod holds a right in the API: the render holds no Role or binding of either kind.
  found "$manifest" "the render holds a Role, a RoleBinding, a ClusterRole or a ClusterRoleBinding" \
    'select(.kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding")'
  # The worker and the web hold no token.
  exactly "$manifest" "the worker mounts a ServiceAccount token" "$WORKER | .automountServiceAccountToken" 'false'
  found "$manifest" "the worker projects a ServiceAccount token" \
    "$WORKER | .volumes[] | select(.projected) | .projected.sources[] | select(has(\"serviceAccountToken\"))"
  exactly "$manifest" "the web does not turn the kubelet's ServiceAccount token automount off" "$WEB | .automountServiceAccountToken" 'false'
  found "$manifest" "the web projects a ServiceAccount token" \
    "$WEB | .volumes[] | select(.projected) | .projected.sources[] | select(has(\"serviceAccountToken\"))"
  # The web's Secret's files lie in one read-only volume.
  exactly "$manifest" "the web does not mount that volume read-only at /run/secrets" \
    "$WEB | .containers[0].volumeMounts[] | select(.name == \"secrets\") | .mountPath + \",\" + (.readOnly | to_string)" '"/run/secrets,true"'
  # Replicas, strategy, process sharing, fsGroup and exec probes.
  exactly "$manifest" "the web or the worker does not run one replica" \
    "select((.kind == \"Deployment\" and .metadata.name == \"web\") or ($WORKER_DOCUMENT)) | .spec.replicas" '1,1'
  exactly "$manifest" "the web's strategy is not Recreate" \
    'select(.kind == "Deployment" and .metadata.name == "web") | .spec.strategy.type' '"Recreate"'
  exactly "$manifest" "the web does not share its process namespace" "$WEB | .shareProcessNamespace" 'true'
  found "$manifest" "a template other than the web's shares its process namespace" \
    "select((.kind == \"Deployment\" and .metadata.name == \"web\") | not) | $SPECS | select(.shareProcessNamespace == true)"
  found "$manifest" "a template sets fsGroup" "$SPECS | select(.securityContext.fsGroup != null)"
  found "$manifest" "a container has an exec probe or a postStart hook" \
    "$SPECS | [.initContainers[], .containers[]][] | select(.livenessProbe.exec != null or .readinessProbe.exec != null or .startupProbe.exec != null or .lifecycle.postStart != null)"
  # The worker's group is the web's, and its command, seal and memory bound are set.
  web_group="$(yq --no-doc "$WEB | .securityContext.runAsGroup" "$manifest")"
  worker_group="$(yq --no-doc "$WORKER_CONTAINER | .securityContext.runAsGroup" "$manifest")"
  { [ "$web_group" != null ] && [ "$web_group" = "$worker_group" ]; } ||
    echo "problem: the worker's runAsGroup '$worker_group' is not the web's '$web_group'"
  exactly "$manifest" "the worker has no command" "$WORKER_CONTAINER | .command | length > 0" 'true'
  exactly "$manifest" "the worker's seal is not set" \
    "$WORKER_CONTAINER | .env[] | select(.name == \"PRESENTATOR_WORKER_SEAL\") | (.value // \"\") != \"\"" 'true'
  exactly "$manifest" "the worker has no memory limit" "$WORKER_CONTAINER | .resources.limits.memory != null" 'true'
}

judge() { judge_levels "$1"; judge_structure "$1"; }

problems="$(judge "$rendered")"
[ -z "$problems" ] || fail "the render breaks its contract: $problems"
echo "the web and every other template pass restricted, the worker passes baseline without its init's NET_ADMIN and is refused with it, and the render holds its contract"

# named_by <expected text> <description>: the mutant in $work/mutant.yaml must make the check
# print a problem that contains the text.
named_by() {
  problems="$(judge "$work/mutant.yaml")"
  [[ $problems == *"$1"* ]] || fail "the mutant '$2' did not make the check name '$1'; it named: ${problems:-nothing}"
  echo "the check names '$1' for the mutant: ${2:0:90}"
}
# mutant <expected text> <yq expression>: the render changed by the expression.
mutant() {
  yq "$2" "$rendered" >"$work/mutant.yaml"
  named_by "$1" "$2"
}
# mutant_with <expected text> <description> <YAML document>: the render with one more document.
mutant_with() {
  { cat "$rendered"; printf -- '---\n%s\n' "$3"; } >"$work/mutant.yaml"
  named_by "$1" "$2"
}
on_web='select(.kind == "Deployment" and .metadata.name == "web")'
on_worker="select($WORKER_DOCUMENT)"
worker_container='.spec.template.spec.containers[] | select(.name == "worker")'

# The web at uid 0 or with an annotation restricted refuses, and a third template at uid 0, also one named like the worker.
mutant "the Pod web is refused at restricted" "($on_web | .spec.template.spec.securityContext) |= (.runAsUser = 0 | .runAsNonRoot = false)"
mutant "the Pod web is refused at restricted" "($on_web | .spec.template.metadata.annotations) = {\"container.apparmor.security.beta.kubernetes.io/web\": \"unconfined\"}"
mutant_with "the Pod build-worker is refused at restricted" "a Deployment named build-worker at uid 0" "$(
  cat <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: build-worker
  namespace: presentator
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: build-worker
  template:
    metadata:
      labels:
        app.kubernetes.io/name: build-worker
    spec:
      containers:
        - name: build-worker
          image: docker.io/library/busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4
          securityContext:
            runAsUser: 0
EOF
)"
mutant_with "the Pod third is refused at restricted" "a third template at uid 0" "$(
  cat <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: third
  namespace: presentator
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: third
  template:
    metadata:
      labels:
        app.kubernetes.io/name: third
    spec:
      containers:
        - name: third
          image: docker.io/library/busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4
          securityContext:
            runAsUser: 0
EOF
)"
# The CronJob's pod template is among the judged templates.
mutant "the Pod restore-test is refused at restricted" \
  "(select(.kind == \"CronJob\" and .metadata.name == \"restore-test\") | .spec.jobTemplate.spec.template.spec.securityContext) |= (.runAsUser = 0 | .runAsNonRoot = false)"
# NET_ADMIN is what makes the worker need baseline.
mutant "the worker with its init's NET_ADMIN is admitted" "($on_worker | .spec.template.spec.initContainers[0].securityContext.capabilities.add) = []"
# NET_ADMIN only in the finishing init.
mutant "a container other than remove-link holds NET_ADMIN" "($on_worker | $worker_container | .securityContext.capabilities.add) += [\"NET_ADMIN\"]"
mutant "the worker has a container besides worker" "($on_worker | .spec.template.spec.containers) += [{\"name\": \"second\", \"image\": \"docker.io/library/busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4\", \"securityContext\": {\"allowPrivilegeEscalation\": true, \"capabilities\": {\"add\": [\"MKNOD\", \"DAC_OVERRIDE\"]}}}]"
mutant "the worker has an init container besides remove-link" "($on_worker | .spec.template.spec.initContainers) += [{\"name\": \"second\", \"image\": \"docker.io/library/busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4\"}]"
mutant "an init container of the worker restarts" "($on_worker | .spec.template.spec.initContainers[0].restartPolicy) = \"Always\""
# remove-link equals the init of no_network.
mutant "remove-link differs" "($on_worker | .spec.template.spec.initContainers[0].command[2]) += \" \""
mutant "remove-link differs" "($on_worker | .spec.template.spec.initContainers[0].image) |= sub(\"@sha256:\", \"@sha256:0\")"
mutant "remove-link differs" "($on_worker | .spec.template.spec.initContainers[0].securityContext.capabilities.add) += [\"CHOWN\"]"
mutant "remove-link differs" "($on_worker | .spec.template.spec.initContainers[0].volumeMounts) = [{\"name\": \"tmp\", \"mountPath\": \"/tmp\"}]"
# The worker's capabilities.
mutant "the worker does not add exactly SETUID, SETGID and KILL" "($on_worker | $worker_container | .securityContext.capabilities.add) += [\"MKNOD\"]"
mutant "the worker does not drop ALL capabilities" "del($on_worker | $worker_container | .securityContext.capabilities.drop)"
# Nothing privileged or shared.
mutant "a container of the worker is privileged" "($on_worker | $worker_container | .securityContext.privileged) = true"
for field in hostPID hostIPC hostNetwork shareProcessNamespace; do
  mutant "the worker sets $field" "($on_worker | .spec.template.spec.$field) = true"
done
# Seccomp profile and privilege escalation.
mutant "the worker's seccompProfile is not RuntimeDefault" "($on_worker | $worker_container | .securityContext.seccompProfile.type) = \"Unconfined\""
mutant "the worker's seccompProfile is not RuntimeDefault" "del($on_worker | $worker_container | .securityContext.seccompProfile)"
mutant "the worker allows privilege escalation" "($on_worker | $worker_container | .securityContext.allowPrivilegeEscalation) = true"
# The worker container's restart policy.
mutant "the worker container's restartPolicy is not exactly Never" "($on_worker | $worker_container | .restartPolicy) = \"Always\""
mutant "the worker container's restartPolicy is not exactly Never" "($on_worker | $worker_container | .restartPolicy) = \"OnFailure\""
mutant "the worker container's restartPolicy is not exactly Never" "del($on_worker | $worker_container | .restartPolicy)"
mutant "the worker container has restartPolicyRules" \
  "($on_worker | $worker_container | .restartPolicyRules) = [{\"action\": \"Restart\", \"exitCodes\": {\"operator\": \"In\", \"values\": [2]}}]"
# No Role, binding or token.
mutant_with "the render holds a Role" "a Role" "$(
  cat <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pods
  namespace: presentator
rules:
  - apiGroups: ['']
    resources: [pods]
    verbs: [delete]
EOF
)"
mutant_with "the render holds a Role" "a RoleBinding" "$(
  cat <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pods
  namespace: presentator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pods
subjects:
  - kind: ServiceAccount
    name: web
    namespace: presentator
EOF
)"
mutant_with "the render holds a Role" "a ClusterRole" "$(
  cat <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wide
rules:
  - apiGroups: ['']
    resources: [pods]
    verbs: [delete]
EOF
)"
mutant_with "the render holds a Role" "a ClusterRoleBinding" "$(
  cat <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: wide
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: wide
subjects:
  - kind: ServiceAccount
    name: build-worker
    namespace: presentator
EOF
)"
mutant "the worker mounts a ServiceAccount token" "($on_worker | .spec.template.spec.automountServiceAccountToken) = true"
mutant "the worker projects a ServiceAccount token" \
  "($on_worker | .spec.template.spec.volumes) += [{\"name\": \"token\", \"projected\": {\"sources\": [{\"serviceAccountToken\": {\"path\": \"token\"}}]}}]"
mutant "the web projects a ServiceAccount token" \
  "($on_web | .spec.template.spec.volumes[] | select(.name == \"secrets\") | .projected.sources) += [{\"serviceAccountToken\": {\"path\": \"token\"}}]"
# Replicas, strategy, process sharing, fsGroup and exec probes.
mutant "the web does not turn the kubelet's ServiceAccount token automount off" "($on_web | .spec.template.spec.automountServiceAccountToken) = true"
mutant "the web does not mount that volume read-only at /run/secrets" "($on_web | .spec.template.spec.containers[0].volumeMounts[] | select(.name == \"secrets\") | .readOnly) = false"
mutant "the web or the worker does not run one replica" "($on_web | .spec.replicas) = 2"
mutant "the web or the worker does not run one replica" "($on_worker | .spec.replicas) = 2"
mutant "the web's strategy is not Recreate" "($on_web | .spec.strategy.type) = \"RollingUpdate\""
mutant "the web does not share its process namespace" "($on_web | .spec.template.spec.shareProcessNamespace) = false"
mutant "a template sets fsGroup" "($on_web | .spec.template.spec.securityContext.fsGroup) = 1001"
mutant "a template sets fsGroup" "($on_worker | .spec.template.spec.securityContext.fsGroup) = 1001"
mutant "a container has an exec probe or a postStart hook" \
  "($on_web | .spec.template.spec.containers[0].livenessProbe) = {\"exec\": {\"command\": [\"true\"]}}"
mutant "a container has an exec probe or a postStart hook" \
  "($on_worker | $worker_container | .lifecycle.postStart) = {\"exec\": {\"command\": [\"true\"]}}"
# Group, command, seal and memory bound.
mutant "is not the web's" "($on_worker | $worker_container | .securityContext.runAsGroup) = 0"
mutant "the worker has no command" "del($on_worker | $worker_container | .command)"
mutant "the worker's seal is not set" "del($on_worker | $worker_container | .env[] | select(.name == \"PRESENTATOR_WORKER_SEAL\"))"
mutant "the worker has no memory limit" "del($on_worker | $worker_container | .resources)"
echo "every mutant was named by the check"
