#!/usr/bin/env bash
# pods_stay_within_their_levels.sh <rendered manifest> [<rendered pull layer>]: holds presentator's pods to the levels
# they may run at, on any cluster with `kubectl` and `yq` and no layer of ours. The first argument is `kubectl kustomize`
# of apps/presentator, or of an overlay that changes only its images or class. The second, which presentator's own
# call at a pinned commit does not pass, is that of apps/presentator/pull, whose Job is judged at restricted as the
# Namespace enforces no level for it. Each Pod template of the render becomes a Pod, created with
# --dry-run=server in throwaway Namespaces that enforce the level: every template but the build worker's at
# restricted, the worker's at baseline once the init container's NET_ADMIN is removed from the copy. The rest of the
# contract is read from the render, where a value two objects must agree on is read from both, and each rule is proven
# by mutants: a copy of the render changed to break exactly that rule must make the check name it, or the script fails.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

if [ $# -lt 1 ] || [ $# -gt 2 ] || [ ! -f "$1" ] || { [ $# -eq 2 ] && [ ! -f "$2" ]; }; then
  fail "usage: $0 <rendered manifest> [<rendered pull layer>]"
fi
rendered="$1"
pull_rendered="${2:-}"
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
# A StatefulSet's claim templates are volumes of its Pods that the template does not list; the controller adds each as a
# claim named <template>-<workload>-<ordinal>, which a dry run does not need to exist.
# shellcheck disable=SC2016 # the jq expression expands its own variable
CLAIM_VOLUMES='(.metadata.name as $workload | [(.spec.volumeClaimTemplates // [])[] | {"name": .metadata.name, "persistentVolumeClaim": {"claimName": (.metadata.name + "-" + $workload + "-0")}}])'
POD_OF="$SPECS as \$spec | $ANNOTATIONS as \$annotations | $CLAIM_VOLUMES as \$claims | select(\$spec != null) | {\"apiVersion\": \"v1\", \"kind\": \"Pod\", \"metadata\": ({\"name\": .metadata.name} + (if \$annotations == null then {} else {\"annotations\": \$annotations} end)), \"spec\": (\$spec | if (\$claims | length) > 0 then .volumes = ((.volumes // []) + \$claims) else . end)}"
WORKER_KEY=StatefulSet/build-worker
WORKER_DOCUMENT=".kind + \"/\" + .metadata.name == \"$WORKER_KEY\""
WORKER="select($WORKER_DOCUMENT) | .spec.template.spec"
WEB='select(.kind == "Deployment" and .metadata.name == "web") | .spec.template.spec'
WORKER_SERVICE='select(.kind == "Service" and .metadata.name == "build-worker")'
WORKER_LABELS="select($WORKER_DOCUMENT) | .spec.template.metadata.labels"
WEB_LABELS='select(.kind == "Deployment" and .metadata.name == "web") | .spec.template.metadata.labels'
WORKER_POLICY='select(.kind == "NetworkPolicy" and .metadata.name == "build-worker")'
REDIS_POLICY='select(.kind == "NetworkPolicy" and .metadata.name == "redis")'
WORKER_CONTAINER="$WORKER | .containers[] | select(.name == \"worker\")"
NET_ADMIN_HOLDER='select((.securityContext.capabilities.add // []) | any_c(. == "NET_ADMIN")) | .name'
WORKER_INIT="$WORKER | .initContainers[0]"

# The Namespaces and the ServiceAccounts the Pods name, which the API server's admission needs to exist.
for level in restricted baseline; do
  namespace="presentator-levels-$level"
  kubectl create namespace "$namespace"
  created_namespaces+=("$namespace")
  kubectl label namespace "$namespace" "pod-security.kubernetes.io/enforce=$level"
  kubectl -n "$namespace" wait serviceaccount/default --for=create --timeout=1m
  for account in $(yq --no-doc "$SPECS | .serviceAccountName | select(. != null)" "$rendered" ${pull_rendered:+"$pull_rendered"}); do
    kubectl -n "$namespace" create serviceaccount "$account"
  done
done

# admit <namespace> <Pod>: succeeds when --dry-run=server creates the Pod there; admit_output holds the answer.
admit() { admit_output="$(kubectl -n "$1" create --dry-run=server -f - <<<"$2" 2>&1)"; }
# The API server validates the Pod itself before admission, so an answer that does not name PodSecurity is no level's
# refusal.
refused_by_pod_security() { [[ $admit_output == *"violates PodSecurity"* ]]; }

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
      elif ! refused_by_pod_security || [[ $admit_output != *NET_ADMIN* ]]; then
        echo "problem: baseline refuses the worker without naming NET_ADMIN: $admit_output"
      fi
    else
      if ! admit "$restricted_namespace" "$pod"; then
        if refused_by_pod_security; then
          echo "problem: the Pod ${name#*/} is refused at restricted: $admit_output"
        else
          echo "problem: the Pod ${name#*/} is refused by something other than restricted: $admit_output"
        fi
      fi
    fi
  done
}

# Each rule below reads the render with yq over one document at a time. found prints the problem when the expression
# prints anything; exactly prints it unless the values the expression prints, as one-line JSON joined by commas, are
# the expected text.
found() { [ -z "$(yq --no-doc "$3" "$1" 2>&1)" ] || echo "problem: $2"; }
exactly() { [ "$(yq --no-doc -o=json -I=0 "$3" "$1" 2>&1 | paste -sd,)" = "$4" ] || echo "problem: $2"; }
# same prints the problem $4 unless the expressions $2 and $3 print the same values.
same() { [ "$(yq --no-doc -o=json -I=0 "$2" "$1" 2>&1 | paste -sd,)" = "$(yq --no-doc -o=json -I=0 "$3" "$1" 2>&1 | paste -sd,)" ] || echo "problem: $4"; }

# judge_structure <manifest>: prints a problem line for each rule of the contract that the render breaks.
judge_structure() {
  local manifest="$1" rules_volume rules_mount rules_file rules_map worker_command worker_probe worker_port key_file key_volume key_secret web_mount
  local service_port service_name service_target web_address web_key_file web_item
  # NET_ADMIN sits in the one finishing init container, which loads the rule file and holds nothing else.
  exactly "$manifest" "a container other than nft-rules holds NET_ADMIN" \
    "$WORKER | [.initContainers[], .containers[]][] | $NET_ADMIN_HOLDER" '"nft-rules"'
  exactly "$manifest" "the worker has a container besides worker" "$WORKER | .containers[].name" '"worker"'
  exactly "$manifest" "the worker has an init container besides nft-rules" "$WORKER | .initContainers[].name" '"nft-rules"'
  found "$manifest" "an init container of the worker restarts, which makes it a sidecar that runs beside the worker" \
    "$WORKER | .initContainers[] | select(has(\"restartPolicy\"))"
  exactly "$manifest" "the init container nft-rules does not hold exactly root, no escalation, a read-only root, RuntimeDefault and NET_ADMIN alone" \
    "$WORKER_INIT | .securityContext | sort_keys(..) | to_json(0)" \
    '"{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"add\":[\"NET_ADMIN\"],\"drop\":[\"ALL\"]},\"readOnlyRootFilesystem\":true,\"runAsUser\":0,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}}"'
  found "$manifest" "the init container nft-rules has an environment, a port or a probe" \
    "$WORKER_INIT | select(has(\"env\") or has(\"envFrom\") or has(\"ports\") or has(\"livenessProbe\") or has(\"readinessProbe\") or has(\"startupProbe\"))"
  # The init container mounts the rule file's ConfigMap read-only and nothing else, and loads a file of it.
  exactly "$manifest" "the init container nft-rules does not mount exactly one volume, read-only" \
    "$WORKER_INIT | .volumeMounts | (length | tostring) + \",\" + (.[0].readOnly | tostring)" '"1,true"'
  rules_volume="$(yq --no-doc "$WORKER_INIT | .volumeMounts[0].name" "$manifest")"
  rules_mount="$(yq --no-doc "$WORKER_INIT | .volumeMounts[0].mountPath" "$manifest")"
  rules_file="$(yq --no-doc "$WORKER_INIT | .command[-1]" "$manifest")"
  rules_map="$(yq --no-doc "$WORKER | .volumes[] | select(.name == \"$rules_volume\") | .configMap.name" "$manifest")"
  [ "$(yq --no-doc "select(.kind == \"ConfigMap\" and .metadata.name == \"$rules_map\") | .data | has(\"${rules_file##*/}\")" "$manifest")" = true ] &&
    [ "${rules_file%/*}" = "$rules_mount" ] ||
    echo "problem: the init container nft-rules does not load a file of the ConfigMap '$rules_map' from its mount '$rules_mount': '$rules_file'"
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
  exactly "$manifest" "the web does not run one replica and the worker two" \
    "select((.kind == \"Deployment\" and .metadata.name == \"web\") or ($WORKER_DOCUMENT)) | .spec.replicas" '1,2'
  # An immutable field of the StatefulSet changes only by deleting it, which Flux does for the annotation.
  found "$manifest" "the worker sets podManagementPolicy without the annotation that lets Flux recreate its StatefulSet" \
    "select($WORKER_DOCUMENT) | select(.spec.podManagementPolicy != null and .metadata.annotations[\"kustomize.toolkit.fluxcd.io/force\"] != \"enabled\")"
  exactly "$manifest" "the web's strategy is not Recreate" \
    'select(.kind == "Deployment" and .metadata.name == "web") | .spec.strategy.type' '"Recreate"'
  exactly "$manifest" "the web does not share its process namespace" "$WEB | .shareProcessNamespace" 'true'
  found "$manifest" "a template other than the web's shares its process namespace" \
    "select((.kind == \"Deployment\" and .metadata.name == \"web\") | not) | $SPECS | select(.shareProcessNamespace == true)"
  found "$manifest" "a template sets fsGroup" "$SPECS | select(.securityContext.fsGroup != null)"
  # The platform's Postgres base reads its readiness through `pg_isready`, an exec probe; it is held to restricted above.
  # The worker's readiness is an exec probe too, since a verified hello would spend a life; it has no other.
  found "$manifest" "a container has an exec probe or a postStart hook" \
    "select(.kind + \"/\" + .metadata.name != \"StatefulSet/postgres\" and .kind + \"/\" + .metadata.name != \"$WORKER_KEY\") | $SPECS | [.initContainers[], .containers[]][] | select(.livenessProbe.exec != null or .readinessProbe.exec != null or .startupProbe.exec != null or .lifecycle.postStart != null)"
  found "$manifest" "a container of the worker has a probe or a postStart hook other than the worker's readiness exec" \
    "$WORKER | [.initContainers[], .containers[]][] | select(.livenessProbe != null or .startupProbe != null or .lifecycle.postStart != null or (.name != \"worker\" and .readinessProbe != null))"
  exactly "$manifest" "the worker's readiness probe is no exec" "$WORKER_CONTAINER | .readinessProbe | has(\"exec\")" 'true'
  # The worker's port is one number in its command, its readiness probe, its container port, its Service and the web's address.
  worker_command="$(yq --no-doc "$WORKER_CONTAINER | (.command // []) | join(\" \")" "$manifest")"
  worker_probe="$(yq --no-doc "$WORKER_CONTAINER | (.readinessProbe.exec.command // []) | join(\" \")" "$manifest")"
  worker_port="$(yq --no-doc "$WORKER_CONTAINER | .ports[] | select(.name == \"build\") | .containerPort" "$manifest")"
  [[ $worker_command =~ (^|\ )--port\ ([0-9]+)($|\ ) ]] && [ "${BASH_REMATCH[2]}" = "$worker_port" ] ||
    echo "problem: the worker's command '$worker_command' does not serve the container port build '$worker_port'"
  [[ $worker_probe =~ (^|\ )--ready\ --port\ ([0-9]+)$ ]] && [ "${BASH_REMATCH[2]}" = "$worker_port" ] ||
    echo "problem: the worker's readiness probe '$worker_probe' does not ask for the container port build '$worker_port'"
  service_name="$(yq --no-doc "$WORKER_SERVICE | .metadata.name" "$manifest")"
  service_port="$(yq --no-doc "$WORKER_SERVICE | .spec.ports[] | select(.name == \"build\") | .port" "$manifest")"
  service_target="$(yq --no-doc "$WORKER_SERVICE | .spec.ports[] | select(.name == \"build\") | .targetPort" "$manifest")"
  web_address="$(yq --no-doc "$WEB | .containers[0].env[] | select(.name == \"PRESENTATOR_BUILD_WORKER_ADDRESS\") | .value" "$manifest")"
  { [ "$service_target" = build ] && [ "$web_address" = "$service_name:$service_port" ] && [ "$service_port" = "$worker_port" ]; } ||
    echo "problem: the Service '$service_name' (port '$service_port' to '$service_target') and the web's address '$web_address' do not reach the container port build '$worker_port'"
  same "$manifest" "$WORKER_SERVICE | .spec.selector" "$WORKER_LABELS" "the Service build-worker does not select the worker's pods"
  # The key is a file of the Secret the worker mounts alone, read-only at 0400, which the web reads at the same path from
  # its volume of Secret files.
  key_file="$(yq --no-doc "$WORKER_CONTAINER | (.command // []) | join(\" \")" "$manifest" | sed -n 's/.*--key-file \([^ ]*\).*/\1/p')"
  key_volume="$(yq --no-doc "$WORKER_CONTAINER | .volumeMounts[] | select(.mountPath == \"${key_file%/*}\") | .name" "$manifest")"
  key_secret="$(yq --no-doc "$WORKER | .volumes[] | select(.name == \"$key_volume\") | .secret.secretName" "$manifest")"
  [ -n "$key_file" ] && [ -n "$key_volume" ] && [ -n "$key_secret" ] ||
    echo "problem: the worker's key file '$key_file' is not in a mounted Secret volume ('$key_volume', '$key_secret')"
  exactly "$manifest" "the worker's key volume is not read-only" \
    "$WORKER_CONTAINER | .volumeMounts[] | select(.name == \"$key_volume\") | .readOnly" 'true'
  exactly "$manifest" "the worker's key file is not mode 0400" \
    "$WORKER | .volumes[] | select(.name == \"$key_volume\") | .secret.defaultMode" '256'
  found "$manifest" "a container other than the worker's mounts the worker's key" \
    "$WORKER | .initContainers[] | select((.volumeMounts // []) | any_c(.name == \"$key_volume\"))"
  web_key_file="$(yq --no-doc "$WEB | .containers[0].env[] | select(.name == \"PRESENTATOR_BUILD_WORKER_KEY_FILE\") | .value" "$manifest")"
  web_mount="$(yq --no-doc "$WEB | .containers[0].volumeMounts[] | select(.name == \"secrets\") | .mountPath" "$manifest")"
  web_item="$(yq --no-doc "$WEB | .volumes[] | select(.name == \"secrets\") | .projected.sources[] | select(.secret.name == \"$key_secret\") | .secret.items[0].path" "$manifest")"
  { [ "$web_key_file" = "$key_file" ] && [ "$web_key_file" = "$web_mount/$web_item" ]; } ||
    echo "problem: the web reads its key from '$web_key_file', not the worker's '$key_file' as the item '$web_item' of its volume at '$web_mount'"
  # The NetworkPolicy admits the web's pods to the worker's port and nothing to leave: no egress rule, and Egress listed.
  exactly "$manifest" "the NetworkPolicy build-worker does not list exactly Ingress and Egress" \
    "$WORKER_POLICY | .spec.policyTypes | sort | join(\",\")" '"Egress,Ingress"'
  exactly "$manifest" "the NetworkPolicy build-worker has an egress rule" "$WORKER_POLICY | (.spec.egress // []) | length" '0'
  exactly "$manifest" "the NetworkPolicy build-worker does not admit exactly one peer, a podSelector, to the one port build" \
    "$WORKER_POLICY | .spec.ingress | (length | tostring) + \",\" + (.[0].from | length | tostring) + \",\" + (.[0].from[0] | keys | join(\"+\")) + \",\" + (.[0].ports | length | tostring) + \",\" + .[0].ports[0].port + \",\" + .[0].ports[0].protocol" \
    '"1,1,podSelector,1,build,TCP"'
  same "$manifest" "$WORKER_POLICY | .spec.ingress[0].from[0].podSelector.matchLabels" "$WEB_LABELS" "the NetworkPolicy build-worker does not admit the web's pods"
  same "$manifest" "$WORKER_POLICY | .spec.podSelector.matchLabels" "$WORKER_LABELS" "the NetworkPolicy build-worker does not select the worker's pods"
  # Only the web holds store credentials: Redis admits the web's pods alone, and the worker names no Redis.
  exactly "$manifest" "the NetworkPolicy redis does not admit exactly one peer, a podSelector" \
    "$REDIS_POLICY | .spec.ingress | (length | tostring) + \",\" + (.[0].from | length | tostring) + \",\" + (.[0].from[0] | keys | join(\"+\"))" \
    '"1,1,podSelector"'
  same "$manifest" "$REDIS_POLICY | .spec.ingress[0].from[0].podSelector.matchLabels" "$WEB_LABELS" "the NetworkPolicy redis does not admit the web's pods"
  found "$manifest" "the worker names a Redis variable" "$WORKER_CONTAINER | (.env // [])[] | select(.name | test(\"REDIS\"))"
  exactly "$manifest" "the worker has no command" "$WORKER_CONTAINER | .command | length > 0" 'true'
  exactly "$manifest" "the worker's seal is not set" \
    "$WORKER_CONTAINER | .env[] | select(.name == \"PRESENTATOR_WORKER_SEAL\") | (.value // \"\") != \"\"" 'true'
  exactly "$manifest" "the worker has no memory limit" "$WORKER_CONTAINER | .resources.limits.memory != null" 'true'
}

judge() { judge_levels "$1"; judge_structure "$1"; }

problems="$(judge "$rendered")"
[ -z "$problems" ] || fail "the render breaks its contract: $problems"
echo "the web and every other template pass restricted, the worker passes baseline without its init's NET_ADMIN and is refused with it, and the render holds its contract"

if [ -n "$pull_rendered" ]; then
  problems="$(judge_levels "$pull_rendered")"
  [ -z "$problems" ] || fail "the pull layer breaks its level: $problems"
  echo "the Job of the pull layer passes restricted"
fi

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
# The platform's Postgres template is held to restricted in this Namespace, which enforces no level.
mutant "the Pod postgres is refused at restricted" \
  "(select(.kind == \"StatefulSet\" and .metadata.name == \"postgres\") | .spec.template.spec.securityContext) |= (.runAsUser = 0 | .runAsNonRoot = false)"
# NET_ADMIN is what makes the worker need baseline.
mutant "the worker with its init's NET_ADMIN is admitted" "($on_worker | .spec.template.spec.initContainers[0].securityContext.capabilities.add) = []"
# NET_ADMIN only in the finishing init.
mutant "a container other than nft-rules holds NET_ADMIN" "($on_worker | $worker_container | .securityContext.capabilities.add) += [\"NET_ADMIN\"]"
mutant "the worker has a container besides worker" "($on_worker | .spec.template.spec.containers) += [{\"name\": \"second\", \"image\": \"docker.io/library/busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4\", \"securityContext\": {\"allowPrivilegeEscalation\": true, \"capabilities\": {\"add\": [\"MKNOD\", \"DAC_OVERRIDE\"]}}}]"
mutant "the worker has an init container besides nft-rules" "($on_worker | .spec.template.spec.initContainers) += [{\"name\": \"second\", \"image\": \"docker.io/library/busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4\"}]"
mutant "an init container of the worker restarts" "($on_worker | .spec.template.spec.initContainers[0].restartPolicy) = \"Always\""
# The init container is exactly the finishing one: its fields, its mount and the file it loads.
init="$on_worker | .spec.template.spec.initContainers[0]"
mutant "the init container nft-rules does not hold exactly" "($init | .securityContext.capabilities.add) += [\"CHOWN\"]"
mutant "the init container nft-rules does not hold exactly" "($init | .securityContext.allowPrivilegeEscalation) = true"
mutant "the init container nft-rules does not hold exactly" "($init | .securityContext.readOnlyRootFilesystem) = false"
mutant "the init container nft-rules does not hold exactly" "($init | .securityContext.runAsUser) = 1000"
mutant "the init container nft-rules does not hold exactly" "del($init | .securityContext.seccompProfile)"
mutant "the init container nft-rules does not hold exactly" "($init | .securityContext.privileged) = true"
mutant "the init container nft-rules has an environment, a port or a probe" "($init | .env) = [{\"name\": \"X\", \"value\": \"1\"}]"
mutant "the init container nft-rules has an environment, a port or a probe" "($init | .readinessProbe) = {\"exec\": {\"command\": [\"true\"]}}"
mutant "the init container nft-rules does not mount exactly one volume, read-only" "($init | .volumeMounts[0].readOnly) = false"
mutant "the init container nft-rules does not mount exactly one volume, read-only" "($init | .volumeMounts) += [{\"name\": \"tmp\", \"mountPath\": \"/tmp\"}]"
mutant "the init container nft-rules does not load a file of the ConfigMap" "($init | .command[-1]) = \"/etc/nftables/other.nft\""
mutant "the init container nft-rules does not load a file of the ConfigMap" "($init | .volumeMounts[0].mountPath) = \"/etc/other\""
mutant "the init container nft-rules does not load a file of the ConfigMap" "($on_worker | .spec.template.spec.volumes[0].configMap.name) = \"missing\""
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
mutant "the web does not run one replica and the worker two" "($on_web | .spec.replicas) = 2"
mutant "the web does not run one replica and the worker two" "($on_worker | .spec.replicas) = 1"
mutant "the web does not run one replica and the worker two" "($on_worker | .spec.replicas) = 3"
mutant "the worker sets podManagementPolicy without the annotation" "del($on_worker | .metadata.annotations)"
mutant "the worker sets podManagementPolicy without the annotation" "($on_worker | .metadata.annotations.\"kustomize.toolkit.fluxcd.io/force\") = \"disabled\""
mutant "the web's strategy is not Recreate" "($on_web | .spec.strategy.type) = \"RollingUpdate\""
mutant "the web does not share its process namespace" "($on_web | .spec.template.spec.shareProcessNamespace) = false"
mutant "a template sets fsGroup" "($on_web | .spec.template.spec.securityContext.fsGroup) = 1001"
mutant "a template sets fsGroup" "($on_worker | .spec.template.spec.securityContext.fsGroup) = 1001"
mutant "a container has an exec probe or a postStart hook" \
  "($on_web | .spec.template.spec.containers[0].livenessProbe) = {\"exec\": {\"command\": [\"true\"]}}"
mutant "a container of the worker has a probe or a postStart hook other than" \
  "($on_worker | $worker_container | .lifecycle.postStart) = {\"exec\": {\"command\": [\"true\"]}}"
mutant "a container has an exec probe or a postStart hook" \
  "($on_web | .spec.template.spec.containers[0].startupProbe) = {\"exec\": {\"command\": [\"true\"]}}"
# The worker has its readiness exec and no other probe or hook, and one port in every place that names it.
mutant "a container of the worker has a probe or a postStart hook other than the worker's readiness exec" \
  "($on_worker | $worker_container | .livenessProbe) = {\"exec\": {\"command\": [\"true\"]}}"
mutant "a container of the worker has a probe or a postStart hook other than the worker's readiness exec" \
  "($init | .readinessProbe) = {\"exec\": {\"command\": [\"true\"]}}"
mutant "the worker's readiness probe is no exec" "($on_worker | $worker_container | .readinessProbe) = {\"tcpSocket\": {\"port\": \"build\"}}"
mutant "the worker's readiness probe '" "($on_worker | $worker_container | .readinessProbe.exec.command[-1]) = \"7101\""
mutant "the worker's command '" "($on_worker | $worker_container | .command[-1]) = \"7101\""
mutant "the Service '" "($on_worker | $worker_container | .ports[0].containerPort) = 7101"
mutant "the Service 'build-worker'" "($WORKER_SERVICE | .spec.ports[0].port) = 7101"
mutant "the Service 'build-worker'" "($WORKER_SERVICE | .spec.ports[0].targetPort) = 7100"
mutant "the Service 'build-worker'" "($on_web | .spec.template.spec.containers[0].env[] | select(.name == \"PRESENTATOR_BUILD_WORKER_ADDRESS\") | .value) = \"build-worker:7101\""
mutant "the Service build-worker does not select the worker's pods" "($WORKER_SERVICE | .spec.selector) = {\"app.kubernetes.io/name\": \"web\"}"
# The key: a Secret file of the worker alone, read-only at 0400, and the web reads the same path.
mutant "the worker's key file is not mode 0400" "($on_worker | .spec.template.spec.volumes[] | select(.name == \"key\") | .secret.defaultMode) = 292"
mutant "the worker's key file is not mode 0400" "del($on_worker | .spec.template.spec.volumes[] | select(.name == \"key\") | .secret.defaultMode)"
mutant "the worker's key volume is not read-only" "($on_worker | $worker_container | .volumeMounts[] | select(.name == \"key\") | .readOnly) = false"
mutant "the worker's key file '" "($on_worker | $worker_container | .command[2]) = \"/run/secrets/other/key\""
mutant "a container other than the worker's mounts the worker's key" "($init | .volumeMounts) += [{\"name\": \"key\", \"mountPath\": \"/run/secrets/build-worker-key\"}]"
mutant "the web reads its key from" "($on_web | .spec.template.spec.containers[0].env[] | select(.name == \"PRESENTATOR_BUILD_WORKER_KEY_FILE\") | .value) = \"/run/secrets/key\""
mutant "the web reads its key from" "($on_web | .spec.template.spec.volumes[] | select(.name == \"secrets\") | .projected.sources[1].secret.items[0].path) = \"key\""
# The NetworkPolicy: Ingress and Egress listed with no egress rule, the web's pods to the one port, the worker's pods selected.
mutant "the NetworkPolicy build-worker does not list exactly Ingress and Egress" "($WORKER_POLICY | .spec.policyTypes) = [\"Ingress\"]"
mutant "the NetworkPolicy build-worker has an egress rule" "($WORKER_POLICY | .spec.egress) = [{}]"
mutant "the NetworkPolicy build-worker does not admit exactly one peer" "($WORKER_POLICY | .spec.ingress[0].from) += [{\"namespaceSelector\": {}}]"
mutant "the NetworkPolicy build-worker does not admit exactly one peer" "($WORKER_POLICY | .spec.ingress[0].from[0]) = {\"namespaceSelector\": {}}"
mutant "the NetworkPolicy build-worker does not admit exactly one peer" "del($WORKER_POLICY | .spec.ingress[0].ports)"
mutant "the NetworkPolicy build-worker does not admit the web's pods" "($WORKER_POLICY | .spec.ingress[0].from[0].podSelector.matchLabels) = {\"app.kubernetes.io/name\": \"build-worker\"}"
mutant "the NetworkPolicy build-worker does not select the worker's pods" "($WORKER_POLICY | .spec.podSelector) = {}"
# Redis's ingress and the worker's environment.
mutant "the NetworkPolicy redis does not admit exactly one peer" "($REDIS_POLICY | .spec.ingress[0].from) = [{\"podSelector\": {}}, {\"namespaceSelector\": {}}]"
mutant "the NetworkPolicy redis does not admit the web's pods" "($REDIS_POLICY | .spec.ingress[0].from[0].podSelector) = {}"
mutant "the worker names a Redis variable" "($on_worker | $worker_container | .env) += [{\"name\": \"PRESENTATOR_REDIS_URL\", \"value\": \"redis://redis:6379/0\"}]"
# Command, seal and memory bound.
mutant "the worker has no command" "del($on_worker | $worker_container | .command)"
mutant "the worker's seal is not set" "del($on_worker | $worker_container | .env[] | select(.name == \"PRESENTATOR_WORKER_SEAL\"))"
mutant "the worker has no memory limit" "del($on_worker | $worker_container | .resources)"
# The pull layer's Job at uid 0 is refused at restricted.
if [ -n "$pull_rendered" ]; then
  yq '(select(.kind == "Job") | .spec.template.spec.securityContext) |= (.runAsUser = 0 | .runAsNonRoot = false)' "$pull_rendered" >"$work/mutant.yaml"
  [[ "$(judge_levels "$work/mutant.yaml")" == *"the Pod pull is refused at restricted"* ]] ||
    fail "the pull layer's Job at uid 0 was not named as refused at restricted"
  echo "the check names 'the Pod pull is refused at restricted' for the pull layer's Job at uid 0"
fi
echo "every mutant was named by the check"
