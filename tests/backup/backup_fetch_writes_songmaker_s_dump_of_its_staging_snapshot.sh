#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=staging_cell.sh
source "$(dirname "${BASH_SOURCE[0]}")/staging_cell.sh"
# `mise run backup:fetch songmaker <file>` after a Backup: the task exits 0 although songmaker's restore-test CronJob has
# init containers beyond the dump's, the file's sha256 is the dump line of the staging snapshot's MANIFEST, and no output
# prints a row of the dump; prints names, counts and verdicts, never a row or a secret.
export KUBECONFIG="$HOME/.kube/config"
namespace="$SONGMAKER_NAMESPACE"
staging=/data/backup-staging
marker="fetch-marker-$(openssl rand -hex 4)"
scratch="$(mktemp -d)"
sql() { kubectl --namespace "$namespace" exec postgres-0 --container postgres -- psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="$1"; }
cleanup() {
  local cell_status=$?
  sql 'DROP TABLE IF EXISTS fetch_marker' >/dev/null || deletion_failures=$((deletion_failures + 1))
  delete_backups
  delete_restic_objects
  rm -rf "$scratch"
  end_deletions "$cell_status"
}
trap cleanup EXIT

sql "CREATE TABLE fetch_marker (value text); INSERT INTO fetch_marker VALUES ('$marker')" >/dev/null
run_backup fetch-first
run_restic "$namespace" fetch-manifest "
  tab=\"\$(printf '\\t')\"
  restic --no-cache dump --path '$staging' latest '$staging/MANIFEST' | grep \"^dump\$tab\" | cut -f2"
[ "$restic_exit" = 0 ] || fail "the MANIFEST of the staging snapshot of $namespace cannot be read (exit $restic_exit)"
manifest_dump="$restic_output"
[ "${#manifest_dump}" = 64 ] || fail "the MANIFEST of $namespace's staging snapshot names no dump sha256"

fetched="$scratch/dump"
fetch_exit=0
fetch_output="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && mise run backup:fetch "$namespace" "$fetched" 2>&1)" || fetch_exit=$?
[ "$fetch_exit" = 0 ] || fail "backup:fetch $namespace ended $fetch_exit: $fetch_output"
[ "$(sha256sum <"$fetched" | cut -c1-64)" = "$manifest_dump" ] ||
  fail "the dump backup:fetch wrote differs from the sha256 of the staging snapshot's MANIFEST"
[[ $fetch_output != *"$marker"* ]] || fail "the output of backup:fetch holds a row of the dump"
echo "backup:fetch $namespace wrote the dump of the staging snapshot, equal to its MANIFEST's sha256, and printed no row"
