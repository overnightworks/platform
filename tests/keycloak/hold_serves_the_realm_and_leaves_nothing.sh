#!/usr/bin/env bash
# hold_serves_the_realm_and_leaves_nothing.sh: drives the Keycloak hold twice, as an app's end-to-end proof does. Hold 1,
# started with `mise run keycloak:hold`, serves hallucinai's realm through its edge and admin addresses and ends on EOF
# with `HOLD ENDED`. Hold 2 runs beside it in a project of its own, started as the script itself since mise run's
# wrapper dies on SIGTERM without waiting for the teardown; it gets SIGTERM before READY and ends with `PROBE FAILED`
# while hold 1 still answers.
# After both, no container, network or volume of either project remains and no generated secret is in any output.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ready_seconds=900
# probe-run's `timeout -k 30` kills what is still running 30 s after its TERM, so a stop must finish within it.
teardown_seconds=30
project_prefix=platform-keycloak-hold-

work="$(mktemp -d)"
postgres_image="$(yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].image' infrastructure/postgres/postgres.yaml)"
keycloak_port="$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].ports[] | select(.name == "http") | .containerPort' infrastructure/keycloak/keycloak.yaml)"
hold_pids=()

fail() { echo "::error::$1" >&2; exit 1; }

# project_objects <project>: the project's containers (one-off runs included), networks and volumes, one id per line.
project_objects() {
  local label="label=com.docker.compose.project=$1"
  docker ps --all --quiet --filter "$label"
  docker network ls --quiet --filter "$label"
  docker volume ls --quiet --filter "$label"
}

stop_holds() {
  local pid
  for pid in "${hold_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
}
finish() {
  local status=$? log project_file project
  stop_holds
  if [ "$status" != 0 ]; then
    for log in "$work"/*-scratch/hold.log "$work"/*-scratch/containers.log; do
      [ -f "$log" ] && { echo "--- tail of $log" >&2; tail -n 40 "$log" >&2; }
    done
  fi
  # A hold that mise run abandoned (it exits on a signal and leaves the script to finish alone) leaves its project; the
  # holds of this test name their projects in their scratch directories.
  for project_file in "$work"/*-scratch/project; do
    [ -f "$project_file" ] || continue
    project="$(<"$project_file")"
    [ -z "$(project_objects "$project")" ] ||
      docker compose --project-name "$project" down --volumes --remove-orphans >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap finish EXIT

# known_secrets <name>: keeps the values of a running hold's generated secrets, which its scratch directory loses at the
# end, for the search of the outputs.
known_secrets() {
  local secret
  mkdir -p "$work/known-secrets"
  for secret in "$work/$1-scratch"/secrets/*; do
    cp "$secret" "$work/known-secrets/$1.$(basename "$secret")"
  done
}

# await_project <name> <pid>: waits until the hold has created an object of its project and sets project_name.
await_project() {
  local deadline=$((SECONDS + 120))
  until [ -f "$work/$1-scratch/project" ] && project_name="$(<"$work/$1-scratch/project")" && [ -n "$(project_objects "$project_name")" ]; do
    kill -0 "$2" 2>/dev/null || fail "$1 ended before it created anything: $(cat "$work/$1.out")"
    [ "$SECONDS" -lt "$deadline" ] || fail "$1 created nothing in 120 s"
    sleep 1
  done
}

# start_hold <name> <stdin file> <command>...: runs the hold in the background with its output in $work/<name>.{out,err}.
start_hold() {
  local name="$1" stdin="$2"
  shift 2
  "$@" --scratch "$work/$name-scratch" <"$stdin" >"$work/$name.out" 2>"$work/$name.err" 3>&- &
  hold_pids+=("$!")
  hold_pid="$!"
}

# await_exit <pid> <seconds>: waits for the process and sets exit_status.
await_exit() {
  local deadline=$((SECONDS + $2))
  while kill -0 "$1" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || fail "process $1 still runs after $2 s"
    sleep 1
  done
  exit_status=0
  wait "$1" || exit_status=$?
}

# --- exit 2 for a scratch directory that is not empty
mkdir "$work/occupied" && touch "$work/occupied/file"
status=0
mise run keycloak:hold --scratch "$work/occupied" >"$work/occupied.out" 2>&1 || status=$?
[ "$status" = 2 ] || fail "a scratch directory with a file ended with $status, not 2"
grep -q 'is not an empty directory' "$work/occupied.out" || fail "the refusal names no cause"

# --- hold 3: a docker that cannot list containers leaves the teardown unverified, which the hold reports
mkdir "$work/shim"
cat >"$work/shim/docker" <<'SHIM'
#!/bin/sh
[ "$1" != ps ] || { echo "docker ps is refused" >&2; exit 1; }
exec "$REAL_DOCKER" "$@"
SHIM
chmod +x "$work/shim/docker"
start_hold hold3 /dev/null env REAL_DOCKER="$(command -v docker)" PATH="$work/shim:$PATH" scripts/keycloak_hold.sh
hold3_pid="$hold_pid"
await_project hold3 "$hold3_pid"
project3="$project_name"
kill -TERM "$hold3_pid"
await_exit "$hold3_pid" 120
[ "$exit_status" = 1 ] || fail "hold 3 ended with $exit_status although docker could not list its containers, not 1"
grep -q '^PROBE FAILED: .*could not list' "$work/hold3.out" || fail "hold 3 did not report the unverified teardown: $(cat "$work/hold3.out")"

# --- hold 1
mkfifo "$work/stdin1"
exec 3<>"$work/stdin1"
started=$SECONDS
start_hold hold1 "$work/stdin1" mise run keycloak:hold
hold1_pid="$hold_pid"
while ! grep -q '^READY ' "$work/hold1.out"; do
  kill -0 "$hold1_pid" 2>/dev/null || fail "hold 1 ended before READY: $(cat "$work/hold1.out")"
  [ "$SECONDS" -lt $((started + ready_seconds)) ] || fail "hold 1 printed no READY in $ready_seconds s"
  sleep 2
done
echo "hold 1 was ready after $((SECONDS - started)) s"
[ "$(grep -c . "$work/hold1.out")" = 1 ] || fail "hold 1 printed more than the READY line before it stopped"
ready="$(sed 's/^READY //' "$work/hold1.out")"
field() { yq -p=json -oy ".$1" <<<"$ready"; }
for key in edge_url admin_url admin_client_id admin_client_secret_file realm public_issuer keycloak_network project; do
  [ "$(field "$key")" != null ] || fail "the READY line holds no $key"
done
edge_url="$(field edge_url)" admin_url="$(field admin_url)" client_id="$(field admin_client_id)"
secret_file="$(field admin_client_secret_file)" realm="$(field realm)" issuer="$(field public_issuer)"
network="$(field keycloak_network)" project1="$(field project)"
[[ $project1 == "$project_prefix"* ]] || fail "hold 1 names the project $project1, not one of $project_prefix"
[ "$(<"$work/hold1-scratch/project")" = "$project1" ] || fail "the project of the READY line is not the one in the scratch directory"
[ -z "$(find "$work/hold1-scratch/secrets" -type f ! -perm 600)" ] &&
  [ -z "$(find "$work/hold1-scratch" -maxdepth 1 -name '*.env' ! -perm 600)" ] ||
  fail "a generated secret or env file of hold 1 is not at mode 600"
known_secrets hold1
public_host="${issuer#https://}"
public_host="${public_host%%/*}"

# discovery_issuer <url>: the issuer a client reads at an edge, sent as the tunnel sends it.
discovery_issuer() {
  curl -sS --fail --header "Host: $public_host" --header 'X-Forwarded-Proto: https' \
    "$1/realms/$realm/.well-known/openid-configuration" | yq -p=json -oy '.issuer'
}
[ "$(discovery_issuer "$edge_url")" = "$issuer" ] || fail "discovery through the edge does not name $issuer"

# A token of the admin client, from its secret file, which never appears in an argument.
token="$(curl -sS --fail "$admin_url/realms/master/protocol/openid-connect/token" --data grant_type=client_credentials \
  --data-urlencode "client_id=$client_id" --data-urlencode "client_secret@$secret_file" | yq -p=json -oy '.access_token')"
printf 'Authorization: Bearer %s\n' "$token" >"$work/bearer"
# api <method> <path> [curl arguments]: prints the status; the body is in $work/body.
api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --output "$work/body" --write-out '%{http_code}' --request "$method" --header @"$work/bearer" \
    "$admin_url/admin/realms/$realm$path" "$@"
}
[ "$(api GET /group-by-path/apps/songmaker/admin)" = 200 ] || fail "the group /apps/songmaker/admin is not readable"
[ "$(api GET /client-scopes)" = 200 ] || fail "the client scopes are not readable"
for scope in basic profile groups; do
  [ "$(yq -p=json -oy ".[] | select(.name == \"$scope\") | .name" "$work/body")" = "$scope" ] || fail "the client scope $scope is absent"
done
[ "$(api POST /clients --header 'Content-Type: application/json' --data '{"clientId": "hold-test"}')" = 201 ] ||
  fail "a client cannot be created"
[ "$(api GET '/clients?clientId=hold-test')" = 200 ] || fail "the created client cannot be listed"
client_uuid="$(yq -p=json -oy '.[0].id' "$work/body")"
[ "$(api DELETE "/clients/$client_uuid")" = 204 ] || fail "the created client cannot be deleted"
[ "$(api GET "/clients/$client_uuid")" = 404 ] || fail "the deleted client still answers"

# A container on the hold's network reaches Keycloak by its service name.
docker run --rm --network "$network" --entrypoint wget "$postgres_image" -qO- \
  "http://keycloak:$keycloak_port/realms/$realm/.well-known/openid-configuration" |
  yq -p=json -oy '.issuer' | grep -qxF "$issuer" || fail "a container on $network does not reach Keycloak"

# --- hold 2 beside hold 1: SIGTERM before READY
start_hold hold2 /dev/null scripts/keycloak_hold.sh
hold2_pid="$hold_pid"
deadline=$((SECONDS + 120))
until [ -f "$work/hold2-scratch/project" ] && project2="$(<"$work/hold2-scratch/project")" && [ -n "$(project_objects "$project2")" ]; do
  kill -0 "$hold2_pid" 2>/dev/null || fail "hold 2 ended before it created anything: $(cat "$work/hold2.out")"
  [ "$SECONDS" -lt "$deadline" ] || fail "hold 2 created nothing in 120 s"
  sleep 1
done
[ "$project2" != "$project1" ] || fail "both holds run the project $project1"
known_secrets hold2
stopped=$SECONDS
kill -TERM "$hold2_pid"
await_exit "$hold2_pid" 120
echo "hold 2 ended $((SECONDS - stopped)) s after SIGTERM before READY"
[ "$exit_status" = 1 ] || fail "hold 2 ended with $exit_status after SIGTERM before READY, not 1"
grep -q '^PROBE FAILED: ' "$work/hold2.out" || fail "hold 2 did not print PROBE FAILED: $(cat "$work/hold2.out")"
! grep -q '^READY ' "$work/hold2.out" || fail "hold 2 printed READY"
[ -z "$(project_objects "$project2")" ] || fail "hold 2 left $(project_objects "$project2" | tr '\n' ' ')"
[ "$(discovery_issuer "$edge_url")" = "$issuer" ] || fail "the end of hold 2 took hold 1 down"

# --- EOF ends hold 1
stopped=$SECONDS
exec 3>&-
await_exit "$hold1_pid" 120
[ "$exit_status" = 0 ] || fail "hold 1 ended with $exit_status after EOF"
[ "$(tail -n 1 "$work/hold1.out")" = "HOLD ENDED" ] || fail "hold 1 did not end with HOLD ENDED: $(tail -n 2 "$work/hold1.out")"
echo "hold 1 ended $((SECONDS - stopped)) s after EOF"
[ $((SECONDS - stopped)) -le "$teardown_seconds" ] || fail "the teardown took longer than $teardown_seconds s"

# --- nothing is left, and no generated secret was printed
for project in "$project1" "$project2" "$project3"; do
  [ -z "$(project_objects "$project")" ] || fail "the holds left $(project_objects "$project" | tr '\n' ' ')"
done
for scratch in "$work"/hold[123]-scratch; do
  [ ! -e "$scratch/secrets" ] && [ -z "$(find "$scratch" -name '*.env')" ] ||
    fail "$(basename "$scratch") kept a generated secret or env file after it ended"
done
secrets=0
for secret in "$work"/known-secrets/*; do
  [ -f "$secret" ] || continue
  secrets=$((secrets + 1))
  if grep -qFf "$secret" "$work"/*.out "$work"/*.err; then fail "a generated secret is in the output of a hold"; fi
done
[ "$secrets" -gt 0 ] || fail "no generated secret was found to look for"
echo "$project1, $project2 and $project3 left nothing; none of $secrets generated secrets was printed"
