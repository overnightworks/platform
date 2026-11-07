#!/usr/bin/env bash
# Render the tree as Flux applies it, with the locked flux2 and without network, and judge every image of every rendered
# Pod template: a vendor ref passes only as a repository of the vendor list at a sha256 digest, every app ref under
# ghcr.io/<owner>/ is red, since no release check exists here, and Flux's controllers pass in their namespace as the
# locked flux2 exports them. What the rule cannot judge is red too.
# Usage: mise exec -- scripts/verify_image_release.sh [tree], the tree defaulting to this checkout. The run names
# GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_REPOSITORY_OWNER, DEFAULT_BRANCH and RENDER_IMAGE, the image the render
# runs in.
# Exit: 0 nothing is red, 1 after at least one red record, 2 on any other failure.
set -Eeuo pipefail
trap 'echo "verify_image_release: line ${LINENO} failed: ${BASH_COMMAND}" >&2; exit 2' ERR

ROOT_SYNC_FILE="clusters/pc/flux-system/gotk-sync.yaml"
VENDOR_LIST="infrastructure/admission/image-vendors.yaml"
# The admission layer's binding reads the list by this name and namespace (paramRef).
VENDOR_LIST_NAME="image-vendors"
VENDOR_LIST_NAMESPACE="admission"
# The PC-only source, rendered empty since CI holds no key for it; the cluster job's overlay swaps the same source.
PC_ONLY_SOURCE="GitRepository/flux-system/platform-secrets"

# The reference grammar of distribution/reference; names and digests are matched against the lowercased string.
DOMAIN_COMPONENT='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
DOMAIN="(${DOMAIN_COMPONENT}(\\.${DOMAIN_COMPONENT})*|\\[[0-9a-f:]+\\])(:[0-9]+)?"
PATH_COMPONENT='[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*'
NAME_PATTERN="^(${DOMAIN}/)?${PATH_COMPONENT}(/${PATH_COMPONENT})*\$"
TAG_PATTERN='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
DIGEST_PATTERN='^[a-z][a-z0-9]*([-_+.][a-z][a-z0-9]*)*:[0-9a-f]{32,}$'
SHA256_DIGEST_PATTERN='^@sha256:[0-9a-f]{64}$'

# The yq programs. Each prints its records as NUL-terminated fields.
OBJECT='(.kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name)'
FIELD_PATH='("." + (path | map(tostring) | join(".")))'
KUSTOMIZATION='(.kind == "Kustomization" and ((.apiVersion // "") | test("^kustomize[.]toolkit[.]fluxcd[.]io/")))'
POD_SPEC_PATH='({"v1 Pod": ".spec", "v1 PodTemplate": ".template.spec", "v1 ReplicationController": ".spec.template.spec",
  "apps/v1 ReplicaSet": ".spec.template.spec", "apps/v1 Deployment": ".spec.template.spec",
  "apps/v1 StatefulSet": ".spec.template.spec", "apps/v1 DaemonSet": ".spec.template.spec",
  "batch/v1 Job": ".spec.template.spec", "batch/v1 CronJob": ".spec.jobTemplate.spec.template.spec"}
  [(.apiVersion // "") + " " + (.kind // "")])'
# Object, namespace, field path, image.
POD_IMAGES="${POD_SPEC_PATH} as \$at | select(\$at != null) | ${OBJECT} as \$object | (.metadata.namespace // \"\") as \$namespace
  | eval(\$at) | (
    ((\"containers\", \"initContainers\", \"ephemeralContainers\") as \$list | (.[\$list] // [])[]
      | [\$object, \$namespace, \$at + \".\" + \$list + \"[\" + (.name // \"\") + \"].image\", ((.image // \"\") | tostring)]),
    ((.volumes // [])[] | select(has(\"image\"))
      | [\$object, \$namespace, \$at + \".volumes[\" + (.name // \"\") + \"].image.reference\", ((.image.reference // \"\") | tostring)])
  ) | .[]"
# Object, apiVersion, field path, value, and key or candidate: an image key, or a string the grammar has to confirm as
# a host-qualified reference, in an object of a kind the rule does not know.
UNKNOWN_KIND_TRIGGERS="select(${POD_SPEC_PATH} == null)
  | select((.apiVersion == \"kustomize.toolkit.fluxcd.io/v1\" and .kind == \"Kustomization\") | not)
  | select((.apiVersion == \"apiextensions.k8s.io/v1\" and .kind == \"CustomResourceDefinition\") | not)
  | select((.apiVersion // \"\") | test(\"^helm[.]toolkit[.]fluxcd[.]io/\") | not)
  | ${OBJECT} as \$object | .apiVersion as \$api_version | (
    (.. | select(tag == \"!!map\" and has(\"image\"))
      | [\$object, \$api_version, ${FIELD_PATH} + \".image\", ((.image | select(kind == \"scalar\") | tostring) // \"\"), \"key\"]),
    (.. | select(tag == \"!!str\" and test(\"^(localhost|[^/ ]*[.:][^/ ]*)/[^ ]*[:@][^ /]*\$\"))
      | [\$object, \$api_version, ${FIELD_PATH}, ., \"candidate\"])
  ) | .[]"
# Object, apiVersion.
HELM_OBJECTS="select((.apiVersion // \"\") | test(\"^helm[.]toolkit[.]fluxcd[.]io/\")) | [${OBJECT}, .apiVersion] | .[]"
# Fact, object, value.
KUSTOMIZATION_FACTS="select(${KUSTOMIZATION}) | ${OBJECT} as \$object | (
    [\"identity\", \$object, ([.apiVersion, .spec] | sort_keys(..) | to_json(0))],
    (select(.spec.ignoreMissingComponents == true) | [\"ignoreMissingComponents\", \$object, \"true\"]),
    ((.spec.postBuild.substituteFrom // [])[]
      | [\"substituteFrom\", \$object, .kind + \"/\" + (\$object | split(\"/\") | .[1]) + \"/\" + .name])
  ) | .[]"
# Object, the fields that make the artifact differ from the checkout, url, ref.
SOURCES="select((.apiVersion // \"\") | test(\"^source[.]toolkit[.]fluxcd[.]io/\")) | [${OBJECT},
  ([(.spec // {}) | keys | .[] | select(. == \"include\" or . == \"ignore\" or . == \"recurseSubmodules\" or . == \"sparseCheckout\")] | join(\" \")),
  ((.spec.url // \"\") | tostring), ((.spec.ref // {}) | sort_keys(..) | to_json(0))] | .[]"
RENDERED_DEPLOYMENTS="select(.apiVersion == \"apps/v1\" and .kind == \"Deployment\") | ${OBJECT}"
# Name, namespace, path, source, apiVersion and spec of the root.
ROOT_FIELDS="select(${KUSTOMIZATION}) | [.metadata.name, .metadata.namespace, .spec.path,
  .spec.sourceRef.kind + \"/\" + (.spec.sourceRef.namespace // .metadata.namespace) + \"/\" + .spec.sourceRef.name,
  ([.apiVersion, .spec] | sort_keys(..) | to_json(0))] | .[]"
HEALTH_CHECKED_DEPLOYMENTS="select(${KUSTOMIZATION}) | .metadata.namespace as \$namespace | (.spec.healthChecks // [])[]
  | select(.apiVersion == \"apps/v1\" and .kind == \"Deployment\") | \"Deployment/\" + (.namespace // \$namespace) + \"/\" + .name"
# One reason for each thing that keeps the vendor list from being exactly one ConfigMap document of string entries.
VENDOR_LIST_SHAPE="
  (
    (select(document_index > 0) | [\"the file holds more than one document\"]),
    (select(document_index == 0 and kind != \"map\") | [\"the document is not a mapping\"]),
    (select(document_index == 0 and kind == \"map\") | (
      (select((keys | sort | join(\",\")) != \"apiVersion,data,kind,metadata\") | [\"its top-level keys are not exactly apiVersion, data, kind and metadata\"]),
      (select(.apiVersion != \"v1\") | [\"apiVersion is not v1\"]),
      (select(.kind != \"ConfigMap\") | [\"kind is not ConfigMap\"]),
      (select((.metadata | kind) != \"map\" or (.metadata | keys | sort | join(\",\")) != \"name,namespace\") | [\"metadata does not hold exactly name and namespace\"]),
      (select(.metadata.name != \"${VENDOR_LIST_NAME}\") | [\"metadata.name is not ${VENDOR_LIST_NAME}\"]),
      (select(.metadata.namespace != \"${VENDOR_LIST_NAMESPACE}\") | [\"metadata.namespace is not ${VENDOR_LIST_NAMESPACE}\"]),
      (select((.data | kind) != \"map\") | [\"data is not a mapping\"]),
      (.data | select(kind == \"map\") | (
        (keys | group_by(.) | .[] | select(length > 1) | [\"data repeats the key \" + .[0]]),
        (to_entries | .[] | select((.value | tag) != \"!!str\") | [\"data entry \" + .key + \" is not a string\"])))))
  ) | .[]"
VENDOR_LIST_ENTRIES="select(document_index == 0) | .data | select(kind == \"map\") | to_entries | .[] | [.key, (.value | tostring)] | .[]"

red_count=0
app_reference_count=0
vendor_reference_count=0
records=()
declare -A vendor_entry_by_repository=()
declare -A used_vendor_repositories=()
declare -A flux_own_images=()

fail() {
  echo "verify_image_release: $1" >&2
  exit 2
}

report_red() {
  red_count=$((red_count + 1))
  echo "red: $1: '${2//$'\n'/\\n}': $3"
}

# Sets records to the fields the yq program $1 prints for the file $2 (default: the render); returns yq's failure.
read_records() {
  yq --no-doc --nul-output --output-format yaml "$1" "${2:-${rendered}}" >"${work_directory}/records" || return
  mapfile -d '' records <"${work_directory}/records"
}

# Sets reference_name, reference_tag and reference_digest by splitting $1, then validates them. Returns 1 when $1 is
# no candidate (a whitespace-free string, no URL, with a registry host before its first slash) and 2 when a candidate
# breaks the reference grammar.
parse_host_qualified_reference() {
  local remainder="$1" last_component host has_digest=false has_tag=false
  reference_name="" reference_tag="" reference_digest=""
  if [[ ${remainder} == *@* ]]; then
    has_digest=true
    reference_digest="${remainder#*@}"
    remainder="${remainder%%@*}"
  fi
  last_component="${remainder##*/}"
  if [[ ${last_component} == *:* ]]; then
    has_tag=true
    reference_tag="${last_component##*:}"
    remainder="${remainder%:*}"
  fi
  reference_name="${remainder}"
  host="${reference_name%%/*}"
  [[ $1 != *[[:space:]]* && ! $1 =~ ^[A-Za-z][A-Za-z0-9+.-]*:// && ${reference_name} == */* &&
    (${host} == *.* || ${host} == *:* || ${host,,} == localhost) ]] || return 1
  [[ ${has_digest} == false || ${reference_digest,,} =~ ${DIGEST_PATTERN} ]] || return 2
  [[ ${has_tag} == false || ${reference_tag} =~ ${TAG_PATTERN} ]] || return 2
  [[ ${reference_name,,} =~ ${NAME_PATTERN} ]] || return 2
}

load_vendor_list() {
  local entry_key repository index
  if ! read_records "${VENDOR_LIST_SHAPE}" "${VENDOR_LIST}" 2>/dev/null; then
    report_red "${VENDOR_LIST}" "" "yq cannot read the vendor list"
    return
  fi
  for index in "${!records[@]}"; do
    report_red "${VENDOR_LIST}" "" "${records[index]}"
  done
  read_records "${VENDOR_LIST_ENTRIES}" "${VENDOR_LIST}"
  for ((index = 0; index < ${#records[@]}; index += 2)); do
    entry_key="${VENDOR_LIST} entry ${records[index]}" repository="${records[index + 1]}"
    if [[ ${repository,,} == "ghcr.io/${owner}/"* ]]; then
      report_red "${entry_key}" "${repository}" "a vendor entry under the app namespace ghcr.io/${owner}/"
    elif ! parse_host_qualified_reference "${repository}" || [ "${repository}" != "${repository,,}" ]; then
      report_red "${entry_key}" "${repository}" "a vendor entry that is no lowercase <registry>/<repository>"
    elif [ -n "${reference_tag}${reference_digest}" ]; then
      report_red "${entry_key}" "${repository}" "a vendor entry with a version"
    elif [ -n "${vendor_entry_by_repository[${repository}]+listed}" ]; then
      report_red "${entry_key}" "${repository}" "a vendor repository listed under two keys: ${vendor_entry_by_repository[${repository}]} and ${records[index]}"
    else
      vendor_entry_by_repository["${repository}"]="${records[index]}"
    fi
  done
}

# Sets the root_ values from the one root Kustomization of the sync file.
read_root() {
  read_records "${ROOT_FIELDS}" "${ROOT_SYNC_FILE}"
  [ "${#records[@]}" -eq 5 ] || fail "${ROOT_SYNC_FILE} holds not exactly one Kustomization"
  root_name="${records[0]}" root_namespace="${records[1]}" root_path="${records[2]}" root_source="${records[3]}"
  root_identity="${records[4]}" root_object="Kustomization/${records[1]}/${records[0]}"
}

# Renders the tree into the file rendered; a failed render is red with flux's message, and the run stops there.
render() {
  local flux_binary status=0 empty_source="${work_directory}/empty-source"
  flux_binary="$(readlink -f "$(command -v flux)")"
  mkdir "${empty_source}"
  docker image inspect "${RENDER_IMAGE}" >/dev/null 2>&1 || docker pull --quiet "${RENDER_IMAGE}" >/dev/null
  docker run --rm --pull never --network none --user "$(id -u):$(id -g)" --workdir /tree \
    --volume "${tree}:/tree:ro" --volume "${flux_binary}:/usr/local/bin/flux:ro" --volume "${empty_source}:/empty:ro" \
    "${RENDER_IMAGE}" flux build kustomization "${root_name}" --namespace "${root_namespace}" --path "${root_path}" \
    --kustomization-file "${ROOT_SYNC_FILE}" --dry-run --in-memory-build --recursive \
    --local-sources "${root_source}=.,${PC_ONLY_SOURCE}=/empty" >"${rendered}" 2>"${work_directory}/render-errors" ||
    status=$?
  case "${status}" in
    0) ;;
    1)
      report_red "${root_object}" "$(cat "${work_directory}/render-errors")" "the render failed"
      echo "images: ${red_count} red"
      exit 1
      ;;
    *) fail "the render container exited ${status}: $(cat "${work_directory}/render-errors")" ;;
  esac
}

# Red: a changed, missing or repeated self-reference, a repeated Kustomization identity, a skipped missing component, a
# ConfigMap substitution and a health-checked Deployment the render lacks. A Secret substitution is gap G2.
judge_kustomizations() {
  local index object value root_copies=0
  local -A identity_count=() rendered_deployments=()
  read_records "${KUSTOMIZATION_FACTS}"
  for ((index = 0; index < ${#records[@]}; index += 3)); do
    object="${records[index + 1]}" value="${records[index + 2]}"
    case "${records[index]}" in
      identity)
        identity_count["${object}"]=$((${identity_count[${object}]:-0} + 1))
        if [ "${object}" = "${root_object}" ]; then
          root_copies=$((root_copies + 1))
          [ "${value}" = "${root_identity}" ] ||
            report_red "${object}" "" "a changed self-reference: the rendered root differs from the root of ${ROOT_SYNC_FILE}"
        fi
        ;;
      ignoreMissingComponents)
        report_red "${object} .spec.ignoreMissingComponents" "${value}" "a skipped missing component may apply in CI and not on the PC"
        ;;
      substituteFrom)
        if [[ ${value} == Secret/* ]]; then
          echo "images: gap G2: ${object} substitutes from ${value}, which CI does not read: its variables render empty, at their defaults, or literal"
        else
          report_red "${object} .spec.postBuild.substituteFrom" "${value}" "a substitution from a ${value%%/*}, which the render does not read"
        fi
        ;;
    esac
  done
  [ "${root_copies}" -gt 0 ] || report_red "${root_object}" "" "a missing self-reference: the render holds no copy of the root"
  for object in "${!identity_count[@]}"; do
    [ "${identity_count[${object}]}" -eq 1 ] || report_red "${object}" "" "a repeated Kustomization identity"
  done
  read_records "${RENDERED_DEPLOYMENTS}"
  for object in "${records[@]}"; do
    rendered_deployments["${object}"]=rendered
  done
  read_records "${HEALTH_CHECKED_DEPLOYMENTS}" "${ROOT_SYNC_FILE}"
  for object in "${records[@]}"; do
    [ -n "${rendered_deployments[${object}]+rendered}" ] || report_red "${object}" "" "the render lacks a Deployment the root health-checks"
  done
}

# Red: a mapped source not rendered exactly once, a source field or ignore file that makes Flux's artifact differ from
# the checkout, a root source other than this repository's default branch, and a PC-only source other than the owner's
# repository of its name.
judge_sources() {
  local source index count field url ref ignore_file host="${GITHUB_SERVER_URL#*://}"
  local pc_only_url_pattern="^(https://|ssh://git@)${host//./\\.}/${owner}/${PC_ONLY_SOURCE##*/}(\\.git)?\$"
  read_records "${SOURCES}"
  for source in "${root_source}" "${PC_ONLY_SOURCE}"; do
    count=0
    for ((index = 0; index < ${#records[@]}; index += 4)); do
      [ "${records[index]}" = "${source}" ] || continue
      count=$((count + 1)) url="${records[index + 2]}" ref="${records[index + 3]}"
      for field in ${records[index + 1]}; do
        report_red "${source} .spec.${field}" "" "a source field that makes Flux's artifact differ from the checkout"
      done
      if [ "${source}" = "${root_source}" ]; then
        [ "${url}" = "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}" ] ||
          report_red "${source} .spec.url" "${url}" "the root's source is not ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
        [ "${ref}" = "{\"branch\":\"${DEFAULT_BRANCH}\"}" ] ||
          report_red "${source} .spec.ref" "${ref}" "the root's source is not the branch ${DEFAULT_BRANCH}"
      elif [[ ! ${url} =~ ${pc_only_url_pattern} ]]; then
        report_red "${source} .spec.url" "${url}" "the PC-only source is not the repository ${owner}/${PC_ONLY_SOURCE##*/}"
      fi
    done
    [ "${count}" -eq 1 ] || report_red "${source}" "" "a mapped source the render holds ${count} times"
  done
  find . -name .git -prune -o -name .sourceignore -print >"${work_directory}/ignore-files"
  while IFS= read -r ignore_file; do
    report_red "${ignore_file#./}" "" "a .sourceignore, which source-controller applies to the whole artifact and the render does not"
  done <"${work_directory}/ignore-files"
}

# Red: every Helm object, and every other kind the rule does not know that carries an image, once per object.
judge_unknown_kinds() {
  local index object value
  local -A judged_objects=()
  read_records "${HELM_OBJECTS}"
  for ((index = 0; index < ${#records[@]}; index += 2)); do
    report_red "${records[index]}" "${records[index + 1]}" "a Helm object, which the render does not render yet"
  done
  read_records "${UNKNOWN_KIND_TRIGGERS}"
  for ((index = 0; index < ${#records[@]}; index += 5)); do
    object="${records[index]}" value="${records[index + 3]}"
    [ -z "${judged_objects[${object}]+judged}" ] || continue
    if [ "${records[index + 4]}" = candidate ]; then
      parse_host_qualified_reference "${value}" && [ -n "${reference_tag}${reference_digest}" ] || continue
    fi
    judged_objects["${object}"]=judged
    report_red "${object} ${records[index + 2]}" "${value}" "a kind whose image the rule does not know (${records[index + 1]})"
  done
}

judge_image() {
  local location="$1 $3" namespace="$2" image="$4" named repository
  named="${image%@*}" repository="${image%@*}"
  [[ ${named##*/} != *:* ]] || repository="${named%:*}"
  if [ -z "${image}" ]; then
    report_red "${location}" "" "an empty or missing image"
  elif [ "${repository}" != "${repository,,}" ]; then
    report_red "${location}" "${image}" "a registry host or repository path that is not lowercase"
  elif [ -n "${flux_own_images["${namespace} ${image}"]+own}" ]; then
    echo "images: ${location} runs ${image}, the locked flux2's own"
  elif [[ ${image} == "ghcr.io/${owner}/"* ]]; then
    app_reference_count=$((app_reference_count + 1))
    if [[ ${repository} =~ ^ghcr\.io/${owner}/${PATH_COMPONENT}(/${PATH_COMPONENT})?$ && ${named} != "${repository}" &&
      ${named##*:} =~ ${TAG_PATTERN} && ${image#"${named}"} =~ ${SHA256_DIGEST_PATTERN} ]]; then
      report_red "${location}" "${image}" "an app ref, and no release check exists yet"
    else
      report_red "${location}" "${image}" "not one full app ref ghcr.io/${owner}/<repo>[/<name>]:<version>@sha256:<64 hex>"
    fi
  elif [ -z "${vendor_entry_by_repository[${repository}]+listed}" ]; then
    report_red "${location}" "${image}" "not a repository of the vendor list"
  else
    used_vendor_repositories["${repository}"]=used
    if [[ ${image#"${named}"} =~ ${SHA256_DIGEST_PATTERN} && (${named} == "${repository}" || ${named##*:} =~ ${TAG_PATTERN}) ]]; then
      vendor_reference_count=$((vendor_reference_count + 1))
    else
      report_red "${location}" "${image}" "a listed vendor repository not at <repository>[:<tag>]@sha256:<64 hex>"
    fi
  fi
}

main() {
  local variable index repository
  for variable in GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_REPOSITORY_OWNER DEFAULT_BRANCH RENDER_IMAGE; do
    [ -n "${!variable:-}" ] || fail "${variable} is not set"
  done
  tree="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
  cd "${tree}"
  owner="${GITHUB_REPOSITORY_OWNER,,}"
  work_directory="$(mktemp -d)"
  trap 'rm -rf "${work_directory}"' EXIT
  rendered="${work_directory}/rendered.yaml"
  flux install --export >"${work_directory}/flux-components.yaml"
  read_records "${POD_IMAGES}" "${work_directory}/flux-components.yaml"
  for ((index = 0; index < ${#records[@]}; index += 4)); do
    flux_own_images["${records[index + 1]} ${records[index + 3]}"]=own
  done
  load_vendor_list
  read_root
  render
  echo "images: ${root_object} renders $(yq eval-all '[.] | length' "${rendered}") objects"
  echo "images: gap G1: ${PC_ONLY_SOURCE} is not rendered: the PC-only source, for which CI holds no key"
  judge_kustomizations
  judge_sources
  judge_unknown_kinds
  read_records "${POD_IMAGES}"
  for ((index = 0; index < ${#records[@]}; index += 4)); do
    judge_image "${records[index]}" "${records[index + 1]}" "${records[index + 2]}" "${records[index + 3]}"
  done
  for repository in "${!vendor_entry_by_repository[@]}"; do
    [ -n "${used_vendor_repositories[${repository}]+used}" ] ||
      report_red "${VENDOR_LIST} entry ${vendor_entry_by_repository[${repository}]}" "${repository}" "a vendor entry no rendered image uses"
  done
  echo "images: ${vendor_reference_count} vendor references pass"
  if [ "${app_reference_count}" -eq 0 ]; then
    echo "images: no app image reference was found"
  else
    echo "images: ${app_reference_count} app image references, none passes before the release checks exist"
  fi
  [ "${red_count}" -eq 0 ] || { echo "images: ${red_count} red" && exit 1; }
}

main "$@"
