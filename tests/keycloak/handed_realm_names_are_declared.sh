#!/usr/bin/env bash
# handed_realm_names_are_declared.sh <realm file>: holds every name that a manifest under apps/ hands to an app under a
# REALM_ key to docs/app.md's scheme. The layers are the Kustomizations of clusters/pc/apps.yaml whose path lies under
# ./apps, each rendered by tests/flux/render_layer.sh as Flux renders it. Every container of every Pod template, in both
# lists, must take no envFrom and hand each REALM_ key as a plain, non-empty value that the realm file declares as an
# object of the key's kind and that is its layer's own app's, or one of the fleet's two. A Kustomization that patches,
# substitutes, rewrites images, adds components or sets a namespace or name prefix is refused, since its render would
# differ from what Flux applies. The judgement, judge_layers, takes the repository root, which holds the layers and
# clusters/pc/apps.yaml, so the mutants below can judge a throwaway root. It then judges changed inputs and fails unless
# each is named. Exits 1 on the first breach, naming layer, container, key and value, which are public.
set -euo pipefail
# shellcheck source=../failure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../failure.sh"
# shellcheck source=realm_groups.sh
source "$(dirname "${BASH_SOURCE[0]}")/realm_groups.sh"
# shellcheck source=../flux/render_layer.sh
source "$(dirname "${BASH_SOURCE[0]}")/../flux/render_layer.sh"

[ $# -eq 1 ] && [ -f "$1" ] || fail "usage: $0 <realm file>"
realm_file="$1"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# realm_facts <realm file>: the group paths, client scope names and client ids the file declares, as one JSON object.
realm_facts() {
  jq --null-input --compact-output \
    --argjson group "$(realm_group_paths "$1" | jq --raw-input . | jq --slurp --compact-output .)" \
    --argjson scope "$(yq --output-format json --indent 0 '[.clientScopes[].name]' "$1")" \
    --argjson client "$(yq --output-format json --indent 0 '[.clients[].clientId]' "$1")" \
    '{group: $group, scope: $scope, client: $client}'
}

# The seven keys, the kind of realm object each names and the value it takes for app $app.
# shellcheck disable=SC2016 # jq's variables
judgement='
  def kind: {REALM_CLIENT_ID: "client", REALM_LOGIN_GROUP: "group", REALM_ADMIN_GROUP: "group", REALM_MCP_GROUP: "group",
             REALM_MCP_SCOPE: "scope", REALM_AGENT_GROUP: "group", REALM_MCP_CLIENT_ID: "client"};
  def own: {REALM_CLIENT_ID: $app, REALM_LOGIN_GROUP: "/apps/\($app)", REALM_ADMIN_GROUP: "/apps/\($app)/admin",
            REALM_MCP_GROUP: "/apps/\($app)/mcp", REALM_MCP_SCOPE: "mcp-\($app)", REALM_AGENT_GROUP: "/agents",
            REALM_MCP_CLIENT_ID: "agents"};
  def entry_problems($container):
    .name as $key | .value as $value
    | "problem: \($layer): container \($container.name): \($key)=\($value // "")" as $where
    | if kind | has($key) | not then "\($where) is no key of the set"
      elif has("valueFrom") then "\($where) comes from valueFrom, not a plain value"
      elif ($value | type) != "string" or $value == "" then "\($where) has no value"
      else
        (if $facts[kind[$key]] | any(. == $value) | not then "\($where) is declared in the realm file by no \(kind[$key])" else empty end),
        (if own[$key] != $value then "\($where) is not the app'"'"'s own" else empty end)
      end;
  [.[] | .. | objects | (.containers?, .initContainers?) | arrays | .[]] as $containers
  | ($containers[] | . as $container
     | (if has("envFrom") then "problem: \($layer): container \($container.name) takes envFrom, whose keys the check cannot see" else empty end),
       (($container.env // [])[] | select(.name | startswith("REALM_")) | entry_problems($container))),
    "\($layer): \($containers | length) containers hand \([$containers[] | (.env // [])[] | select(.name | startswith("REALM_"))] | length) REALM_ values"
'

# judge_render <app> <layer> <rendered YAML file> <facts>: the problem lines of one layer's render, and a line counting what it judged.
judge_render() {
  yq --output-format json --indent 0 '.' "$3" |
    jq --slurp --raw-output --arg app "$1" --arg layer "$2" --argjson facts "$4" "$judgement"
}

# judge_layers <repository root> <realm file>: the problem lines of every layer of <root>/clusters/pc/apps.yaml under ./apps.
judge_layers() {
  local root="$1" facts layer path forbidden directory nested status rendered="$work/layer.yaml"
  facts="$(realm_facts "$2")"
  while read -r layer path forbidden; do
    [ -z "$forbidden" ] || echo "problem: $layer carries $forbidden, which makes Flux's render differ from the layer's directory"
    directory="$root/${path#./}"
    status=0
    nested="$(render_layer "$directory" "$rendered")" || status=$?
    case "$status" in
      0) ;;
      2)
        echo "problem: $layer has no kustomization, and Flux renders its subdirectory $nested as a resource of its own"
        continue ;;
      *) fail "$layer ($path) does not render" ;;
    esac
    judge_render "$(cut -d/ -f3 <<<"$path")" "$layer" "$rendered" "$facts"
  done < <(yq --no-doc 'select(.kind == "Kustomization") | select(.spec.path | test("^[.]/apps/"))
    | .metadata.name + " " + .spec.path + " " + ([.spec | keys | .[] | select(. == "patches" or . == "postBuild" or . == "images"
      or . == "components" or . == "targetNamespace" or . == "namePrefix")] | join(","))' "$root/clusters/pc/apps.yaml")
}

problems="$(judge_layers "$repository_root" "$realm_file")"
echo "$problems"
[ -z "$(grep '^problem: ' <<<"$problems" || true)" ] || fail "a handed realm name breaks docs/app.md's scheme"

facts="$(realm_facts "$realm_file")"
hopin="$work/hopin.yaml"
skat="$work/skat.yaml"
kubectl kustomize "$repository_root/apps/hopin" >"$hopin"
kubectl kustomize "$repository_root/apps/skat" >"$skat"
on_hopin='select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "hopin")'
env_of() { echo "$on_hopin | .env[] | select(.name == \"$1\")"; }

# mutant <expected text> <yq expression> [<app> <render>]: a copy of the render changed by the expression must make the
# judgement name the text.
mutant() {
  local app="${3:-hopin}" render="${4:-$hopin}"
  yq "$2" "$render" >"$work/mutant.yaml"
  expect_problem "$1" "$2" judge_render "$app" "./apps/$app" "$work/mutant.yaml" "$facts"
}
by_no() { echo "$1=$2 is declared in the realm file by no $3"; }
value_of() { echo "($(env_of "$1") | .value) = \"$2\""; }

mutant "$(by_no REALM_MCP_SCOPE mcp-nothing scope)" "$(value_of REALM_MCP_SCOPE mcp-nothing)"
mutant "$(by_no REALM_MCP_SCOPE /apps/hopin/mcp scope)" "$(value_of REALM_MCP_SCOPE /apps/hopin/mcp)"
mutant "$(by_no REALM_MCP_GROUP mcp-hopin group)" "$(value_of REALM_MCP_GROUP mcp-hopin)"
mutant "$(by_no REALM_CLIENT_ID nothing client)" "$(value_of REALM_CLIENT_ID nothing)"
mutant "$(by_no REALM_MCP_CLIENT_ID nothing client)" "$(value_of REALM_MCP_CLIENT_ID nothing)"
for group in /hopin/mcp mcp /apps/hopin/mc /apps/hopin/mcp/x; do
  mutant "$(by_no REALM_MCP_GROUP "$group" group)" "$(value_of REALM_MCP_GROUP "$group")"
done
mutant "REALM_AGENT_GRUP=/agents is no key of the set" "($(env_of REALM_AGENT_GROUP) | .name) = \"REALM_AGENT_GRUP\""
mutant "REALM_MCP_SCOPE= comes from valueFrom" \
  "($(env_of REALM_MCP_SCOPE)) = {\"name\": \"REALM_MCP_SCOPE\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"hopin\", \"key\": \"scope\"}}}"
mutant "REALM_MCP_SCOPE= has no value" "$(value_of REALM_MCP_SCOPE "")"
mutant "container hopin takes envFrom" "($on_hopin | .envFrom) = [{\"configMapRef\": {\"name\": \"hopin\"}}]"
mutant "container setup: REALM_MCP_SCOPE=mcp-nothing" \
  "(select(.kind == \"Deployment\") | .spec.template.spec.initContainers) = [{\"name\": \"setup\", \"image\": \"x\", \"env\": [{\"name\": \"REALM_MCP_SCOPE\", \"value\": \"mcp-nothing\"}]}]"
mutant "REALM_MCP_SCOPE=mcp-hopin is not the app's own" \
  "(select(.kind == \"Deployment\") | .spec.template.spec.containers[] | select(.name == \"skat\") | .env[] | select(.name == \"REALM_MCP_SCOPE\") | .value) = \"mcp-hopin\"" \
  skat "$skat"

yq 'del(.groups[] | select(.name == "apps") | .subGroups[] | select(.name == "hopin") | .subGroups[] | select(.name == "mcp"))' \
  "$realm_file" >"$work/realm.yaml"
expect_problem "$(by_no REALM_MCP_GROUP /apps/hopin/mcp group)" "the realm file without /apps/hopin/mcp" \
  judge_render hopin ./apps/hopin "$hopin" "$(realm_facts "$work/realm.yaml")"

# A throwaway root with a layer that has no kustomization.yaml, which Flux renders from its files.
throwaway="$work/root"
mkdir -p "$throwaway/clusters/pc" "$throwaway/apps/throwaway"
cat >"$throwaway/clusters/pc/apps.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: throwaway
spec:
  path: ./apps/throwaway
YAML
cat >"$throwaway/apps/throwaway/cronjob.yaml" <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: job
spec:
  schedule: '* * * * *'
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: job
              image: x
              env:
                - name: REALM_NOPE
                  value: nothing
YAML
cat >"$throwaway/apps/throwaway/pod.yml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: pod
spec:
  containers:
    - name: pod
      image: x
      env:
        - name: REALM_CLIENT_ID
          value: nothing
YAML
expect_problem "container job: REALM_NOPE=nothing is no key of the set" "a CronJob of a layer without a kustomization.yaml" \
  judge_layers "$throwaway" "$realm_file"
expect_problem "container pod: REALM_CLIENT_ID=nothing is declared in the realm file by no client" "a bare Pod of a layer without a kustomization.yaml" \
  judge_layers "$throwaway" "$realm_file"

mkdir -p "$throwaway/apps/throwaway/nested"
touch "$throwaway/apps/throwaway/nested/kustomization.yaml"
expect_problem "Flux renders its subdirectory $throwaway/apps/throwaway/nested as a resource of its own" "a subdirectory with a kustomization.yaml" \
  judge_layers "$throwaway" "$realm_file"
rm -r "$throwaway/apps/throwaway/nested" "$throwaway/apps/throwaway/cronjob.yaml" "$throwaway/apps/throwaway/pod.yml"

# A Kustomization of apps/ that changes what Flux applies.
for field in patches postBuild images components targetNamespace namePrefix; do
  FIELD="$field" yq --inplace '.spec[strenv(FIELD)] = "x"' "$throwaway/clusters/pc/apps.yaml"
  expect_problem "throwaway carries $field" "a Kustomization of apps/ with $field" judge_layers "$throwaway" "$realm_file"
  FIELD="$field" yq --inplace 'del(.spec[strenv(FIELD)])' "$throwaway/clusters/pc/apps.yaml"
done
echo "every handed realm name is declared, is its app's own or the fleet's, and every mutant is red"
