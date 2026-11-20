#!/usr/bin/env bash
# Drive `scripts/pause_or_resume_attestation_check.sh` (the tasks admission:pause and admission:resume) against a fake
# kubectl and a fake gh, for the states the cluster cannot arrange: pause suspends the Kustomization app-attestations,
# scales Kyverno's admission controller to 0 and only then deletes the webhook configurations Kyverno manages, selected
# by its label and never by name, and ends the same when repeated or run again after a step failed; resume, while the
# Kustomization exists, takes the restore branch without any read of GitHub, also while GitHub fails; with the
# Kustomization gone it takes the removal branch only when the root has applied main's head, then deletes what Flux
# labelled as applied by app-attestations except a Namespace, the webhook configurations, and the TLS Secrets and Leases
# that carry Kyverno's owner label and Kyverno's four Leases by name; with another applied revision or an unreadable head it refuses, names which, and
# deletes nothing.
# Usage: mise exec -- tests/admission/pause_and_resume_stop_and_restore_the_attestation_check.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "$repository_root/tests/failure.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
fake_bin="$work_directory/bin"
state="$work_directory/state"
calls="$work_directory/calls"
mkdir "$fake_bin" "$state"

# The fake kubectl records each call and answers the reads the script makes from files of the state directory; the
# call that contains FAKE_FAILING_CALL fails. The webhook list holds one webhook that judges Pods the way the live
# policy asks.
cat >"$fake_bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CALLS"
if [ -n "${FAKE_FAILING_CALL:-}" ] && [[ "$*" == *"$FAKE_FAILING_CALL"* ]]; then
  exit 1
fi
case "$*" in
  *"get kustomization app-attestations"*"--output name"*) [ ! -e "$FAKE_STATE/layer" ] || echo kustomization.kustomize.toolkit.fluxcd.io/app-attestations ;;
  *"get kustomization app-attestations"*lastHandledReconcileAt*) cat "$FAKE_STATE/token" ;;
  *"get kustomization app-attestations"*) echo True ;;
  *"annotate kustomization app-attestations"*) sed 's/.*requestedAt=//; s/ .*//' <<<"$*" >"$FAKE_STATE/token" ;;
  *"get gitrepository flux-system"*"spec.url"*) echo https://github.com/overnightworks/platform ;;
  *"get gitrepository flux-system"*"spec.ref.branch"*) echo main ;;
  *"get kustomization flux-system"*) cat "$FAKE_STATE/applied" ;;
  *"get deployment"*"spec.replicas"*) echo 1 ;;
  *"get deployment"*"readyReplicas"*) echo 1 ;;
  *"get imagevalidatingpolicy"*) cat "$FAKE_STATE/policy.json" ;;
  *"get validatingwebhookconfiguration"*"-o json"* | *"get validatingwebhookconfiguration"*"--output json"*) cat "$FAKE_STATE/webhooks.json" ;;
  *"api-resources"*) printf '%s\n' namespaces events pods deployments.apps networkpolicies.networking.k8s.io customresourcedefinitions.apiextensions.k8s.io imagevalidatingpolicies.policies.kyverno.io ;;
esac
FAKE
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_CALLS"
[ ! -e "$FAKE_STATE/github-down" ] || exit 1
echo "$(cat "$FAKE_STATE/head")"
FAKE
chmod +x "$fake_bin/kubectl" "$fake_bin/gh"

printf '%s' '{"spec":{"matchConditions":[{"name":"app-ref","expression":"app-ref text"},{"name":"image-change","expression":"image-change text"}]}}' >"$state/policy.json"
# Kyverno's webhook configurations hold no webhooks, or a webhook without rules, while no policy matches.
cat >"$state/webhooks.json" <<'JSON'
{"items":[{},{"webhooks":[{"name":"without-rules"}]},{"webhooks":[{"failurePolicy":"Fail","rules":[{"resources":["pods"]},{"resources":["pods/ephemeralcontainers"]}],
"namespaceSelector":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["kube-system","flux-system","admission"]}]},
"matchConditions":[{"name":"a","expression":"(app-ref text)"},{"name":"b","expression":"x || image-change text"}]}]}]}
JSON
head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' "$head_sha" >"$state/head"

# run_task <verb>: runs the script and leaves its status in `status` and its lines in `output`.
run_task() {
  : >"$calls"
  status=0
  output="$(PATH="$fake_bin:$PATH" FAKE_CALLS="$calls" FAKE_STATE="$state" KUBECONFIG=/nonexistent ADMISSION_WAIT_SECONDS=2 \
    ADMISSION_POLL_SECONDS=1 "$repository_root/scripts/pause_or_resume_attestation_check.sh" "$@" 2>&1)" || status=$?
}
made_call() { grep -q -- "$1" "$calls"; }
call_line() { grep -n -- "$1" "$calls" | head -1 | cut -d: -f1; }
deletions() { grep -E '^(delete|gh )' "$calls" || true; }

# Pause: suspend, then scale to 0, then delete the webhook configurations by Kyverno's label.
touch "$state/layer"
run_task pause
[ "$status" -eq 0 ] || fail "pause ended $status: $output"
made_call "patch kustomization app-attestations" || fail "pause did not suspend app-attestations"
made_call '"suspend":true' || fail "pause did not set suspend to true"
made_call "scale deployment" || fail "pause did not scale the admission controller"
made_call "replicas 0" || made_call "replicas=0" || fail "pause did not scale to 0"
[ "$(call_line patch)" -lt "$(call_line scale)" ] || fail "pause scaled before it suspended"
# The root Kustomization takes over what the managers named kubectl* set and keeps flux-client-side-apply's fields.
field_manager=--field-manager=flux-client-side-apply
made_call "patch kustomization app-attestations $field_manager " || fail "pause did not patch as $field_manager: $(cat "$calls")"
[ "$(call_line scale)" -lt "$(call_line '^delete')" ] || fail "pause deleted the webhooks before it scaled to 0"
webhook_deletions="$(grep -c '^delete' "$calls")"
[ "$webhook_deletions" -eq 1 ] || fail "pause made $webhook_deletions deletions, not the one of the webhook configurations"
grep -q '^delete validatingwebhookconfiguration,mutatingwebhookconfiguration .*webhook.kyverno.io/managed-by=kyverno' "$calls" ||
  fail "pause did not select the webhook configurations by Kyverno's managed-by label: $(deletions)"
if grep -q '^delete .*webhookconfiguration[s]\? [a-z]' "$calls"; then fail "pause deleted a webhook configuration by name"; fi
first_calls="$(cat "$calls")"

# Repeated, it makes the same calls; run again after a step failed, it completes.
run_task pause
[ "$status" -eq 0 ] && [ "$(cat "$calls")" = "$first_calls" ] || fail "a repeated pause made other calls or ended $status: $output"
FAKE_FAILING_CALL="scale deployment" run_task pause
[ "$status" -ne 0 ] || fail "a pause whose scale failed ended 0"
made_call "patch kustomization" || fail "a pause whose scale failed did not suspend first"
if made_call '^delete'; then fail "a pause whose scale failed went on to delete the webhooks"; fi
run_task pause
[ "$status" -eq 0 ] && [ "$(cat "$calls")" = "$first_calls" ] || fail "a pause after an interrupted one ended in another state: $output"
echo "pause suspends, scales to 0 and deletes by label, in that order, and repeats to the same state"

# Resume with the Kustomization present: the restore branch, with no read of GitHub, also while GitHub is down.
touch "$state/github-down"
run_task resume
[ "$status" -eq 0 ] || fail "resume ended $status while GitHub was down: $output"
grep -q -e "patch kustomization app-attestations $field_manager .*\"suspend\":null" "$calls" ||
  fail "resume did not clear suspend as the manager that paused: $(cat "$calls")"
grep -q -e "annotate kustomization app-attestations reconcile.fluxcd.io/requestedAt=[0-9]* .*$field_manager" "$calls" ||
  fail "resume did not force a reconcile as $field_manager: $(cat "$calls")"
if made_call '^gh '; then fail "the restore branch read GitHub"; fi
if made_call '^delete'; then fail "the restore branch deleted something: $(deletions)"; fi
run_task resume
[ "$status" -eq 0 ] || fail "a repeated resume ended $status: $output"
rm "$state/github-down"
echo "resume restores without a read of GitHub and repeats"

# A webhook that lacks a match condition or an exclusion keeps resume waiting until it fails.
sed -i 's/image-change text/other text/' "$state/webhooks.json"
run_task resume
[ "$status" -ne 0 ] || fail "resume ended 0 although a webhook lacks the image-change condition"
[[ "$output" == *webhook* ]] || fail "resume did not name the webhooks that lack a condition: $output"
sed -i 's/other text/image-change text/' "$state/webhooks.json"
sed -i 's/"admission"//; s/,\]/]/' "$state/webhooks.json"
run_task resume
[ "$status" -ne 0 ] || fail "resume ended 0 although a webhook does not exclude admission"
echo "resume waits for the webhooks' exclusions and both match conditions"
sed -i 's/"flux-system"\]/"flux-system","admission"]/' "$state/webhooks.json"

# The removal branch: the Kustomization is gone and the root applied main's head.
rm "$state/layer"
printf 'main@sha1:%s\n' "$head_sha" >"$state/applied"
run_task resume
[ "$status" -eq 0 ] || fail "the removal ended $status: $output"
applied_selector='kustomize.toolkit.fluxcd.io/name=app-attestations,kustomize.toolkit.fluxcd.io/namespace=flux-system'
grep -q "^delete .*$applied_selector" "$calls" || fail "the removal did not select Flux's objects by its ownership labels: $(deletions)"
if grep -E '^delete ' "$calls" | grep -E '(^|[ ,])(namespaces|namespace|events)([ ,]|$)'; then fail "the removal deleted a Namespace or event"; fi
grep -q '^delete .*webhook.kyverno.io/managed-by=kyverno' "$calls" || fail "the removal did not delete the webhook configurations by label"
grep -q '^delete secret .*cert.kyverno.io/managed-by=kyverno' "$calls" || fail "the removal did not delete Kyverno's TLS Secrets by its owner label"
grep -q '^delete lease .*app.kubernetes.io/name=kyverno' "$calls" || fail "the removal did not delete Kyverno's Leases by its owner label"
lease_deletion="$(grep -n -e '^delete lease --namespace admission kyverno kyvernopre kyvernopre-lock kyverno-health --ignore-not-found$' "$calls" | head -1 | cut -d: -f1)"
[ -n "$lease_deletion" ] || fail "the removal did not delete Kyverno's four Leases by name: $(deletions)"
[ "$lease_deletion" -lt "$(call_line 'get pods,')" ] || fail "the removal deleted the Leases after it began to wait for the objects to be gone"
echo "the removal deletes by ownership labels, never a Namespace"

# Refusals delete nothing.
printf 'main@sha1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$state/applied"
run_task resume
[ "$status" -ne 0 ] || fail "the removal ended 0 with another revision applied"
[[ "$output" == *applied* ]] || fail "the refusal for another revision did not name it: $output"
if made_call '^delete'; then fail "a removal refused for another revision deleted something"; fi
printf 'main@sha1:%s\n' "$head_sha" >"$state/applied"
touch "$state/github-down"
run_task resume
[ "$status" -ne 0 ] || fail "the removal ended 0 with GitHub unreadable"
[[ "$output" == *GitHub* ]] || fail "the refusal for an unreadable head did not name GitHub: $output"
if made_call '^delete'; then fail "a removal with an unreadable head deleted something"; fi
echo "the removal refuses a stale applied revision and an unreadable head, naming which, and deletes nothing"

# A read that fails is no absence and no emptiness: nothing is deleted on an unreadable Kustomization, and a failed
# listing of what is left never ends the removal.
rm "$state/github-down"
touch "$state/layer"
FAKE_FAILING_CALL="get kustomization app-attestations --ignore-not-found" run_task resume
[ "$status" -ne 0 ] || fail "resume ended 0 although the Kustomization could not be read"
if made_call '^delete'; then fail "resume deleted something after the Kustomization could not be read: $(deletions)"; fi
FAKE_FAILING_CALL="get kustomization app-attestations --ignore-not-found" run_task pause
[ "$status" -ne 0 ] || fail "pause ended 0 although the Kustomization could not be read"
if made_call 'scale deployment'; then fail "pause scaled Kyverno after the Kustomization could not be read"; fi
rm "$state/layer"
FAKE_FAILING_CALL="get pods," run_task resume
[ "$status" -ne 0 ] || fail "the removal ended 0 although the listing of the applied objects failed"
FAKE_FAILING_CALL="get validatingwebhookconfiguration,mutatingwebhookconfiguration --selector" run_task resume
[ "$status" -ne 0 ] || fail "the removal ended 0 although the listing of the webhook configurations failed"
echo "an unreadable Kustomization deletes and scales nothing, and a failed listing never ends the removal"
