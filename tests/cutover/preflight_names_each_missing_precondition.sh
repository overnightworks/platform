#!/usr/bin/env bash
# Drive scripts/cutover_preflight.sh against fake kubectl, flux, gh, curl, docker, systemctl, lslocks and df and a git
# delegate that logs every call, all first on PATH: each precondition that is missing is named with its owner and ends
# the run at exit 1, one whose reader fails ends it at exit 3, a usage error ends it at exit 2 before any read, the
# evidence file is written only at exit 0, I1 compares the NetworkPolicies by namespace/name over their normalised
# .spec, and every call is one of the reads the contract lists. The fakes refuse a call that is no such read, and the
# cell turns red on each planted forbidden call.
# Usage: mise exec -- tests/cutover/preflight_names_each_missing_precondition.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
real_git="$(command -v git)"
[ -z "$("$real_git" -C "$repository_root" status --porcelain)" ] ||
  fail "this checkout is not clean, so a reordered step would show as a false N4: the cell writes nothing into the tree"
head_sha="$("$real_git" -C "$repository_root" rev-parse HEAD)"
other_sha="$(printf 'b%.0s' {1..40})"
secrets_sha="$(printf 'c%.0s' {1..40})"
work_directory="$(mktemp -d)"
trap '[ -n "${KEEP-}" ] || rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
base="$work_directory/base"
mkdir "$fake_bin" "$base"
script="$repository_root/scripts/cutover_preflight.sh"
forward_port=34567

# ---------------------------------------------------------------- the fakes
cat >"$work_directory/fake_lib.sh" <<'FAKE'
tool="$(basename "$0")"
scenario="$FAKE_SCENARIO"
printf '%q ' "$@" >>"$FAKE_LOG/$tool"
echo >>"$FAKE_LOG/$tool"
echo "${PATH%%:*}" >>"$FAKE_LOG/path"
refuse() {
  echo "$tool: $1: $*" >>"$FAKE_LOG/refused"
  echo "fake $tool refuses: $1" >&2
  exit 99
}
# A reader the scenario makes fail.
failing() { [ ! -e "$scenario/fail/$1" ] || exit 1; }
FAKE

write_fake() {
  { echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'; echo 'source "$FAKE_LIB"'; cat; } >"$fake_bin/$1"
  chmod +x "$fake_bin/$1"
}

write_fake kubectl <<'FAKE'
namespace=""
if [ "${1-}" = --namespace ]; then namespace="$2"; shift 2; fi
case "$namespace|$*" in
  "|get nodes --output json") failing kubectl-nodes; cat "$scenario/nodes.json" ;;
  "|get gitrepositories.source.toolkit.fluxcd.io --all-namespaces --output json")
    failing kubectl-gitrepositories; cat "$scenario/gitrepositories.json" ;;
  "|get kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces --output json")
    failing kubectl-kustomizations; cat "$scenario/kustomizations.json" ;;
  "|get customresourcedefinitions.apiextensions.k8s.io adminnetworkpolicies.policy.networking.k8s.io baselineadminnetworkpolicies.policy.networking.k8s.io --ignore-not-found --output name")
    failing kubectl-crd; cat "$scenario/crds.out" ;;
  "keycloak|get networkpolicies --output json" | "litellm|get networkpolicies --output json" | "hopin|get networkpolicies --output json")
    failing "kubectl-networkpolicies-$namespace"; cat "$scenario/networkpolicies-$namespace.json" ;;
  "cloudflared|get configmap cloudflared --output json") failing kubectl-configmap; cat "$scenario/configmap.json" ;;
  "cloudflared|get deployment cloudflared --output json") failing kubectl-deployment; cat "$scenario/deployment.json" ;;
  "|get backups,restores,checks,prunes,archives.k8up.io --all-namespaces --output json")
    failing kubectl-k8up; cat "$scenario/k8up.json" ;;
  "|get jobs --all-namespaces --output json") failing kubectl-jobs; cat "$scenario/jobs.json" ;;
  "keycloak|port-forward --address 127.0.0.1 service/keycloak :http")
    failing kubectl-portforward
    echo "Forwarding from 127.0.0.1:$FAKE_FORWARD_PORT -> 8080"
    exec sleep 3600 ;;
  *) refuse "kubectl form" ;;
esac
FAKE

write_fake flux <<'FAKE'
[ $# = 6 ] && [ "$1 $2" = "build kustomization" ] && [ "$4" = --path ] && [ "$6" = --in-memory-build ] ||
  refuse "flux form (a build without --in-memory-build writes into the tree)"
declared="$(jq -r --arg name "$3" '.items[] | select(.metadata.name == $name) | .spec.path' "$scenario/kustomizations.json")"
[ "$5" = "$FAKE_ROOT/${declared#./}" ] || refuse "flux path"
failing "flux-build-$3"
cat "$scenario/render-$3.yaml"
FAKE

write_fake gh <<'FAKE'
method=GET endpoint="" jq_expression=""
[ "${1-}" = api ] || refuse "gh subcommand"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --method | -X) method="$2"; shift ;;
    -f | -F | --field | --raw-field | --input) [ "$method" != GET ] || method=POST; shift ;;
    --jq) jq_expression="$2"; shift ;;
    -*) refuse "gh option $1" ;;
    *) endpoint="$1" ;;
  esac
  shift
done
[ "$method" = GET ] || refuse "gh method $method"
case "$endpoint" in
  repos/*/*/commits/* | repos/*/*/contents/.sops.yaml) ;;
  *) refuse "gh endpoint" ;;
esac
file="$scenario/gh/$(tr / _ <<<"$endpoint")"
[ -f "$file" ] || refuse "gh endpoint without a scenario"
failing "gh-$(tr / _ <<<"$endpoint")"
cat "$file"
FAKE

write_fake curl <<'FAKE'
get=false data=false host="" url="" output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --silent | --show-error) ;;
    --max-time | --write-out) shift ;;
    --header) [[ $2 == "Host: "* ]] || refuse "curl header"; host="${2#Host: }"; shift ;;
    --output) output="$2"; shift ;;
    --get) get=true ;;
    --data | --data-*) data=true; shift ;;
    --request | -X | --form | --json | --upload-file | --head | --config) refuse "curl option $1" ;;
    -*) refuse "curl option $1" ;;
    *) url="$1" ;;
  esac
  shift
done
[ "$data" = false ] || [ "$get" = true ] || refuse "curl data without --get is a POST"
key="$(printf '%s' "$host $url" | tr -c 'A-Za-z0-9\n' _)"
[ -f "$scenario/http/$key" ] || refuse "curl URL $host $url"
IFS='|' read -r status content_type redirect exit_code <"$scenario/http/$key"
[ "${exit_code:-0}" = 0 ] || exit "$exit_code"
if [ "$output" != /dev/null ]; then tail -n +2 "$scenario/http/$key"; fi
printf '\n%s|%s|%s' "$status" "$content_type" "$redirect"
FAKE

write_fake docker <<'FAKE'
case "$*" in
  "ps --all --quiet --no-trunc --filter label=com.docker.compose.project=hal --filter label=com.docker.compose.service=keycloak-db --filter label=com.docker.compose.oneoff=False")
    failing docker-ps; cat "$scenario/docker-ps.out" ;;
  "exec --env PGOPTIONS=-c default_transaction_read_only=on $(cat "$scenario/docker-ps.out") psql --username=keycloak --dbname=keycloak --no-psqlrc -Atc select pg_database_size(current_database())")
    failing docker-exec; cat "$scenario/database-size.out" ;;
  *) refuse "docker form" ;;
esac
FAKE

write_fake systemctl <<'FAKE'
case "$*" in
  "--user show hal-backup.service --property=ActiveState --value" | "--user show hal-backup-restore-test.service --property=ActiveState --value" | \
    "--user show hal-backup.timer --property=NextElapseUSecRealtime --value --timestamp=unix" | \
    "--user show hal-backup-restore-test.timer --property=NextElapseUSecRealtime --value --timestamp=unix")
    failing systemctl; cat "$scenario/systemctl/$3" ;;
  *) refuse "systemctl form" ;;
esac
FAKE

write_fake lslocks <<'FAKE'
[ "$*" = "--json --output PID,INODE,MAJ:MIN,BLOCKER" ] || refuse "lslocks form"
failing lslocks
cat "$scenario/lslocks.json"
FAKE

write_fake df <<'FAKE'
[ "$*" = "--block-size=1 --output=avail,pcent,target $FAKE_HOME /opt/local-path-provisioner" ] || refuse "df form"
failing docker-df
# A file that appears while the run reads: the evidence file's race.
[ ! -e "$scenario/create-on-df" ] || : >"$(cat "$scenario/create-on-df")"
cat "$scenario/df.out"
FAKE

write_fake git <<'FAKE'
[ "${1-}" = -C ] || refuse "git without -C"
directory="$2"
shift 2
case "$directory" in
  "$FAKE_ROOT") owner=platform ;;
  "$FAKE_HOME/srv/hal") owner=hal ;;
  *) refuse "git directory" ;;
esac
case "$*" in
  "--no-optional-locks status --porcelain" | "rev-parse HEAD" | "symbolic-ref --short HEAD" | "remote get-url origin") ;;
  *) refuse "git form" ;;
esac
failing "git-$owner"
exec "$FAKE_REAL_GIT" -C "$directory" "$@"
FAKE

# ------------------------------------------------------ the healthy scenario
# Fixtures are hand-written in the shape the tools print; the specs of the API side carry the server's defaults.
api_metadata='"uid":"0f8a-uid","resourceVersion":"123456","generation":1,"creationTimestamp":"2026-11-01T10:00:00Z","labels":{"kustomize.toolkit.fluxcd.io/name":"layer","kustomize.toolkit.fluxcd.io/namespace":"flux-system"},"managedFields":[{"manager":"kustomize-controller","operation":"Apply"}]'
traefik_only='{"podSelector":{},"ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"traefik"}}}],"ports":[{"port":PORT}]}]}'
traefik_only_served='{"podSelector":{},"policyTypes":["Ingress"],"ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"traefik"}}}],"ports":[{"port":PORT,"protocol":"TCP"}]}]}'
keycloak_egress='{"podSelector":{"matchLabels":{"app":"keycloak"}},"egress":[{"to":[{"podSelector":{"matchLabels":{"app":"postgres"}}}],"ports":[{"port":5432}]}]}'
keycloak_egress_served='{"podSelector":{"matchLabels":{"app":"keycloak"}},"policyTypes":["Ingress","Egress"],"egress":[{"to":[{"podSelector":{"matchLabels":{"app":"postgres"}}}],"ports":[{"port":5432,"protocol":"TCP"}]}]}'
litellm_policy='{"podSelector":{"matchLabels":{"app":"litellm"}},"policyTypes":["Ingress","Egress"],"ingress":[{"ports":[{"port":4000,"protocol":"TCP"}]}],"egress":[{"ports":[{"port":53,"protocol":"UDP"}]}]}'

# policy_document <namespace> <name> <spec json>: a rendered object as YAML; policy_item likewise as the API prints it.
policy_document() {
  jq -n --arg namespace "$1" --arg name "$2" --argjson spec "$3" \
    '{apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy", metadata: {name: $name, namespace: $namespace}, spec: $spec}' | yq --prettyPrint '.'
}
policy_item() {
  jq -n --arg namespace "$1" --arg name "$2" --argjson spec "$3" "{apiVersion: \"networking.k8s.io/v1\", kind: \"NetworkPolicy\",
    metadata: {name: \$name, namespace: \$namespace, $api_metadata}, spec: \$spec}"
}
items() { jq --slurp '{items: .}'; }

gitrepository() {
  jq -n --arg name "$1" --arg url "$2" --arg sha "$3" '{metadata: {name: $name, namespace: "flux-system", generation: 3},
    spec: {url: $url, interval: "1m0s", ref: {branch: "main"}},
    status: {observedGeneration: 3, conditions: [{type: "Ready", status: "True"}], artifact: {revision: "main@sha1:\($sha)"}}}'
}
kustomization() {
  jq -n --arg name "$1" --arg path "$2" --arg source "$3" --arg sha "$4" '{metadata: {name: $name, namespace: "flux-system", generation: 5},
    spec: {path: $path, sourceRef: {kind: "GitRepository", name: $source}},
    status: {observedGeneration: 5, conditions: [{type: "Ready", status: "True"}], lastAppliedRevision: "main@sha1:\($sha)"}}'
}
# serve <host> <url> <status> <content type> <redirect> <exit code>: what the fake curl answers; the body is stdin.
serve() {
  local key
  key="$(printf '%s' "$1 $2" | tr -c 'A-Za-z0-9\n' _)"
  { echo "$3|${4:-}|${5:-}|${6:-0}"; cat; } >"$scenario_directory/http/$key"
}
discovery_body='{"issuer":"https://auth.hallucinai.de/realms/hallucinai","jwks_uri":"https://auth.hallucinai.de/realms/hallucinai/protocol/openid-connect/certs"}'
login_page='<html><link href="/resources/abcde/login/hallucinai/css/styles.css" rel="stylesheet"></html>'
discovery_path=/realms/hallucinai/.well-known/openid-configuration
certs_path=/realms/hallucinai/protocol/openid-connect/certs

build_base() {
  scenario_directory="$base"
  mkdir -p "$base/gh" "$base/http" "$base/systemctl" "$base/fail"
  jq -n '{items: [{metadata: {name: "pc"}, status: {conditions: [{type: "Ready", status: "True"}, {type: "MemoryPressure", status: "False"},
    {type: "DiskPressure", status: "False"}, {type: "PIDPressure", status: "False"}]}}]}' >"$base/nodes.json"
  { gitrepository flux-system https://github.com/overnightworks/platform "$head_sha"
    gitrepository platform-secrets ssh://git@github.com/overnightworks/platform-secrets "$secrets_sha"; } | items >"$base/gitrepositories.json"
  { kustomization flux-system ./clusters/pc flux-system "$head_sha"
    kustomization platform-secrets ./clusters/pc/secrets platform-secrets "$secrets_sha"
    kustomization keycloak ./infrastructure/keycloak flux-system "$head_sha"
    kustomization litellm ./infrastructure/litellm flux-system "$head_sha"
    kustomization hopin ./apps/hopin flux-system "$head_sha"
    kustomization tunnel ./infrastructure/cloudflared flux-system "$head_sha"; } | items >"$base/kustomizations.json"
  echo "$head_sha" >"$base/gh/repos_overnightworks_platform_commits_main"
  echo "$secrets_sha" >"$base/gh/repos_overnightworks_platform-secrets_commits_main"
  printf 'creation_rules:\n  - path_regex: a\n    age: age1canaryone,age1canarytwo\n  - age: >-\n      age1canarythree,\n      age1canaryfour\n' |
    base64 >"$base/gh/repos_overnightworks_platform-secrets_contents_.sops.yaml"
  : >"$base/crds.out"
  {
    policy_document keycloak keycloak-egress "$keycloak_egress"; echo ---
    policy_document keycloak http-from-traefik-only "${traefik_only//PORT/8080}"; echo ---
    yq --prettyPrint '.' <<<'{"kind":"Deployment","metadata":{"name":"keycloak","namespace":"keycloak"},"spec":{"template":{"spec":{"containers":[{"name":"keycloak","env":[{"name":"KC_HOSTNAME","value":"https://auth.hallucinai.de"},{"name":"KC_HOSTNAME_ADMIN","value":"http://localhost:9000"}]}]}}}}'
  } >"$base/render-keycloak.yaml"
  policy_document litellm litellm "$litellm_policy" >"$base/render-litellm.yaml"
  policy_document hopin http-from-traefik-only "${traefik_only//PORT/8000}" >"$base/render-hopin.yaml"
  { policy_item keycloak keycloak-egress "$keycloak_egress_served"
    policy_item keycloak http-from-traefik-only "${traefik_only_served//PORT/8080}"; } | items >"$base/networkpolicies-keycloak.json"
  policy_item litellm litellm "$litellm_policy" | items >"$base/networkpolicies-litellm.json"
  policy_item hopin http-from-traefik-only "${traefik_only_served//PORT/8000}" | items >"$base/networkpolicies-hopin.json"
  tunnel_lines=$'ingress:\n  - hostname: hopin.hallucinai.de\n    service: http://traefik.traefik:80\n  - service: http_status:404\n'
  jq -n --arg lines "$tunnel_lines" '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "cloudflared", namespace: "cloudflared"}, data: {"config.yaml": $lines}}' |
    yq --prettyPrint '.' >"$base/render-tunnel.yaml"
  write_tunnel_live "$tunnel_lines"
  echo '{"items": []}' >"$base/k8up.json"
  echo '{"items": [{"kind": "Job", "metadata": {"namespace": "keycloak", "name": "config-cli"}, "status": {"succeeded": 1}}]}' >"$base/jobs.json"
  echo abc123container >"$base/docker-ps.out"
  echo 1000000000 >"$base/database-size.out"
  printf '        Avail Use%% Mounted on\n100000000000 40%% /\n100000000000 40%% /opt\n' >"$base/df.out"
  for unit in hal-backup.service hal-backup-restore-test.service; do echo inactive >"$base/systemctl/$unit"; done
  for unit in hal-backup.timer hal-backup-restore-test.timer; do echo "@$(($(date +%s) + 100000))" >"$base/systemctl/$unit"; done
  echo '{"locks": []}' >"$base/lslocks.json"
  serve auth.hallucinai.de "http://127.0.0.1:8081$discovery_path" 200 application/json <<<"$discovery_body"
  serve auth.hallucinai.de "http://127.0.0.1:8081$certs_path" 200 application/json <<<'{"keys":[{"kid":"kid-b"},{"kid":"kid-a"}]}'
  serve "" "https://auth.hallucinai.de$discovery_path" 200 application/json <<<"$discovery_body"
  serve "" "https://auth.hallucinai.de$certs_path" 200 application/json <<<'{"keys":[{"kid":"kid-a"},{"kid":"kid-b"}]}'
  for host_and_path in presentator.hallucinai.de/health presentator-talk.hallucinai.de/health hallucinai.de/impressum; do
    serve "${host_and_path%%/*}" "http://127.0.0.1:8081/${host_and_path#*/}" 200 text/html </dev/null
  done
  serve x.hallucinai.de http://localhost:9000/h 204 </dev/null
  serve localhost http://127.0.0.1:8090/admin/ 302 text/html http://localhost:8090/admin/master/console/ </dev/null
  serve "" "http://127.0.0.1:$forward_port/realms/hallucinai/protocol/openid-connect/auth" 200 text/html <<<"$login_page"
  serve "" "http://127.0.0.1:$forward_port/resources/abcde/login/hallucinai/css/styles.css" 200 'text/css;charset=UTF-8' </dev/null
  build_home
}
write_tunnel_live() {
  local checksum
  jq -n --arg lines "$1" '{metadata: {name: "cloudflared"}, data: {"config.yaml": $lines}}' >"$scenario_directory/configmap.json"
  checksum="$(printf '%s' "$1" | sha256sum)"
  jq -n --arg checksum "${checksum%% *}" '{metadata: {name: "cloudflared", generation: 4},
    spec: {replicas: 1, template: {metadata: {annotations: {"checksum/config": $checksum}}}},
    status: {observedGeneration: 4, updatedReplicas: 1}}' >"$scenario_directory/deployment.json"
}
build_home() {
  local hal="$base/home/srv/hal"
  mkdir -p "$hal" "$base/home/.local/state/edge"
  : >"$base/home/.local/state/edge/backup.lock"
  "$real_git" -C "$hal" init --quiet --initial-branch=main
  "$real_git" -C "$hal" remote add origin https://github.com/overnightworks/hal.git
  "$real_git" -C "$hal" -c user.name=cell -c user.email=cell@example.invalid commit --quiet --allow-empty --message hal
  echo fleet.yaml >"$hal/.git/info/exclude"
  cat >"$hal/fleet.yaml" <<'YAML'
cloudflare: {zone: hallucinai.de}
services:
  hopin: {hosts: [{name: hopin, tunnel: platform, ready: /health}]}
  presentator: {hosts: [{name: presentator, ready: /health}, {name: presentator-talk, ready: /health}]}
  legal: {hosts: [{name: "@", ready: /impressum}]}
  keycloak: {hosts: [{name: auth, ready: "/realms/hallucinai/.well-known/openid-configuration"}]}
  songmaker: {hosts: [{name: songmaker, target: "http://localhost:8080"}]}
  other: {hosts: [{name: x, ready: /h, target: "http://localhost:9000"}]}
YAML
  hal_sha="$("$real_git" -C "$hal" rev-parse HEAD)"
  echo "$hal_sha" >"$base/gh/repos_overnightworks_hal_commits_main"
}

# ------------------------------------------------------------- running cases
export MISE_DISABLE_TOOLS=kubectl,flux,flux2,gh KUBECONFIG=/nonexistent
# script_env <command>...: the environment the script inherits, with the fakes first on PATH.
script_env() {
  env HOME="$case_home" PATH="$fake_bin:$PATH" FAKE_HOME="$case_home" FAKE_SCENARIO="$case_directory" FAKE_LOG="$case_directory/log" \
    FAKE_ROOT="$repository_root" FAKE_LIB="$work_directory/fake_lib.sh" FAKE_REAL_GIT="$real_git" FAKE_FORWARD_PORT="$forward_port" "$@"
}
new_case() {
  case_directory="$work_directory/cases/$1"
  case_name="$1"
  mkdir -p "$work_directory/cases"
  cp -a "$base" "$case_directory"
  scenario_directory="$case_directory"
  case_home="$case_directory/home"
  lock_file="$case_home/.local/state/edge/backup.lock"
}
edit() { jq "$2" "$case_directory/$1" >"$case_directory/$1.new" && mv "$case_directory/$1.new" "$case_directory/$1"; }
# hold_lock <pid> <blocker json>: lslocks lists an entry on the lock file's inode and device.
hold_lock() {
  jq -n --arg inode "$(stat -c %i "$lock_file")" --arg device "$(stat -c '%Hd:%Ld' "$lock_file")" --argjson pid "$1" --argjson blocker "$2" \
    '{locks: [{command: "hal", pid: $pid, inode: ($inode | tonumber), "maj:min": $device, blocker: $blocker}]}' >"$case_directory/lslocks.json"
}
# logs_clean: every call was one of the contract's reads, from the fakes first on PATH, by bare name.
logs_clean() {
  local script_under_test="${1:-$script}"
  [ ! -s "$case_directory/log/refused" ] || { reason="a call was refused: $(head -n 1 "$case_directory/log/refused")"; return 1; }
  if [ -f "$case_directory/log/path" ] && grep -qvxF "$fake_bin" "$case_directory/log/path"; then
    reason="a fake ran with another first PATH entry: the script changed PATH"
    return 1
  fi
  if grep -qE '(^|[[:space:];|&(])/(usr|bin|sbin)/' "$script_under_test"; then
    reason="the script calls an executable by an absolute path"
    return 1
  fi
}
# run_case <script> <argument>...: sets status and output.
run_script() {
  local script_under_test="$1"
  shift
  rm -rf "$case_directory/log"
  mkdir "$case_directory/log"
  status=0
  output="$(script_env "$script_under_test" "$@" 2>"$case_directory/stderr")" || status=$?
}
run_case() {
  run_script "$script" "$@"
  logs_clean || fail "$case_name: $reason"
}
expect_status() { [ "$status" = "$1" ] || fail "$case_name: exit $status, not $1: $output"; }
expect_line() { grep -qE "$1" <<<"$output" || fail "$case_name: no line matches '$1' in: $output"; }
expect_no_line() { ! grep -qE "$1" <<<"$output" || fail "$case_name: a line matches '$1' in: $output"; }
expect_no_evidence() { [ ! -e "$case_directory/evidence" ] || fail "$case_name: an evidence file was written"; }
empty_logs() {
  [ -z "$(find "$case_directory/log" -type f -size +0)" ] || fail "$case_name: a fake was called: $(find "$case_directory/log" -type f -size +0)"
}

build_base

# ------------------------------------------------------ interception
new_case healthy
for tool in kubectl flux gh curl docker systemctl lslocks df git; do
  [ "$(script_env bash -c 'command -v "$1"' _ "$tool")" = "$fake_bin/$tool" ] || fail "$tool does not resolve to its fake in the script's environment"
done

# ------------------------------------------------------ case 1: all healthy
required_ids=(N1 N2 N3 N4 I1 I2 H1 H2 H3 H4 H5 D1 B1 B2 L1 L2)
note_ids=(pod-logs record provider-keys hopin-key profile hal-plan recovery docker-disk sessions)
run_case --live --evidence "$case_directory/evidence"
expect_status 0
for id in "${required_ids[@]}"; do expect_line "^ok $id: "; done
for id in "${note_ids[@]}"; do expect_line "^note $id: not read here: .*; owner "; done
expect_line "^cutover:preflight: 16 ok, 0 FAIL, 0 UNKNOWN; evidence $case_directory/evidence\$"
expect_line "^ok I2: .*auth is not among them"
expect_line '^ok I1: .*hopin/http-from-traefik-only'
expect_no_line 'age1canary'
[ "$(stat -c %a "$case_directory/evidence")" = 600 ] || fail "healthy: the evidence file is not mode 600"
expected_evidence="issuer https://auth.hallucinai.de/realms/hallucinai
kid kid-a
kid kid-b
hal-main $hal_sha
platform $head_sha"
[ "$(head -n 5 "$case_directory/evidence")" = "$expected_evidence" ] || fail "healthy: the evidence file holds another content"
grep -qE '^read-at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$case_directory/evidence" || fail "healthy: the evidence file has no read-at time"

# ------------------------------------------------------ cases 2 and 3: FAIL exits 1, a failing reader exits 3
fail_N1() { edit nodes.json '.items[0].status.conditions |= map(if .type == "DiskPressure" then .status = "True" else . end)'; }
fail_N2() { echo "$other_sha" >"$case_directory/gh/repos_overnightworks_platform-secrets_commits_main"; }
fail_N3() { edit kustomizations.json '(.items[] | select(.metadata.name == "hopin") | .spec.suspend) = true'; }
fail_N4() { edit kustomizations.json "(.items[] | select(.metadata.name == \"flux-system\") | .status.lastAppliedRevision) = \"main@sha1:$other_sha\""; }
fail_I1() { edit networkpolicies-hopin.json '.items = []'; }
fail_I2() { edit configmap.json '.data["config.yaml"] += "# drift\n"'; }
fail_H1() { mkdir -p "$case_home/.local/state/edge/stopped" && : >"$case_home/.local/state/edge/stopped/keycloak"; }
fail_H2() { serve presentator.hallucinai.de http://127.0.0.1:8081/health 503 </dev/null; }
fail_H3() { serve localhost http://127.0.0.1:8090/admin/ 500 </dev/null; }
fail_H4() { serve auth.hallucinai.de "http://127.0.0.1:8081$certs_path" 200 application/json <<<'{"keys":[{"kid":"kid-a"},{"kid":"kid-c"}]}'; }
fail_H5() { : >"$case_home/srv/hal/untracked"; }
fail_D1() { printf '        Avail Use%% Mounted on\n1000 40%% /\n100000000000 40%% /opt\n' >"$case_directory/df.out"; }
fail_B1() { edit k8up.json '.items += [{kind: "Backup", metadata: {namespace: "keycloak", name: "b"}, status: {started: true}}]'; }
fail_B2() { hold_lock 4242 null; }
fail_L1() { serve "" "http://127.0.0.1:$forward_port/realms/hallucinai/protocol/openid-connect/auth" 200 text/html <<<'<link href="/resources/abcde/login/keycloak.v2/css/login.css">'; }
fail_L2() { printf 'creation_rules:\n  - age: age1canaryone\n' | base64 >"$case_directory/gh/repos_overnightworks_platform-secrets_contents_.sops.yaml"; }
unknown_N1() { touch "$case_directory/fail/kubectl-nodes"; }
unknown_N2() { touch "$case_directory/fail/gh-repos_overnightworks_platform_commits_main"; }
unknown_N3() { touch "$case_directory/fail/kubectl-kustomizations"; }
unknown_N4() { touch "$case_directory/fail/git-platform"; }
unknown_I1() { touch "$case_directory/fail/kubectl-crd"; }
unknown_I2() { touch "$case_directory/fail/kubectl-configmap"; }
unknown_H1() { serve auth.hallucinai.de "http://127.0.0.1:8081$discovery_path" 000 "" "" 127 </dev/null; }
unknown_H2() { echo 'services: [' >"$case_home/srv/hal/fleet.yaml"; }
unknown_H3() { serve localhost http://127.0.0.1:8090/admin/ 000 "" "" 127 </dev/null; }
unknown_H4() { serve "" "https://auth.hallucinai.de$certs_path" 000 "" "" 127 </dev/null; }
unknown_H5() { touch "$case_directory/fail/git-hal"; }
unknown_D1() { touch "$case_directory/fail/docker-exec"; }
unknown_B1() { touch "$case_directory/fail/kubectl-k8up"; }
unknown_B2() { touch "$case_directory/fail/lslocks"; }
unknown_L1() { touch "$case_directory/fail/kubectl-portforward"; }
unknown_L2() { touch "$case_directory/fail/gh-repos_overnightworks_platform-secrets_contents_.sops.yaml"; }
declare -A owner_of=([N1]=platform [N2]='overnightworks/platform-secrets' [N3]=hopin [N4]=platform [I1]='platform, the layer' [I2]=platform
  [H1]="hal's head" [H2]="hal's head" [H3]="hal's head" [H4]="hal's head" [H5]="hal's head; operator" [D1]='platform; operator frees space'
  [B1]="k8up" [B2]="hal's head" [L1]='#4' [L2]='#13')
for id in "${required_ids[@]}"; do
  new_case "fail-$id"
  "fail_$id"
  run_case --live --evidence "$case_directory/evidence"
  expect_status 1
  expect_line "^FAIL $id: .*; owner ${owner_of[$id]}\$"
  expect_no_evidence
  expect_line "evidence none\$"
  new_case "unknown-$id"
  "unknown_$id"
  run_case --live --evidence "$case_directory/evidence"
  expect_status 3
  expect_line "^UNKNOWN $id: "
  expect_no_line '^FAIL '
  expect_no_evidence
done

# ------------------------------------------------------ case 4: FAIL beside UNKNOWN
new_case fail-and-unknown
fail_N1
unknown_N3
run_case --evidence "$case_directory/evidence"
expect_status 1
expect_no_evidence

# ------------------------------------------------------ case 5: usage ends before any read
new_case usage
: >"$case_directory/existing"
for arguments in "--evidence $case_directory/existing" "--bogus" "--evidence" "--evidence --live" "--evidence $case_directory/missing/file" "--live extra"; do
  # shellcheck disable=SC2086 # the words of a case are its arguments
  run_case $arguments
  expect_status 2
  empty_logs
done

# ------------------------------------------------------ case 6: no --live, no L1 or L2
new_case without-live
run_case
expect_status 0
expect_no_line '^(ok|FAIL|UNKNOWN) L[12]:'
expect_line '^cutover:preflight: 14 ok, 0 FAIL, 0 UNKNOWN; evidence none$'
[ ! -e "$case_directory/log/kubectl" ] || ! grep -q port-forward "$case_directory/log/kubectl" || fail "without-live: a port-forward was started"

# ------------------------------------------------------ case 7: main@sha1:<sha> against GitHub's <sha>
new_case revision-form
run_case
expect_line '^ok N2: '

# ------------------------------------------------------ case 8: the lock held, waited for, absent
new_case lock-held
hold_lock 4242 null
run_case
expect_line '^FAIL B2: pid 4242 holds the lock'
new_case lock-waited
hold_lock 4243 4242
run_case
expect_line '^FAIL B2: pid 4243 waits for the lock'
new_case lock-absent
rm "$lock_file"
run_case
expect_line '^ok B2: '

# ------------------------------------------------------ case 9: I1 by namespace/name over normalised .spec
new_case policy-missing
edit networkpolicies-keycloak.json '.items |= map(select(.metadata.name != "keycloak-egress"))'
run_case
expect_line '^FAIL I1: missing keycloak/keycloak-egress;'
new_case policy-extra
edit networkpolicies-litellm.json '.items += [(.items[0] | .metadata.name = "leftover")]'
run_case
expect_line '^FAIL I1: extra litellm/leftover;'
new_case policy-changed
edit networkpolicies-litellm.json '.items[0].spec.ingress[0].ports[0].port = 4001'
run_case
expect_line '^FAIL I1: differs litellm/litellm;'
new_case policy-same-name-elsewhere
fail_I1
run_case
expect_line '^FAIL I1: missing hopin/http-from-traefik-only;'
expect_no_line 'keycloak/http-from-traefik-only;'
new_case policy-crd
echo customresourcedefinition.apiextensions.k8s.io/adminnetworkpolicies.policy.networking.k8s.io >"$case_directory/crds.out"
run_case
expect_line '^UNKNOWN I1: an admin-policy CRD exists'

# ------------------------------------------------------ the tunnel's hostnames
new_case tunnel-with-auth
auth_lines=$'ingress:\n  - hostname: auth.hallucinai.de\n    service: http://traefik.traefik:80\n  - service: http_status:404\n'
jq -n --arg lines "$auth_lines" '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "cloudflared", namespace: "cloudflared"}, data: {"config.yaml": $lines}}' |
  yq --prettyPrint '.' >"$case_directory/render-tunnel.yaml"
write_tunnel_live "$auth_lines"
run_case
expect_line '^ok I2: .*auth is among them'

# ------------------------------------------------------ the evidence file appears while the run reads
new_case evidence-race
echo "$case_directory/evidence" >"$case_directory/create-on-df"
run_case --evidence "$case_directory/evidence"
expect_status 1
expect_line '^FAIL E1: '
[ ! -s "$case_directory/evidence" ] || fail "evidence-race: the existing file was written over"

# ------------------------------------------------------ planted forbidden calls turn the cell red
# plant <label> <line>...: a scratch copy of the script that makes the calls before its first condition, run on the healthy scenario.
plant() {
  local label="$1" planted="$work_directory/planted-$1.sh" line
  shift
  new_case "planted-$label"
  {
    while IFS= read -r line; do
      case "$line" in
        'root='*) echo "root=\"$repository_root\"" ;;
        check_N1) printf '%s\n' "$@"; echo check_N1 ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <"$script"
  } >"$planted"
  chmod +x "$planted"
  run_script "$planted" --live
  if logs_clean "$planted"; then fail "planted $label: the cell stayed green"; fi
  echo "planted $label turns the cell red: $reason"
}
plant absolute-path '/usr/bin/true'
plant changed-path 'PATH="/usr/sbin:$PATH"; kubectl get nodes --output json >/dev/null || true'
plant git-fetch 'git -C "$root" fetch || true'
plant git-status-with-locks 'git -C "$root" status --porcelain || true'
plant curl-request 'curl --silent --request POST http://127.0.0.1:8081/realms/hallucinai/.well-known/openid-configuration || true'
plant curl-data-without-get 'curl --silent --data a=b http://127.0.0.1:8081/realms/hallucinai/.well-known/openid-configuration || true'
plant curl-unlisted-url 'curl --silent https://example.invalid/x || true'
plant gh-method-post 'gh api repos/overnightworks/platform/commits/main --method POST || true'
plant gh-field-without-method 'gh api repos/overnightworks/platform/commits/main -f x=y || true'
plant gh-unlisted-endpoint 'gh api user --jq .login || true'
plant kubectl-annotate 'kubectl annotate nodes pc a=b || true'
plant kubectl-get-secret 'kubectl get secret litellm --output json || true'
plant flux-without-in-memory 'flux build kustomization tunnel --path "$root/infrastructure/cloudflared" || true'
plant psql-without-read-only-transaction 'docker exec abc123container psql --username=keycloak --dbname=keycloak --no-psqlrc -Atc "select 1" || true'

echo "cutover:preflight names each missing precondition: ${#required_ids[@]} conditions, FAIL, UNKNOWN, usage, evidence, I1, interception and read-only held"
