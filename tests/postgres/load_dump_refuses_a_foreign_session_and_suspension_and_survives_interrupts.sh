#!/usr/bin/env bash
# Proves, on the proof layer's Postgres loaded once from a synthetic dump, that db:load-dump waits for a foreign
# session once, names it once, loads nothing and resumes the layer; that it refuses a suspension it did not make and
# names --resume; and that pg_restore lists the toc-heavy dump and the loader recovers from an INT and a KILL at the
# restore of each dump. Needs PROOF_LAYER, PROBE_IMAGE and RUNNER_TEMP.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=loader_proof_setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/loader_proof_setup.sh"
# The loader and the interrupt test run as on the PC, against this cluster.
export KUBECONFIG="$HOME/.kube/config"
layer="$PROOF_LAYER"

prepare_loader_proof
loaded "$layer" "$dump" || fail "the load of the dump exited non-zero"
writers_ran

# A foreign session held through the whole run: the load waits for it once, names it once and resumes.
foreign_sessions() {
  sql "$layer" "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'foreign_session'"
}
kubectl --namespace "$layer" exec postgres-0 --container postgres -- env PGAPPNAME=foreign_session \
  psql --no-psqlrc --command='SELECT pg_sleep(600)' > /dev/null 2>&1 &
foreign=$!
for _ in $(seq 30); do [ "$(foreign_sessions)" = 1 ] && break; sleep 1; done
[ "$(foreign_sessions)" = 1 ] || fail "the foreign session did not start within 30 seconds"
if DB_LOAD_DUMP_ALONE_SECONDS=10 loaded "$layer" "$dump"; then fail "the load ran beside a foreign session"; fi
held_through="$(foreign_sessions)"
sql "$layer" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE application_name = 'foreign_session'" > /dev/null
wait "$foreign" || true
[ "$held_through" = 1 ] || fail "the foreign session ended before the load did"
[ "$(grep -c 'still holds another session' "$output")" = 1 ] && ! grep -qF 'in one transaction' "$output" ||
  fail "a foreign session did not cost exactly one wait and one line, or the load ran"
[ "$(kubectl --namespace flux-system get kustomization "$layer" -o jsonpath='{.spec.suspend}')" != true ] ||
  fail "the Kustomization $layer stayed suspended after a load that loaded nothing"
writers_ran
echo "a foreign session cost one wait and one line, nothing loaded and the Kustomization $layer resumed"

flux suspend kustomization "$layer"
if loaded "$layer" "$dump"; then fail "the load ran on a Kustomization suspended by another"; fi
grep -qF -- "--resume $layer" "$output" || fail "the refusal does not name --resume"
flux resume kustomization "$layer" --wait
echo "the load refused a suspension it did not make and named --resume"

# pg_restore cannot list the first half of the toc-heavy dump, so its table of contents is the larger half.
list_dump() { kubectl --namespace "$layer" exec --stdin postgres-0 --container postgres -- pg_restore --list > /dev/null; }
list_dump 2> /dev/null < <(head -c "$(($(stat -c %s "$toc_dump") / 2))" "$toc_dump") &&
  fail "pg_restore listed the first half of the toc-heavy dump"
list_dump < "$toc_dump" || fail "pg_restore cannot list the toc-heavy dump"

for interrupted_dump in "$dump" "$toc_dump"; do
  for signal in INT KILL; do
    tests/postgres/interrupt_load.sh "$layer" "$interrupted_dump" "$signal" > "$output" 2>&1 ||
      { cat "$output"; fail "interrupt_load.sh $signal failed on ${interrupted_dump##*/}"; }
    cat "$output"
    ! grep -q "$marker" "$output" || fail "interrupt_load.sh $signal printed a row"
  done
done
