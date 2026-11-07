#!/usr/bin/env bash
# Render the tree as Flux applies it, with the locked flux2 and without network, and judge every image of every rendered
# Pod template, and every host-qualified value of a step env in the CI workflow: a vendor ref passes only as a
# repository of the vendor list at a sha256 digest, an app ref under ghcr.io/<owner>/ passes only through its release
# checks (its tag, its attestation and the signer's commit on quality's main), and Flux's controllers pass in their
# namespace as the locked flux2 exports them. What the rule cannot judge is red too.
# Usage: mise exec -- scripts/verify_image_release.sh [tree], the tree defaulting to this checkout. The run names
# GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_REPOSITORY_OWNER, DEFAULT_BRANCH, RENDER_IMAGE, the image the render
# runs in, and FLUX_COMPONENTS, which mise.toml sets; gh reads GH_TOKEN or its own login, and reads the registry through
# Docker's login to ghcr.io.
# Exit: 0 nothing is red, 1 after at least one red record, 2 on any other failure.
set -Eeuo pipefail
trap 'echo "verify_image_release: line ${LINENO} failed: ${BASH_COMMAND}" >&2; exit 2' ERR

ROOT_SYNC_FILE="clusters/pc/flux-system/gotk-sync.yaml"
# The CI workflow whose step env values name the images its probes run in the cluster.
CI_WORKFLOW=".github/workflows/ci.yml"
VENDOR_LIST="infrastructure/admission/image-vendors.yaml"
# The admission layer's binding reads the list by this name and namespace (paramRef).
VENDOR_LIST_NAME="image-vendors"
VENDOR_LIST_NAMESPACE="admission"
# The PC-only source, rendered empty since CI holds no key for it; the cluster job's overlay swaps the same source.
PC_ONLY_SOURCE="GitRepository/flux-system/platform-secrets"
# An app's release: its image is built and attested by quality's reusable workflow from the app's main, and the
# signer's commit must lie on quality's main.
SIGNER_REPOSITORY_NAME="quality"
SIGNER_WORKFLOW=".github/workflows/image.yml"
SIGNER_BRANCH="main"
RELEASE_SOURCE_REF="refs/heads/main"
# Passed although it is gh's default, so a changed default cannot loosen the check.
RELEASE_PREDICATE_TYPE="https://slsa.dev/provenance/v1"

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
# Field path and string value of every env entry of every step of every job.
CI_STEP_ENV_VALUES='.jobs | to_entries | .[] | .key as $job | (.value.steps // []) | .[] | (.name // "") as $step
  | (.env // {}) | to_entries | .[] | select((.value | tag) == "!!str")
  | [".jobs." + $job + ".steps[" + $step + "].env." + .key, .value] | .[]'
# Object, apiVersion, field path, value, and key or candidate: an image key, or a string the grammar has to confirm as
# a host-qualified reference, in an object of a kind the rule does not know.
UNKNOWN_KIND_TRIGGERS="select(${POD_SPEC_PATH} == null)
  | select((.apiVersion == \"kustomize.toolkit.fluxcd.io/v1\" and .kind == \"Kustomization\") | not)
  | select((.apiVersion == \"apiextensions.k8s.io/v1\" and .kind == \"CustomResourceDefinition\") | not)
  | select((.apiVersion // \"\") | test(\"^helm[.]toolkit[.]fluxcd[.]io/\") | not)
  | ${OBJECT} as \$object | .apiVersion as \$api_version | (
    (.. | select(tag == \"!!map\" and has(\"image\"))
      | [\$object, \$api_version, ${FIELD_PATH} + \".image\", ((.image | select(kind == \"scalar\") | tostring) // \"\"), \"key\"]),
    (.. | select(tag == \"!!str\" and test(\"^((?i:localhost)|[^/ ]*[.:][^/ ]*)/[^ ]*[:@][^ /]*\$\"))
      | [\$object, \$api_version, ${FIELD_PATH}, ., \"candidate\"])
  ) | .[]"
# Object, apiVersion.
HELM_OBJECTS="select((.apiVersion // \"\") | test(\"^helm[.]toolkit[.]fluxcd[.]io/\")) | [${OBJECT}, .apiVersion] | .[]"
# Fact, object, value.
KUSTOMIZATION_FACTS="select(${KUSTOMIZATION}) | ${OBJECT} as \$object | (
    [\"identity\", \$object, ([.apiVersion, .spec] | sort_keys(..) | to_json(0))],
    [\"path\", \$object, ((.spec.path // \"\") | tostring)],
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
declare -A app_reference_locations=()

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

# Whether the repository $1 lies under the app namespace ghcr.io/<owner>/, in any case and with any port on the host,
# since each such spelling pulls from the same registry.
in_app_namespace() {
  [[ ${1,,} =~ ^ghcr\.io(:[0-9]+)?/${owner}/ ]]
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
    if in_app_namespace "${repository}"; then
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

# Whether the path $1, cleaned from its source's root, climbs above that root: flux build joins it to the checkout,
# while kustomize-controller clamps it inside the artifact (securejoin).
climbs_above_source_root() {
  local remainder="$1/" segment depth=0
  while [ -n "${remainder}" ]; do
    segment="${remainder%%/*}" remainder="${remainder#*/}"
    case "${segment}" in
      "" | .) ;;
      ..) depth=$((depth - 1)) && [ "${depth}" -ge 0 ] || return 0 ;;
      *) depth=$((depth + 1)) ;;
    esac
  done
  return 1
}

# Red: a changed, missing or repeated self-reference, a repeated Kustomization identity, a path above its source's root,
# a skipped missing component, a ConfigMap substitution and a health-checked Deployment the render lacks. A Secret
# substitution is gap G2.
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
      path)
        if climbs_above_source_root "${value}"; then
          report_red "${object} .spec.path" "${value}" "a path above its source's root, which the render resolves in the checkout and Flux inside its artifact"
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

# Red: a mapped source not rendered exactly once, a source field, ignore file or symlink that makes Flux's artifact
# differ from the checkout, a root source other than this repository's default branch, and a PC-only source other than
# the owner's repository of its name.
judge_sources() {
  local source index count field url ref ignore_file symlink host="${GITHUB_SERVER_URL#*://}"
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
  find . -name .git -prune -o -type l -print >"${work_directory}/symlinks"
  while IFS= read -r symlink; do
    report_red "${symlink#./}" "" "a symlink, which source-controller leaves out of the artifact and the render follows"
  done <"${work_directory}/symlinks"
}

# Red: every Helm object, and every other kind the rule does not know that carries an image, once per object.
judge_unknown_kinds() {
  local index object value
  local -A judged_objects=()
  read_records "${HELM_OBJECTS}"
  for ((index = 0; index < ${#records[@]}; index += 2)); do
    report_red "${records[index]}" "${records[index + 1]}" "a Helm object, which the render does not render"
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
  elif in_app_namespace "${repository}"; then
    app_reference_count=$((app_reference_count + 1))
    if [[ ${repository} =~ ^ghcr\.io/${owner}/${PATH_COMPONENT}(/${PATH_COMPONENT})?$ && ${named} != "${repository}" &&
      ${named##*:} =~ ${TAG_PATTERN} && ${image#"${named}"} =~ ${SHA256_DIGEST_PATTERN} ]]; then
      app_reference_locations["${image}"]+="${app_reference_locations[${image}]:+; }${location}"
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

# Judges every step env value of the CI workflow that is a host-qualified reference, as a Pod template's image is judged.
judge_ci_step_env_images() {
  local index status
  [ -f "${CI_WORKFLOW}" ] || fail "${CI_WORKFLOW} is missing"
  read_records "${CI_STEP_ENV_VALUES}" "${CI_WORKFLOW}"
  for ((index = 0; index < ${#records[@]}; index += 2)); do
    status=0
    parse_host_qualified_reference "${records[index + 1]}" || status=$?
    [ "${status}" -ne 1 ] || continue
    judge_image "${CI_WORKFLOW}" "" "${records[index]}" "${records[index + 1]}"
  done
}

# Prints the file $1 on one line.
one_line() {
  tr '\n' ' ' <"$1"
}

# Sets tag_commit to the commit the tag v$2 of the owner's repository $1 names, peeled when annotated. Returns 1 with
# release_failure set when git cannot list the tags or the tag is missing. ls-remote matches its patterns against the
# tail of each ref name, so only the two exact names count.
resolve_tag_commit() {
  local url="${GITHUB_SERVER_URL}/${owner}/$1" tag="refs/tags/v$2" object name direct="" peeled=""
  tag_commit=""
  if ! GIT_TERMINAL_PROMPT=0 git ls-remote "${url}" "${tag}" "${tag}^{}" >"${work_directory}/tags" \
    2>"${work_directory}/tag-errors"; then
    release_failure="git ls-remote ${url} failed: $(one_line "${work_directory}/tag-errors")"
    return 1
  fi
  while read -r object name; do
    case "${name}" in
      "${tag}") direct="${object}" ;;
      "${tag}^{}") peeled="${object}" ;;
    esac
  done <"${work_directory}/tags"
  tag_commit="${peeled:-${direct}}"
  [ -n "${tag_commit}" ] || { release_failure="the tag v$2 is missing in ${owner}/$1" && return 1; }
}

# Red unless the app ref $1, used at the locations $2, passes its release checks: its tag v<version> resolves to a
# commit, gh verifies an attestation of its digest from that commit through flags on fields the signer cannot forge
# (the attestations come from GitHub's API, and nothing is read from their statement), and every verified attestation's
# signer commit lies on quality's main.
check_app_release() {
  local image="$1" locations="$2" named="${1%@*}" repository version repository_name status signer index
  local signer_repository="${owner}/${SIGNER_REPOSITORY_NAME}" reds_before="${red_count}"
  repository="${named%:*}" version="${named##*:}"
  repository_name="${repository#*/*/}" repository_name="${repository_name%%/*}"
  if ! resolve_tag_commit "${repository_name}" "${version}"; then
    report_red "${locations}" "${image}" "${release_failure}"
    return
  fi
  if ! gh attestation verify "oci://${repository}@${image#*@}" --repo "${owner}/${repository_name}" \
    --signer-workflow "${signer_repository}/${SIGNER_WORKFLOW}" --source-digest "${tag_commit}" \
    --source-ref "${RELEASE_SOURCE_REF}" --predicate-type "${RELEASE_PREDICATE_TYPE}" --deny-self-hosted-runners \
    --format json >"${work_directory}/attestations.json" 2>"${work_directory}/attestation-errors"; then
    report_red "${locations}" "${image}" "no attestation verifies with the tag v${version}'s commit ${tag_commit} as source digest: $(one_line "${work_directory}/attestation-errors")"
    return
  fi
  read_records '.[] | (.verificationResult.signature.certificate.buildSignerDigest // "") | tostring' \
    "${work_directory}/attestations.json"
  [ "${#records[@]}" -gt 0 ] || report_red "${locations}" "${image}" "gh verified no attestation"
  for index in "${!records[@]}"; do
    signer="${records[index]}"
    if [[ ! ${signer} =~ ^[0-9a-f]{40}$ ]]; then
      report_red "${locations}" "${image}" "a verified attestation's signer digest '${signer}' is no commit"
    elif ! status="$(gh api "repos/${signer_repository}/compare/${signer}...${SIGNER_BRANCH}" --jq .status \
      2>"${work_directory}/compare-errors")"; then
      report_red "${locations}" "${image}" "the signer commit ${signer} is not on ${signer_repository}'s ${SIGNER_BRANCH}: $(one_line "${work_directory}/compare-errors")"
    elif [ "${status}" != ahead ] && [ "${status}" != identical ]; then
      report_red "${locations}" "${image}" "the signer commit ${signer} is not on ${signer_repository}'s ${SIGNER_BRANCH}: ${status}"
    fi
  done
  [ "${red_count}" -eq "${reds_before}" ] || return 0
  echo "images: ${image} at ${locations}: the tag v${version} of ${owner}/${repository_name} is commit ${tag_commit}, its attestation verifies, and the signer commits ${records[*]} are on ${signer_repository}'s ${SIGNER_BRANCH}"
}

main() {
  local variable index repository image reds_before released_count=0
  local -a app_references=()
  for variable in GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_REPOSITORY_OWNER DEFAULT_BRANCH RENDER_IMAGE FLUX_COMPONENTS; do
    [ -n "${!variable:-}" ] || fail "${variable} is not set"
  done
  tree="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
  cd "${tree}"
  owner="${GITHUB_REPOSITORY_OWNER,,}"
  work_directory="$(mktemp -d)"
  trap 'rm -rf "${work_directory}"' EXIT
  rendered="${work_directory}/rendered.yaml"
  flux install --export --components="${FLUX_COMPONENTS}" >"${work_directory}/flux-components.yaml"
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
  judge_ci_step_env_images
  for repository in "${!vendor_entry_by_repository[@]}"; do
    [ -n "${used_vendor_repositories[${repository}]+used}" ] ||
      report_red "${VENDOR_LIST} entry ${vendor_entry_by_repository[${repository}]}" "${repository}" "a vendor entry no rendered image or CI step env value uses"
  done
  echo "images: ${vendor_reference_count} vendor references pass"
  [ "${#app_reference_locations[@]}" -eq 0 ] ||
    mapfile -t app_references < <(printf '%s\n' "${!app_reference_locations[@]}" | sort)
  for image in "${app_references[@]}"; do
    reds_before="${red_count}"
    check_app_release "${image}" "${app_reference_locations[${image}]}"
    [ "${red_count}" -ne "${reds_before}" ] || released_count=$((released_count + 1))
  done
  if [ "${app_reference_count}" -eq 0 ]; then
    echo "images: no app image reference was found"
  else
    echo "images: ${app_reference_count} app image references, ${#app_reference_locations[@]} distinct full refs, ${released_count} pass their release checks"
  fi
  [ "${red_count}" -eq 0 ] || { echo "images: ${red_count} red" && exit 1; }
}

main "$@"
