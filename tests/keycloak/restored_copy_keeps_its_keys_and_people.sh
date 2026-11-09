#!/usr/bin/env bash
# restored_copy_keeps_its_keys_and_people.sh <dump> <evidence>: on the PC, after db:load-dump keycloak <dump> converged,
# shows that config-cli's Job completed within its retries, that Keycloak created no temporary administrator, that the
# copy's issuer and key ids equal those in the evidence file cutover:preflight wrote, that config-cli left the users, their
# attributes, credentials and group memberships as the dump holds them, and that every client of the realm keeps the
# secret the dump holds; the first apply on a dump older than an agent client adds only that client's service account and
# memberships. A dump holds keys and hashes, so it prints names, counts, key ids and outcomes, never a row, a secret, a
# digest and never a message of pg_restore or psql. Reads through the PC's k3s kubeconfig unless KUBECONFIG is set; runs
# with the locked tools: mise exec -- tests/keycloak/restored_copy_keeps_its_keys_and_people.sh <dump> <evidence>.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
dump="${1:?usage: $0 <dump> <evidence>}" evidence="${2:?usage: $0 <dump> <evidence>}"
[ -r "$dump" ] && [ ! -d "$dump" ] || fail "no readable dump file $dump"
evidence_issuer="$(sed -n 's/^issuer //p' "$evidence")" evidence_kids="$(sed -n 's/^kid //p' "$evidence" | sort)" ||
  fail "no readable evidence file $evidence"
[ -n "$evidence_issuer" ] && [ -n "$evidence_kids" ] || fail "the evidence file $evidence holds no issuer or no key id"
namespace=keycloak
# A connection attempt ends past 10 s, a statement past 60 s and a lock wait past 10 s, as a lock the operator's session
# holds could otherwise hold this check forever. pg_dump resets both for its session, so the container's own timeout,
# below the local deadline, ends pg_dump and pg_restore: the pipe into table-digests.sh closes and no process of the
# database's session outlives the check. The local deadline ends the kubectl exec around each, which a stalled
# connection could otherwise keep open.
deadline=2m
remote_deadline=100s
remote_deadline_status=97
# The container's busybox timeout returns 124 or 143 when it ended its command; bounded returns 97 for both.
remote_bound='bounded() { limit=$1; shift; timeout "$limit" "$@"; status=$?; case $status in 124|143) return 97;; esac; return "$status"; }'
in_postgres() {
  timeout "$deadline" kubectl --namespace "$namespace" exec postgres-0 --container postgres -- \
    env PGCONNECT_TIMEOUT=10 PGOPTIONS='-c statement_timeout=60s -c lock_timeout=10s' "$@"
}
dump_into_postgres() {
  timeout "$deadline" kubectl --namespace "$namespace" exec --stdin postgres-0 --container postgres -- "$@" <"$dump"
}
# step_failed <status> <step>: fails naming the step, and the deadline when it ended the step.
step_failed() {
  [ "$1" != 124 ] || fail "$2 did not end within $deadline, the local deadline"
  [ "$1" != "$remote_deadline_status" ] || fail "$2 did not end within $remote_deadline in the container"
  fail "$2 failed"
}
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
  step_failed "$?" "counting the temporary administrators in the database $namespace"
if [ "$temporary" = 0 ]; then echo "no client and no user is a temporary administrator"
else echo "$temporary clients and users are temporary administrators: DIFFERS"; outcome=1; fi

# The issuer and key ids of the copy, through a loopback forward, against the evidence file's.
realm_file="$(dirname "${BASH_SOURCE[0]}")/../../infrastructure/keycloak/realm.yaml"
realm="$(yq '.realm' "$realm_file")"
forward_log="$(mktemp)"
timeout 5m kubectl --namespace "$namespace" port-forward --address 127.0.0.1 service/keycloak :http >"$forward_log" 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; rm -f -- "$forward_log"' EXIT
timeout 30 bash -c 'until grep -q "^Forwarding from 127.0.0.1:" "$0"; do sleep 1; done' "$forward_log" ||
  fail "the port-forward to Keycloak did not start"
local_url="http://127.0.0.1:$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$forward_log" | head -n 1)"
copy_issuer="$(curl --silent --fail --max-time 20 "$local_url/realms/$realm/.well-known/openid-configuration" |
  yq -p json '.issuer')" || fail "the copy's discovery of $realm cannot be read"
copy_kids="$(curl --silent --fail --max-time 20 "$local_url/realms/$realm/protocol/openid-connect/certs" |
  yq -p json '.keys[].kid' | sort)" || fail "the copy's key set of $realm cannot be read"
verdict=equal
[ "$copy_issuer" = "$evidence_issuer" ] || { verdict=DIFFERS; outcome=1; }
echo "issuer of $realm: copy $copy_issuer, evidence $evidence_issuer, $verdict"
verdict=equal
[ -n "$copy_kids" ] && [ "$copy_kids" = "$evidence_kids" ] || { verdict=DIFFERS; outcome=1; }
echo "key ids of $realm: copy ${copy_kids//$'\n'/ }, evidence ${evidence_kids//$'\n'/ }, $verdict"

# The awk program below, passed as an argument so no quoting of a container script reaches it. It reads a COPY stream:
# with print_column it prints that column of every row, else it prints the stream without the rows whose column value
# is in added.
rows_by_column='BEGIN { count = split(added, ids, " "); for (i = 1; i <= count; i++) skip[ids[i]] = 1 }
  /^COPY / { field = 0; seen = 1; header = $0; sub(/^[^(]*[(]/, "", header); sub(/[)].*/, "", header)
    table = $2; sub(/^[^.]*[.]/, "", table)
    columns = split(header, names, /, */); for (i = 1; i <= columns; i++) if (names[i] == column) field = i
    if (column != "" && !field) { print "the COPY of " table " has no column " column > "/dev/stderr"; missing = 1 }
    copying = 1; if (!print_column) print; next }
  copying && /^\\[.]$/ { copying = 0; if (!print_column) print; next }
  copying && field { split($0, cells, "\t"); if (print_column) { print cells[field]; next } if (cells[field] in skip) next }
  { if (!print_column) print }
  END { if (!seen) { print "the stream holds no COPY of the table" > "/dev/stderr"; missing = 1 }; if (missing) exit 1 }'
# The service accounts a realm-file client gained since the dump: user ids that stay in this script; a person or any
# other added row shows up as a difference in the digests below, which skip only these users' rows.
declared_clients="$(yq "[.clients[].clientId] | map(\"'\" + . + \"'\") | join(\",\")" "$realm_file")"
live_service_accounts="$(in_postgres psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="SELECT u.id
  FROM user_entity u JOIN client c ON c.id = u.service_account_client_link JOIN realm r ON r.id = c.realm_id
  WHERE r.name = '$realm' AND c.client_id IN ($declared_clients)" 2>/dev/null | LC_ALL=C sort)" ||
  step_failed "$?" "reading the service accounts of the declared clients"
dumped_user_ids="$(dump_into_postgres sh -c "$remote_bound"'; set -o pipefail
  bounded "$2" pg_restore --data-only --table=user_entity --file=- 2>/dev/null |
    awk -v column=id -v print_column=1 "$1" | LC_ALL=C sort' sh "$rows_by_column" "$remote_deadline")" ||
  step_failed "$?" "reading the dump's user ids"
added_service_accounts="$(comm -13 <(printf '%s\n' "$dumped_user_ids") <(printf '%s\n' "$live_service_accounts") | tr '\n' ' ')"
added_service_accounts="${added_service_accounts%% }"
# Each table's rows from the dump and from the database through the ConfigMap postgres's table-digests.sh, the
# loader's own digest, inside the container; stderr stays there too. The database's rows of an added service account
# are dropped before the digest, by the column that names the user, so every other row still has to match.
for table_and_column in user_entity:id credential: user_group_membership:user_id user_attribute:user_id; do
  table="${table_and_column%%:*}" column="${table_and_column#*:}"
  dumped="$(dump_into_postgres sh -c "$remote_bound"'; set -o pipefail
    bounded "$2" pg_restore --data-only --table="$1" --file=- 2>/dev/null | sh /etc/postgres-checks/table-digests.sh' \
    sh "$table" "$remote_deadline")" || step_failed "$?" "reading the dump's $table"
  loaded="$(in_postgres sh -c "$remote_bound"'; set -o pipefail
    bounded "$2" pg_dump --data-only --lock-wait-timeout=10s --table="$1" 2>/dev/null |
      awk -v column="$3" -v added="$4" "$5" | sh /etc/postgres-checks/table-digests.sh' \
    sh "$table" "$remote_deadline" "$column" "$added_service_accounts" "$rows_by_column")" ||
    step_failed "$?" "reading the database's $table"
  [ -n "$dumped" ] && [ -n "$loaded" ] || fail "$table: the digest of the dump or of the database is empty, though it holds a line for every table"
  verdict=equal
  [ "$dumped" = "$loaded" ] || { verdict=DIFFERS; outcome=1; }
  loaded_rows="${loaded##* }" dumped_rows="${dumped##* }"
  echo "$table: ${loaded_rows:-0} rows in the database beyond added service accounts, ${dumped_rows:-0} in the dump, $verdict"
done
added_count=0
[ -z "$added_service_accounts" ] || added_count="$(wc -w <<<"$added_service_accounts")"
echo "$added_count service accounts of declared clients were added since the dump, with their memberships"
# Each client of the realm that holds a secret, as "<client><tab><sha256 of its COPY-escaped secret>", from the dump and from
# the database through the same awk program, as the four tables are. The digests are made in the container, so no secret
# reaches this shell, and the escaped text has no newline or tab that could split a line: only a client's name is printed.
client_secrets='copying && /^\\[.]$/ { copying = 0; next }
  copying {
    split($0, cell, "\t")
    if (table == "realm") { if (cell[column["name"]] == realm) realm_id = cell[column["id"]] }
    else { clients++; client_realm[clients] = cell[column["realm_id"]]; client_name[clients] = cell[column["client_id"]]; client_secret[clients] = cell[column["secret"]] }
    next
  }
  /^COPY / {
    table = $2; sub(/^[^.]*[.]/, "", table)
    header = $0; sub(/^[^(]*[(]/, "", header); sub(/[)].*/, "", header)
    split("", column); columns = split(header, names, /, */)
    for (i = 1; i <= columns; i++) column[names[i]] = i
    required["realm"] = "id name"; required["client"] = "client_id realm_id secret"
    needed = split(required[table], needs, " ")
    for (i = 1; i <= needed; i++) if (!(needs[i] in column)) { print "the COPY of " table " has no column " needs[i] > "/dev/stderr"; missing = 1 }
    copying = 1
  }
  END { if (missing) exit 1; for (i = 1; i <= clients; i++) if (realm_id != "" && client_realm[i] == realm_id && client_secret[i] != "\\N") print client_name[i] "\t" client_secret[i] }'
digest_each='while IFS="$(printf "\t")" read -r client secret; do
      printf "%s\t%s\n" "$client" "$(printf %s "$secret" | sha256sum | cut -d" " -f1)"
    done'
dumped_digests="$(dump_into_postgres sh -c "$remote_bound"'; set -o pipefail
  bounded "$2" pg_restore --data-only --table=realm --table=client --file=- 2>/dev/null | awk -v realm="$3" "$1" |
    '"$digest_each" sh "$client_secrets" "$remote_deadline" "$realm")" || step_failed "$?" "reading the dump's client secrets"
copy_digests="$(in_postgres sh -c "$remote_bound"'; set -o pipefail
  bounded "$2" pg_dump --data-only --lock-wait-timeout=10s --table=realm --table=client 2>/dev/null | awk -v realm="$3" "$1" |
    '"$digest_each" sh "$client_secrets" "$remote_deadline" "$realm")" || step_failed "$?" "reading the database's client secrets"
declare -A copy_digest_of=()
while IFS=$'\t' read -r client digest; do [ -z "$client" ] || copy_digest_of[$client]="$digest"; done <<<"$copy_digests"
[ -n "$dumped_digests" ] || { echo "the dump holds no client secret of $realm: DIFFERS"; outcome=1; }
while IFS=$'\t' read -r client digest; do
  [ -n "$client" ] || continue
  if [ "${copy_digest_of[$client]-}" = "$digest" ]; then echo "$client: client secret equal"
  else echo "$client: client secret DIFFERS"; outcome=1; fi
  unset "copy_digest_of[$client]"
done <<<"$dumped_digests"
for client in "${!copy_digest_of[@]}"; do echo "$client: client secret not in the dump, not compared"; done
[ "$outcome" = 0 ] || fail "the restored copy differs from the dump or from the evidence"
echo "the restored copy kept its issuer, key ids, people, memberships and client secrets through config-cli"
