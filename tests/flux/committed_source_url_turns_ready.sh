#!/usr/bin/env bash
set -euo pipefail
# The job's root reads the repository the job serves, so the url and branch the PC's root commits are fetched here by
# a throwaway GitRepository under the candidate's source-controller, and deleted on every exit.
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
source_name="committed-source"
remove_source() {
  local cell_status=$?
  delete_object -n flux-system delete gitrepository "$source_name" --ignore-not-found
  end_deletions "$cell_status"
}
trap remove_source EXIT

committed="$(kubectl create --dry-run=client -f clusters/pc/flux-system/gotk-sync.yaml -o go-template='{{if eq .kind "GitRepository"}}{{.spec.url}} {{.spec.ref.branch}}{{end}}')"
read -r url branch <<<"$committed"
[ -n "$url" ] && [ -n "$branch" ] || fail "the committed root names no GitRepository url and branch"
source_manifest="$(cat <<'YAML'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: @NAME@
  namespace: flux-system
spec:
  interval: 1m0s
  url: @URL@
  ref:
    branch: @BRANCH@
YAML
)"
source_manifest="${source_manifest//@NAME@/${source_name}}"
source_manifest="${source_manifest//@URL@/${url}}"
source_manifest="${source_manifest//@BRANCH@/${branch}}"
printf '%s\n' "$source_manifest" | kubectl apply --server-side -f -
kubectl -n flux-system wait "gitrepository/$source_name" --for=condition=Ready --timeout=3m ||
  { kubectl -n flux-system get "gitrepository/$source_name" -o yaml; fail "a GitRepository at the committed $url on $branch does not turn Ready"; }
echo "a GitRepository at the committed $url on $branch is Ready under the candidate's source-controller"
