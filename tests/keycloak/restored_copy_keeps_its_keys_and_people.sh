#!/usr/bin/env bash
# restored_copy_keeps_its_keys_and_people.sh <dump>: on the PC, after db:load-dump keycloak <dump> converged, shows
# that config-cli's Job completed within its retries, that Keycloak created no temporary administrator, that the
# realm's key ids equal those of the public issuer, and that config-cli left the users, credentials and group
# memberships as the dump holds them. A dump holds keys and hashes, so it prints names, counts, key ids and outcomes,
# never a row and never a message of pg_restore or psql. Reads through the PC's k3s kubeconfig unless KUBECONFIG is set;
# runs with the locked tools: mise exec -- tests/keycloak/restored_copy_keeps_its_keys_and_people.sh <dump>.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
dump="${1:?usage: $0 <dump>}"
[ -r "$dump" ] && [ ! -d "$dump" ] || fail "no readable dump file $dump"
namespace=keycloak
in_postgres() { kubectl --namespace "$namespace" exec postgres-0 --container postgres -- "$@"; }
dump_into_postgres() { kubectl --namespace "$namespace" exec --stdin postgres-0 --container postgres -- "$@" <"$dump"; }
outcome=0

job="$(kubectl --namespace "$namespace" get job config-cli -o json)" || fail "the Job config-cli cannot be read"
read -r complete failed backoff_limit < <(yq -p json \
  '([.status.conditions[]? | select(.type == "Complete") | .status] | .[0] // "False") + " " +
   ((.status.failed // 0) | tostring) + " " + (.spec.backoffLimit | tostring)' <<<"$job")
[ "$complete" = True ] || fail "config-cli's Job has not completed: $failed failed attempts of its backoffLimit $backoff_limit"
echo "config-cli's Job completed after $failed failed attempts, within its backoffLimit $backoff_limit"

# Keycloak marks the administrator it creates from KC_BOOTSTRAP_ADMIN_CLIENT_ID, and its service account, with this
# attribute; a restored database has an administrator, so Keycloak creates none.
temporary="$(in_postgres psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="SELECT
  (SELECT count(*) FROM client_attributes WHERE name = 'is_temporary_admin') +
  (SELECT count(*) FROM user_attribute WHERE name = 'is_temporary_admin')" 2>/dev/null)" ||
  fail "the database $namespace cannot be read"
if [ "$temporary" = 0 ]; then echo "no client and no user is a temporary administrator"
else echo "$temporary clients and users are temporary administrators: DIFFERS"; outcome=1; fi

# The key ids of the copy, through a loopback forward, against those the public issuer serves.
keycloak="$(kubectl --namespace "$namespace" get deployment keycloak -o json)" || fail "the Deployment keycloak cannot be read"
public_url="$(yq -p json '.spec.template.spec.containers[0].env[] | select(.name == "KC_HOSTNAME") | .value' <<<"$keycloak")"
realm="$(yq '.realm' "$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/keycloak/realm.yaml")"
forward_log="$(mktemp)"
timeout 5m kubectl --namespace "$namespace" port-forward --address 127.0.0.1 service/keycloak :http >"$forward_log" 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; rm -f -- "$forward_log"' EXIT
timeout 30 bash -c 'until grep -q "^Forwarding from 127.0.0.1:" "$0"; do sleep 1; done' "$forward_log" ||
  fail "the port-forward to Keycloak did not start"
local_url="http://127.0.0.1:$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -n 1)"
key_ids() {
  curl --silent --fail --max-time 20 "$1/realms/$realm/protocol/openid-connect/certs" | yq -p json '.keys[].kid' | sort
}
copy_kids="$(key_ids "$local_url")" || fail "the copy's key set of $realm cannot be read"
public_kids="$(key_ids "$public_url")" || fail "the key set of $public_url/realms/$realm cannot be read"
verdict=equal
[ -n "$copy_kids" ] && [ "$copy_kids" = "$public_kids" ] || { verdict=DIFFERS; outcome=1; }
echo "key ids of $realm: copy ${copy_kids//$'\n'/ }, $public_url ${public_kids//$'\n'/ }, $verdict"

# Each table's rows from the dump and from the database through the ConfigMap postgres's table-digests.sh, the
# loader's own digest, inside the container; stderr stays there too.
for table in user_entity credential user_group_membership; do
  dumped="$(dump_into_postgres sh -c 'set -o pipefail; pg_restore --data-only --table="$1" --file=- 2>/dev/null |
    sh /etc/postgres-checks/table-digests.sh' sh "$table")" || fail "the dump's $table cannot be read"
  loaded="$(in_postgres sh -c 'set -o pipefail; pg_dump --data-only --table="$1" 2>/dev/null |
    sh /etc/postgres-checks/table-digests.sh' sh "$table")" || fail "the database's $table cannot be read"
  verdict=equal
  [ "$dumped" = "$loaded" ] || { verdict=DIFFERS; outcome=1; }
  loaded_rows="${loaded##* }" dumped_rows="${dumped##* }"
  echo "$table: ${loaded_rows:-0} rows in the database, ${dumped_rows:-0} in the dump, $verdict"
done
[ "$outcome" = 0 ] || fail "the restored copy differs from the dump or from the public issuer"
echo "the restored copy kept its key ids, its people and their memberships through config-cli"
