#!/usr/bin/env bash
# Drive scripts/check_secrets_expiry.sh against a fake kubectl and a fake clock first on PATH.
# Usage: tests/secrets/expiry_check_names_each_breach.sh
# Proves docs/operations.md OPS-1.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT
fake_bin="${work_directory}/bin"
mkdir "${fake_bin}"

# The fake kubectl prints FAKE_LISTING, or fails when FAKE_LISTING_FAIL is set, and refuses any query that could
# print a Secret's data.
cat >"${fake_bin}/kubectl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *json*|*yaml*|*".data"*) echo "fake kubectl: a query that reads data: $*" >&2; exit 1 ;;
  "get secrets --all-namespaces"*) ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 1 ;;
esac
[ -z "${FAKE_LISTING_FAIL:-}" ] || { echo "fake kubectl: connection refused" >&2; exit 1; }
printf '%s' "${FAKE_LISTING}"
FAKE
# The fake date answers the clock's own query with a fixed day, so a midnight cannot change a result.
cat >"${fake_bin}/date" <<'FAKE'
#!/usr/bin/env bash
[ "$*" != "+%F" ] || { echo 2026-06-15; exit 0; }
exec /usr/bin/date "$@"
FAKE
chmod +x "${fake_bin}/kubectl" "${fake_bin}/date"
# mise's locked kubectl and the PC's readable k3s must not answer instead of the fake.
export PATH="${fake_bin}:${PATH}" MISE_DISABLE_TOOLS=kubectl,flux,flux2 KUBECONFIG=/nonexistent
[ "$(command -v kubectl)" = "${fake_bin}/kubectl" ] || fail "the fake kubectl is not first on PATH"

check() { "${repository_root}/scripts/check_secrets_expiry.sh" 2>&1; }
expect_pass() {
  local case_name="$1" output
  output="$(FAKE_LISTING="$2" check)" || fail "the check failed ${case_name}: ${output}"
  echo "the check passes ${case_name}: ${output}"
}
expect_breach() {
  local case_name="$1" named="$3" output
  output="$(FAKE_LISTING="$2" check)" && fail "the check passed ${case_name}: ${output}"
  grep -q -- "${named}" <<<"${output}" || fail "the check did not name ${case_name}: ${output}"
  echo "the check fails on ${case_name}: $(grep -- "${named}" <<<"${output}")"
}

expect_pass "no annotated Secret" $'apps  plain  <none>\n'
expect_pass "a date 31 days out" $'apps  late  2026-07-16\n'
expect_breach "a date 30 days out" $'apps  soon  2026-07-15\n' "apps/soon expires on 2026-07-15"
expect_breach "a past date" $'apps  old  2026-06-14\n' "apps/old expired on 2026-06-14"
expect_breach "an unparseable date" $'apps  odd  2026-13-45\n' "apps/odd has an expiry that is no"
expect_breach "a date in another form" $'apps  odd  tomorrow\n' "apps/odd has an expiry that is no"
expect_breach "a breach beside a passing Secret" $'a  fine  2027-01-01\nb  soon  2026-07-01\n' "b/soon"
output="$(FAKE_LISTING_FAIL=1 check)" && fail "the check passed a failing listing: ${output}"
grep -q "listing the Secrets failed" <<<"${output}" || fail "the check did not name the failing listing: ${output}"
echo "the check fails on a failing listing: ${output}"
