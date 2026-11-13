#!/usr/bin/env bash
# keycloak_hold.sh --scratch DIR: starts Keycloak with its Postgres at the images and environment of
# infrastructure/keycloak and infrastructure/postgres, applies master.yaml and realm.yaml through config-cli, prints one
# line `READY <json>` and holds until SIGTERM, SIGINT or EOF on stdin. Teardown removes every container, network and
# volume of its compose project, and only of that one; it prints `HOLD ENDED` and exits 0. A failed bring-up, a signal
# before READY or an object left after teardown prints `PROBE FAILED: <what>` and exits 1; a scratch directory that is
# not new or empty exits 2. DIR holds the generated secrets and the env files while the hold runs and loses them on
# every exit once docker's teardown ran; the project's name and docker's log (the containers' log after a failure) stay
# with the caller.
# Each run has its own compose project and its own host ports, so holds run side by side. The caller runs it under
# probe-run. Keycloak serves edge_url itself; a client sends `Host: auth.hallucinai.de` and `X-Forwarded-Proto: https`
# as Traefik would, from an address of the hold's network.
# Keycloak is not restarted after the apply: right after config-cli exits 0 it serves master's frontendUrl and the
# admin client, which tests/keycloak/hold_serves_the_realm_and_leaves_nothing.sh proves by the token it requests at
# admin_url and the client it creates and deletes straight after READY.
set -euo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
compose_file="$root/scripts/keycloak_hold.compose.yaml"
keycloak_manifest="$root/infrastructure/keycloak/keycloak.yaml"
config_cli_manifest="$root/infrastructure/keycloak/config-cli.yaml"
postgres_manifest="$root/infrastructure/postgres/postgres.yaml"
kustomization="$root/infrastructure/keycloak/kustomization.yaml"
project="" log="" scratch="" child="" failure="" stop_signal="" fail_after_teardown=""
compose_command=()
# probe-run kills what still runs 30 s after its TERM, which a stopped docker command and the teardown share: a command
# that is running when the hold is stopped may end by itself for command_settle_seconds, so that a container whose creation
# it has already requested exists when the teardown looks, and one that outlives its SIGTERM by child_stop_seconds is killed.
command_settle_seconds=10
child_stop_seconds=3
child_settle_seconds=0
# docker finishes a request a killed command had sent, so the teardown repeats until the project stays empty.
teardown_rounds=4
project_claimed=0 ready=0
# Set by container_value.
password_mount="" manifest_admin_url="" public_hostname="" admin_client_id="" admin_secret_ref=""
# Values the hold sets for env names its manifests also hold.
declare -A hold_env=()

fail() { failure="$1"; exit 1; }

# await runs the command itself, so a compose command it starts is the array, not this function.
compose() { "${compose_command[@]}" "$@"; }

# The project's containers (one-off runs included), networks and volumes, one name per line.
# A listing that fails fails the function, so an empty answer is never taken for a clean teardown.
project_objects() {
  local label="label=com.docker.compose.project=$project"
  docker ps --all --quiet --filter "$label" || return
  docker network ls --quiet --filter "$label" || return
  docker volume ls --quiet --filter "$label" || return
}

# Runs a command with docker's output in the log, in a session of its own so that stop_child reaches the compose plugin
# the docker command starts, and waits for it in a way a trapped signal interrupts at once. The command must be an
# executable and not a shell function, so that $child is the pid of the session's leader.
await() {
  local status=0
  setsid "$@" >>"$log" 2>&1 &
  child=$!
  child_settle_seconds=$command_settle_seconds
  wait "$child" || status=$?
  child="" child_settle_seconds=0
  return "$status"
}

# Removes the project and lists what is left, again until two rounds in a row find it clean: docker finishes a create
# request that a stopped compose command had already sent, which can land after the first `down` listed the project.
teardown() {
  local round clean_rounds=0 down_failed leftovers listing_failed
  for ((round = 0; round < teardown_rounds && clean_rounds < 2; round++)); do
    down_failed=0 listing_failed=0
    await "${compose_command[@]}" down --volumes --remove-orphans || down_failed=1
    leftovers="$(project_objects)" || listing_failed=1
    if [ "$down_failed$listing_failed" = 00 ] && [ -z "$leftovers" ]; then clean_rounds=$((clean_rounds + 1)); else clean_rounds=0; fi
    [ "$clean_rounds" -ge 2 ] || sleep 1
  done
  [ "$clean_rounds" -lt 2 ] || return 0
  [ "$down_failed" = 0 ] || fail_after_teardown="docker compose down failed"
  if [ "$listing_failed" = 1 ]; then
    fail_after_teardown="${fail_after_teardown:+$fail_after_teardown; }docker could not list the objects of $project, so the teardown is unverified"
  elif [ -n "$leftovers" ]; then
    fail_after_teardown="${fail_after_teardown:+$fail_after_teardown; }left after teardown: $(tr '\n' ' ' <<<"$leftovers")"
  fi
}

# True while a process of the session $1 leads, a zombie apart.
session_runs() { ps -o stat= --sid "$1" 2>/dev/null | grep -qv '^Z'; }

await_session_gone() {
  local attempt=0
  while session_runs "$1"; do
    [ "$attempt" -lt $(($2 * 5)) ] || return 1
    attempt=$((attempt + 1))
    sleep 0.2
  done
}

# Stops the session of the running child and waits until no process of it remains, so that nothing it still creates
# appears after the teardown listed the project: it may end by itself for child_settle_seconds, then gets SIGTERM, and a
# session that ignores that for child_stop_seconds is killed.
stop_child() {
  if ! await_session_gone "$child" "$child_settle_seconds"; then
    kill -TERM -- "-$child" 2>/dev/null || true
  fi
  if ! await_session_gone "$child" "$child_stop_seconds"; then
    kill -KILL -- "-$child" 2>/dev/null || true
    await_session_gone "$child" 5 || true
  fi
  session_runs "$child" || wait "$child" 2>/dev/null || true
  child=""
}

finish() {
  local status=$?
  trap '' TERM INT
  trap - EXIT
  [ -z "$child" ] || stop_child
  if [ "$project_claimed" = 1 ]; then
    [ -z "$failure" ] || compose logs --no-color >"$scratch/containers.log" 2>&1 || true
    teardown || true
  fi
  # The generated secrets and the env files that carry them outlive neither the hold nor a failed one.
  [ -z "$scratch" ] || rm -rf "$scratch/secrets" "$scratch"/*.env
  [ -z "$fail_after_teardown" ] || failure="${failure:+$failure; }$fail_after_teardown"
  if [ "$ready" = 0 ] && [ -z "$failure" ]; then
    failure="${stop_signal:+stopped by $stop_signal before READY}"
    failure="${failure:-the script stopped with status $status before READY}"
  fi
  if [ -z "$failure" ]; then echo "HOLD ENDED"; exit 0; fi
  echo "PROBE FAILED: $failure"
  exit 1
}

usage_error() { echo "keycloak_hold.sh: $1" >&2; exit 2; }

[ "$#" = 2 ] && [ "$1" = --scratch ] || usage_error "usage: keycloak_hold.sh --scratch DIR"
if [ -e "$2" ]; then
  [ -d "$2" ] && [ -z "$(ls -A "$2")" ] || usage_error "$2 is not an empty directory"
else
  mkdir -p "$2"
fi
chmod 700 "$2"
scratch="$(cd "$2" && pwd -P)"
log="$scratch/hold.log"
: >"$log"
project="platform-keycloak-hold-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
compose_command=(docker compose --project-name "$project" --file "$compose_file")
echo "$project" >"$scratch/project"

trap 'stop_signal=SIGTERM; exit 1' TERM
trap 'stop_signal=SIGINT; exit 1' INT
trap finish EXIT

# Reads one value of a container in a pod template of a manifest into the variable named by $1.
container_value() {
  local out
  out="$(yq "select(.kind == \"$3\") | .spec.template.spec.containers[] | select(.name == \"$4\") | $5" "$2")" ||
    fail "yq could not read $5 of $2"
  { [ -n "$out" ] && [ "$out" != null ]; } || fail "$2 holds no $5 for its container $4"
  printf -v "$1" '%s' "$out"
}
keycloak_value() { container_value "$1" "$keycloak_manifest" Deployment keycloak "$2"; }
keycloak_env() { keycloak_value "$1" ".env[] | select(.name == \"$2\") | .value"; }

# The path of the generated value for a Secret key; the value never leaves its file but for the env files and the
# password file.
secret_path() { printf '%s' "$scratch/secrets/${1%/*}.${1#*/}"; }
ensure_secret() {
  local path
  path="$(secret_path "$1")"
  [ -e "$path" ] || head -c 48 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=' >"$path"
}

# Writes the env file of a container from its env list: a name in hold_env as the hold sets it, a literal as it stands,
# the namespace as the namespace of kustomization.yaml, a Secret key as its generated value, and a name with no value
# as Keycloak's own, which kustomization.yaml copies into config-cli.
write_env() {
  local manifest="$1" kind="$2" container="$3" file="$4" entries name form payload value inherited
  entries="$(yq "select(.kind == \"$kind\") | .spec.template.spec.containers[] | select(.name == \"$container\") | .env[]
    | .name + \"|\" + (
      (select(has(\"value\")) | \"value|\" + (.value | tostring))
      // (select(.valueFrom.fieldRef) | \"field|\" + .valueFrom.fieldRef.fieldPath)
      // (select(.valueFrom.secretKeyRef) | \"secret|\" + .valueFrom.secretKeyRef.name + \"/\" + .valueFrom.secretKeyRef.key)
      // (select(has(\"valueFrom\") | not) | \"inherit|\")
      // \"unknown|\")" "$manifest")" || fail "yq could not read the env of $container in $manifest"
  : >"$file"
  while IFS='|' read -r name form payload; do
    if [[ -v "hold_env[$name]" ]]; then
      printf '%s=%s\n' "$name" "${hold_env[$name]}" >>"$file"
      continue
    fi
    case "$form" in
      value) value="$payload" ;;
      field)
        [ "$payload" = metadata.namespace ] ||
          fail "$name in $manifest reads the field $payload; the hold knows only metadata.namespace"
        value="$namespace" ;;
      secret)
        ensure_secret "$payload"
        value="$(<"$(secret_path "$payload")")" ;;
      inherit)
        keycloak_env inherited "$name"
        value="$inherited" ;;
      *) fail "$name in $manifest has an env form the hold does not know" ;;
    esac
    printf '%s=%s\n' "$name" "$value" >>"$file"
  done <<<"$entries"
}

# A port in the range below the kernel's ephemeral ports that nothing listens on, other than the ones already taken.
free_port() {
  local port
  while :; do
    port=$((20000 + RANDOM % 12000))
    [[ " $* " != *" $port "* ]] || continue
    [ -n "$(ss -Htln "sport = :$port")" ] || { echo "$port"; return; }
  done
}

docker info >/dev/null 2>&1 || fail "docker is not reachable"
network_key="$(yq '.networks | keys | .[0]' "$compose_file")"

mkdir "$scratch/secrets"
namespace="$(yq '.namespace' "$kustomization")"
export HOLD_SCRATCH="$scratch"

container_value KEYCLOAK_IMAGE "$keycloak_manifest" Deployment keycloak .image
container_value KEYCLOAK_ARGS "$keycloak_manifest" Deployment keycloak '.args | join(" ")'
container_value KEYCLOAK_HTTP_PORT "$keycloak_manifest" Deployment keycloak '.ports[] | select(.name == "http") | .containerPort'
container_value KEYCLOAK_THEME_DIR "$keycloak_manifest" Deployment keycloak '.volumeMounts[] | select(.name == "theme") | .mountPath'
container_value KEYCLOAK_TMP_DIR "$keycloak_manifest" Deployment keycloak '.volumeMounts[] | select(.name == "tmp") | .mountPath'
container_value CONFIG_CLI_IMAGE "$config_cli_manifest" Job config-cli .image
container_value CONFIG_CLI_COMMAND "$config_cli_manifest" Job config-cli '.command | join(" ")'
container_value CONFIG_CLI_DIR "$config_cli_manifest" Job config-cli '.volumeMounts[] | select(.name == "realms") | .mountPath'
container_value POSTGRES_IMAGE "$postgres_manifest" StatefulSet postgres .image
container_value POSTGRES_DATA_DIR "$postgres_manifest" StatefulSet postgres '.volumeMounts[] | select(.name == "data") | .mountPath'
container_value POSTGRES_PASSWORD_PATH "$postgres_manifest" StatefulSet postgres '.env[] | select(.name == "POSTGRES_PASSWORD_FILE") | .value'
container_value POSTGRES_READINESS_COMMAND "$postgres_manifest" StatefulSet postgres '.readinessProbe.exec.command | join(" ")'
container_value password_mount "$postgres_manifest" StatefulSet postgres '.volumeMounts[] | select(.name == "password") | .mountPath'
backoff_limit="$(yq 'select(.kind == "Job") | .spec.backoffLimit' "$config_cli_manifest")" ||
  fail "yq could not read the backoffLimit of $config_cli_manifest"
[ "$(dirname "$POSTGRES_PASSWORD_PATH")" = "$password_mount" ] ||
  fail "$postgres_manifest reads the password from $POSTGRES_PASSWORD_PATH, outside the mount $password_mount"
keycloak_env manifest_admin_url KC_HOSTNAME_ADMIN
keycloak_env public_hostname KC_HOSTNAME
keycloak_env admin_client_id KC_BOOTSTRAP_ADMIN_CLIENT_ID
keycloak_value admin_secret_ref '.env[] | select(.name == "KC_BOOTSTRAP_ADMIN_CLIENT_SECRET") | .valueFrom.secretKeyRef | .name + "/" + .key'
# Keycloak's admin front end names the port a client reaches it at, so the hold's own port replaces the cluster's.
[[ $manifest_admin_url =~ ^(http://localhost):[0-9]+$ ]] ||
  fail "KC_HOSTNAME_ADMIN reads '$manifest_admin_url', not http://localhost:<port>"
admin_host="${BASH_REMATCH[1]}"
export HOLD_ADMIN_PORT HOLD_EDGE_PORT
HOLD_ADMIN_PORT="$(free_port)"
HOLD_EDGE_PORT="$(free_port "$HOLD_ADMIN_PORT")"
admin_url="$admin_host:$HOLD_ADMIN_PORT"
hold_env[KC_HOSTNAME_ADMIN]="$admin_url"
realm="$(yq '.realm' "$root/infrastructure/keycloak/realm.yaml")"

write_env "$config_cli_manifest" Job config-cli "$scratch/config-cli.env"
write_env "$postgres_manifest" StatefulSet postgres "$scratch/postgres.env"
# Compose reads every env file when it creates the network; Keycloak's is written once the network has its addresses.
: >"$scratch/keycloak.env"
ensure_secret "postgres/$(basename "$POSTGRES_PASSWORD_PATH")"

# Keycloak reads its theme beside the design kit it links; both stay in the tree, so the hold assembles a copy.
theme_dir="$scratch/theme"
mkdir "$theme_dir"
cp -R "$root/infrastructure/keycloak/themes/hallucinai/." "$theme_dir/"
for area in login account; do
  cp -R "$root"/infrastructure/design/*/ "$theme_dir/$area/resources/"
done
chmod -R a+rX "$theme_dir"

export HOLD_THEME_SOURCE="$theme_dir"
export HOLD_MASTER_FILE="$root/infrastructure/keycloak/master.yaml"
export HOLD_REALM_FILE="$root/infrastructure/keycloak/realm.yaml"
export POSTGRES_PASSWORD_SOURCE
POSTGRES_PASSWORD_SOURCE="$(secret_path "postgres/$(basename "$POSTGRES_PASSWORD_PATH")")"
export KEYCLOAK_IMAGE KEYCLOAK_ARGS KEYCLOAK_HTTP_PORT KEYCLOAK_THEME_DIR KEYCLOAK_TMP_DIR \
  CONFIG_CLI_IMAGE CONFIG_CLI_COMMAND CONFIG_CLI_DIR POSTGRES_IMAGE POSTGRES_DATA_DIR POSTGRES_PASSWORD_PATH \
  POSTGRES_READINESS_COMMAND

# The network exists before Keycloak's env file is written, because Keycloak trusts the forwarded headers of that
# network's addresses, which docker picks.
project_claimed=1
await "${compose_command[@]}" up --no-start postgres || fail "docker compose could not create the network; see $log"
subnets="$(docker network inspect "${project}_$network_key" --format '{{range .IPAM.Config}}{{.Subnet}},{{end}}')" ||
  fail "docker could not inspect the network ${project}_$network_key"
[ -n "${subnets%,}" ] || fail "the network ${project}_$network_key has no address range"
hold_env[KC_PROXY_TRUSTED_ADDRESSES]="${subnets%,}"
write_env "$keycloak_manifest" Deployment keycloak "$scratch/keycloak.env"

await "${compose_command[@]}" up --detach postgres keycloak ||
  fail "docker compose could not start Keycloak: $(tail -n 1 "$log")"

attempts=$((backoff_limit + 1))
applied=0
for _ in $(seq "$attempts"); do
  # -T: the hold's stdin is the stop signal, which a run must not take.
  if await "${compose_command[@]}" run --rm --no-deps -T config-cli; then applied=1; break; fi
done
[ "$applied" = 1 ] || fail "config-cli failed $attempts times; its output is in $log"

keycloak_network="$(docker network ls --format '{{.Name}}' \
  --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.network=$network_key")"
edge_url="http://127.0.0.1:$HOLD_EDGE_PORT"
admin_client_secret_file="$(secret_path "$admin_secret_ref")"
public_issuer="$public_hostname/realms/$realm"
export edge_url admin_url admin_client_id admin_client_secret_file realm public_issuer keycloak_network project
ready_json="$(yq --null-input --output-format=json --indent=0 '{"edge_url": strenv(edge_url), "admin_url": strenv(admin_url),
  "admin_client_id": strenv(admin_client_id), "admin_client_secret_file": strenv(admin_client_secret_file),
  "realm": strenv(realm), "public_issuer": strenv(public_issuer), "keycloak_network": strenv(keycloak_network),
  "project": strenv(project)}')"
ready=1
echo "READY $ready_json"

setsid cat <&0 >/dev/null &
child=$!
wait "$child" || true
child=""
