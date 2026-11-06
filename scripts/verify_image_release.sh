#!/usr/bin/env bash
# Judge every image reference the tracked YAML and JSON files hold, YAML held in their strings included: a vendor ref
# passes only as a repository of the vendor list at a sha256 digest, and every app ref is red, since no release check
# exists here. GITHUB_REPOSITORY_OWNER names the app namespace ghcr.io/<owner>/.
# Usage: mise exec -- scripts/verify_image_release.sh, so yq is the one mise.lock pins.
# Exit: 0 every reference passes, 1 a reference, a vendor entry or a file is red.
set -euo pipefail

VENDOR_LIST="infrastructure/admission/image-vendors.yaml"
# flux install --export of the locked flux2; the cluster job fails when it differs from a regeneration.
GENERATED_FLUX_COMPONENTS="clusters/pc/flux-system/gotk-components.yaml"
IMAGES_OVERRIDE_REASON="an images override rewrites an image named elsewhere"

# The reference grammar of distribution/reference, matched against the lowercased string.
DOMAIN_COMPONENT='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
DOMAIN="(${DOMAIN_COMPONENT}(\\.${DOMAIN_COMPONENT})*|\\[[0-9a-f:]+\\])(:[0-9]+)?"
PATH_COMPONENT='[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*'
NAME_PATTERN="^(${DOMAIN}/)?${PATH_COMPONENT}(/${PATH_COMPONENT})*\$"
TAG_PATTERN='^[a-z0-9_][a-z0-9_.-]{0,127}$'
DIGEST_PATTERN='^[a-z][a-z0-9]*([-_+.][a-z][a-z0-9]*)*:[0-9a-f]{32,}$'
SHA256_DIGEST_PATTERN='^sha256:[0-9a-f]{64}$'

# Every record is five NUL-terminated fields: type, document index, JSON pointer, value, reason. A scalar at an image
# position (a key image, a patch operation's value at an /image path) leaves the plain scalar walk for the image one.
POINTER='(path | map("/" + (tostring | sub("~", "~0") | sub("/", "~1"))) | join(""))'
PATCH_OPERATION='(kind == "map" and has("op") and has("path") and (parent | kind) == "seq")'
IMAGE_POSITION="((key == \"image\" and (parent | kind) == \"map\") or (key == \"value\" and (parent | (${PATCH_OPERATION} and (.path | tostring | test(\"/image\$\"))))))"
SPLIT_IMAGE="
  . as \$mapping |
  [keys | .[] | select(. != \"registry\" and . != \"repository\" and . != \"tag\" and . != \"digest\" and . != \"pullPolicy\")] as \$unknown |
  [to_entries | .[] | select((.value | tag) != \"!!null\" and .value != \"\")] as \$set |
  [\$set | .[] | select((.value | tag) != \"!!str\") | .key] as \$not_strings |
  [\$set | .[] | select(.key == \"registry\") | .value] as \$registry |
  [\$set | .[] | select(.key == \"repository\") | .value] as \$repository |
  [\$set | .[] | select(.key == \"tag\") | .value] as \$tag |
  [\$set | .[] | select(.key == \"digest\") | .value] as \$digest |
  (\$mapping | to_json(0)) as \$shown |
  if (\$unknown | length) > 0 then [\"red\", \$document, ${POINTER}, \$shown, \"a split image mapping holds \" + (\$unknown | join(\", \")) + \" beside registry, repository, tag, digest and pullPolicy\"]
  elif (\$not_strings | length) > 0 then [\"red\", \$document, ${POINTER}, \$shown, \"a set split image field is not a string: \" + (\$not_strings | join(\", \"))]
  elif (\$registry | length) == 0 or (\$repository | length) == 0 then [\"red\", \$document, ${POINTER}, \$shown, \"a split image mapping needs registry and repository\"]
  elif (\$digest | length) > 0 then (
    if (\$digest | .[0] | test(\"${SHA256_DIGEST_PATTERN}\")) then [\"split\", \$document, ${POINTER}, (\$registry | .[0]) + \"/\" + (\$repository | .[0]) + \"@\" + (\$digest | .[0]), \"\"]
    else [\"red\", \$document, ${POINTER}, \$shown, \"a split image digest is not sha256:<64 hex>\"] end)
  elif (\$tag | length) > 0 then [\"split\", \$document, ${POINTER}, (\$registry | .[0]) + \"/\" + (\$repository | .[0]) + \":\" + (\$tag | .[0]), \"\"]
  else [\"red\", \$document, ${POINTER}, \$shown, \"a split image mapping with neither tag nor digest runs the chart's default tag\"] end"
IMAGE_VALUE="
  if tag == \"!!null\" then [\"red\", \$document, ${POINTER}, \"null\", \"an image with a null value\"]
  elif kind == \"scalar\" then [\"image\", \$document, ${POINTER}, tostring, \"\"]
  elif kind == \"map\" then (${SPLIT_IMAGE})
  else [\"red\", \$document, ${POINTER}, to_json(0), \"an image that is a sequence\"] end"
PATCH_RULES="
  ${POINTER} as \$operation | (.path | tostring) as \$target | (.op | tostring) as \$op | (
  (select(\$target | test(\"/image/\")) | [\"red\", \$document, \$operation, \$op + \" \" + \$target, \"a patch operation below an image segment changes one part of a reference joined elsewhere\"]),
  (select(\$target | test(\"/image\$\")) | (
    if (\$op == \"add\" or \$op == \"replace\" or \$op == \"test\") | not then [\"red\", \$document, \$operation, \$op + \" \" + \$target, \"a \" + \$op + \" at an /image path hands the image to a chart default or a value read elsewhere\"]
    elif has(\"value\") | not then [\"red\", \$document, \$operation, \$op + \" \" + \$target, \"a patch operation at an /image path without a value\"]
    else (.value | ${IMAGE_VALUE}) end)),
  (select(has(\"from\") and (.from | tostring | test(\"/image(/|\$)\"))) | [\"red\", \$document, \$operation, \$op + \" from \" + (.from | tostring), \"a patch operation whose from lies at or below an /image path\"]))"
RECORDS="
  explode(.) | document_index as \$document | (
    [\"root\", \$document, \"\", kind, \"\"],
    (.. | select(kind == \"scalar\") | select(${IMAGE_POSITION} | not) | [\"scalar\", \$document, ${POINTER}, tostring, \"\"]),
    (.. | select(kind == \"map\") | ${POINTER} as \$map | keys | .[] | [\"scalar\", \$document, \$map + \"/\" + (tostring | sub(\"~\", \"~0\") | sub(\"/\", \"~1\")), tostring, \"\"]),
    (.. | select(key == \"image\" and (parent | kind) == \"map\") | ${IMAGE_VALUE}),
    (.. | select(${PATCH_OPERATION}) | ${PATCH_RULES}),
    (.. | select(key == \"images\" and kind == \"seq\") | [\"red\", \$document, ${POINTER}, to_json(0), \"${IMAGES_OVERRIDE_REASON}\"])
  ) | .[]"

red_count=0
app_reference_count=0
vendor_reference_count=0
declare -A vendor_entry_by_repository=()
declare -A used_vendor_repositories=()

report_red() {
  red_count=$((red_count + 1))
  echo "red: $1: '${2//$'\n'/\\n}': $3"
}

# Prints the records of every document of $2 ('-' for stdin) read as $1; fails when yq cannot parse it.
decode() {
  yq --no-doc --nul-output --output-format yaml --yaml-fix-merge-anchor-to-spec=true --input-format "$1" "${RECORDS}" "$2"
}

# Sets reference_name, reference_tag and reference_digest by splitting $1, then validates them. Returns 1 when $1 is
# no candidate (a whitespace-free string, no URL, with a registry host before its first slash) and 2 when a candidate
# breaks the reference grammar.
parse_host_qualified_reference() {
  local remainder="$1" last_component host
  reference_name="" reference_tag="" reference_digest=""
  if [[ ${remainder} == *@* ]]; then
    reference_digest="${remainder#*@}"
    remainder="${remainder%%@*}"
  fi
  last_component="${remainder##*/}"
  if [[ ${last_component} == *:* ]]; then
    reference_tag="${last_component##*:}"
    remainder="${remainder%:*}"
  fi
  reference_name="${remainder}"
  host="${reference_name%%/*}"
  [[ $1 != *[[:space:]]* && ! $1 =~ ^[A-Za-z][A-Za-z0-9+.-]*:// && ${reference_name} == */* &&
    (${host} == *.* || ${host} == *:* || ${host,,} == localhost) ]] || return 1
  [[ -z ${reference_digest} || ${reference_digest,,} =~ ${DIGEST_PATTERN} ]] || return 2
  [[ -z ${reference_tag} || ${reference_tag,,} =~ ${TAG_PATTERN} ]] || return 2
  [[ ${reference_name,,} =~ ${NAME_PATTERN} ]] || return 2
}

judge_app_reference() {
  local location="$1" value="$2" position="$3" repository_pattern="^ghcr\\.io/${owner}/${PATH_COMPONENT}(/${PATH_COMPONENT})?\$"
  app_reference_count=$((app_reference_count + 1))
  if [ "${position}" = split ]; then
    report_red "${location}" "${value}" "an app ref in split form; an app ref is one string"
  elif ! parse_host_qualified_reference "${value}" || [[ ! ${reference_name,,} =~ ${repository_pattern} ]] ||
    [ -z "${reference_tag}" ] || [[ ! ${reference_digest} =~ ${SHA256_DIGEST_PATTERN} ]]; then
    report_red "${location}" "${value}" "not one full app ref ghcr.io/${owner}/<repo>[/<name>]:<version>@sha256:<64 hex>"
  elif [ "${reference_name}" != "${reference_name,,}" ]; then
    report_red "${location}" "${value}" "an app ref whose registry host or path is not lowercase"
  else
    report_red "${location}" "${value}" "an app ref, and no release check exists yet"
  fi
}

# Judges one decoded string at a position: content (any scalar), image (an image value) or split (a joined mapping).
judge_string() {
  local location="$1" value="$2" position="$3" namespace_content_rule="$4" reasons=() joined_reasons parse_status=0
  if [[ ${value,,} == *"ghcr.io/${owner}/"* ]] && { [ "${position}" != content ] || [ "${namespace_content_rule}" = true ]; }; then
    judge_app_reference "${location}" "${value}" "${position}"
    return
  fi
  parse_host_qualified_reference "${value}" || parse_status=$?
  if [ "${parse_status}" -ne 0 ]; then
    if [ "${position}" != content ]; then
      report_red "${location}" "${value}" "an image that is no valid reference with a registry host"
    elif [ "${parse_status}" -eq 2 ] && [ -n "${reference_tag}${reference_digest}" ]; then
      report_red "${location}" "${value}" "a host-qualified reference with a tag or digest that breaks the reference grammar"
    fi
    return
  fi
  [ "${position}" != content ] || [ -n "${reference_tag}${reference_digest}" ] || return 0
  if [[ ${reference_name,,} == "ghcr.io/${owner}/"* ]]; then
    judge_app_reference "${location}" "${value}" "${position}"
    return
  fi
  vendor_reference_count=$((vendor_reference_count + 1))
  if [ "${reference_name}" != "${reference_name,,}" ]; then
    reasons+=("its registry host or path is not lowercase")
  elif [ -n "${vendor_entry_by_repository[${reference_name}]+listed}" ]; then
    used_vendor_repositories["${reference_name}"]=1
  else
    reasons+=("its repository is not in ${VENDOR_LIST}")
  fi
  [[ ${reference_digest} =~ ${SHA256_DIGEST_PATTERN} ]] || reasons+=("it has no sha256:<64 hex> digest")
  if [ "${#reasons[@]}" -eq 0 ]; then
    echo "pass: ${location}: '${value}'"
  else
    printf -v joined_reasons '%s; ' "${reasons[@]}"
    report_red "${location}" "${value}" "a vendor ref: ${joined_reasons%; }"
  fi
}

# Judges the records in the file $2, read from a source at $1; a string that holds a YAML mapping or sequence is
# replaced by its decoded children.
judge_records() {
  local prefix="$1" records_file="$2" namespace_content_rule="$3" depth="$4" records index
  mapfile -d '' records <"${records_file}"
  for ((index = 0; index < ${#records[@]}; index += 5)); do
    local type="${records[index]}" location="${prefix} doc ${records[index + 1]} ${records[index + 2]:-/}"
    local value="${records[index + 3]}" reason="${records[index + 4]}"
    case "${type}" in
      root) ;;
      red) report_red "${location}" "${value}" "${reason}" ;;
      image | split) judge_string "${location}" "${value}" "${type}" "${namespace_content_rule}" ;;
      scalar) judge_scalar "${location}" "${records[index + 2]}" "${value}" "${namespace_content_rule}" "${depth}" ;;
      *) echo "verify_image_release: unknown record type ${type}" >&2 && exit 1 ;;
    esac
  done
}

# Succeeds when a document of the records file $1 has a root of one of the kinds $2....
holds_root_kind() {
  local records_file="$1" records index kind
  shift
  mapfile -d '' records <"${records_file}"
  for ((index = 0; index < ${#records[@]}; index += 5)); do
    [ "${records[index]}" = root ] || continue
    for kind in "$@"; do
      [ "${records[index + 3]}" != "${kind}" ] || return 0
    done
  done
  return 1
}

# Judges a scalar at the JSON pointer $2 of $1. A string that parses as a mapping or sequence is replaced by its decoded
# children and keeps its field, so an images field holding a sequence is an override. yq cannot print a scalar that
# holds a NUL character, so a string yq parses as a mapping or sequence but cannot decode is red.
judge_scalar() {
  local location="$1" pointer="$2" value="$3" namespace_content_rule="$4" depth="$5" kinds
  local nested_file="${work_directory}/records.$((depth + 1))"
  if printf '%s' "${value}" | decode yaml - >"${nested_file}" 2>/dev/null; then
    if holds_root_kind "${nested_file}" map seq; then
      if [[ ${pointer} == */images ]] && holds_root_kind "${nested_file}" seq; then
        report_red "${location}" "${value}" "${IMAGES_OVERRIDE_REASON}"
      fi
      judge_records "${location} >" "${nested_file}" "${namespace_content_rule}" "$((depth + 1))"
      return
    fi
  elif kinds="$(printf '%s' "${value}" | yq --no-doc --input-format yaml kind - 2>/dev/null)" && [[ ${kinds} == *map* || ${kinds} == *seq* ]]; then
    report_red "${location}" "${value}" "yq parses the string as a YAML document but cannot decode it"
    return
  fi
  judge_string "${location}" "${value}" content "${namespace_content_rule}"
}

judge_file() {
  local file="$1" input_format=yaml namespace_content_rule=true records_file="${work_directory}/records.0"
  [[ ${file,,} != *.json ]] || input_format=json
  # The admission policies name the app namespace as a pattern, not as a reference.
  case "${file}" in
    infrastructure/admission/image-policy.yaml | infrastructure/app-attestations/app-attestations.yaml) namespace_content_rule=false ;;
  esac
  if ! decode "${input_format}" "${file}" >"${records_file}"; then
    report_red "${file}" "" "yq cannot parse the file"
    return
  fi
  judge_records "${file}" "${records_file}" "${namespace_content_rule}" 0
}

load_vendor_list() {
  local entries_file="${work_directory}/vendor-entries" entries index repository
  yq --nul-output --output-format yaml '.data // {} | to_entries | .[] | [.key, (.value | tostring)] | .[]' "${VENDOR_LIST}" >"${entries_file}" ||
    { echo "verify_image_release: yq cannot read the vendor list ${VENDOR_LIST}" >&2 && exit 1; }
  mapfile -d '' entries <"${entries_file}"
  for ((index = 0; index < ${#entries[@]}; index += 2)); do
    repository="${entries[index + 1]}"
    if [[ ${repository,,} == "ghcr.io/${owner}/"* ]]; then
      report_red "${VENDOR_LIST} entry ${entries[index]}" "${repository}" "a vendor entry under the app namespace ghcr.io/${owner}/"
    elif ! parse_host_qualified_reference "${repository}" || [ "${repository}" != "${repository,,}" ]; then
      report_red "${VENDOR_LIST} entry ${entries[index]}" "${repository}" "a vendor entry that is no lowercase <registry>/<repository>"
    elif [ -n "${reference_tag}${reference_digest}" ]; then
      report_red "${VENDOR_LIST} entry ${entries[index]}" "${repository}" "a vendor entry with a version"
    else
      vendor_entry_by_repository["${repository}"]="${entries[index]}"
    fi
  done
}

main() {
  local repository_root tracked_files file
  repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "${repository_root}"
  owner="${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER names the app namespace ghcr.io/<owner>/}"
  owner="${owner,,}"
  work_directory="$(mktemp -d)"
  trap 'rm -rf "${work_directory}"' EXIT
  load_vendor_list
  tracked_files="${work_directory}/tracked-files"
  git ls-files -z -- ':(icase)*.yaml' ':(icase)*.yml' ':(icase)*.json' >"${tracked_files}"
  while IFS= read -r -d '' file; do
    [ "${file}" = "${GENERATED_FLUX_COMPONENTS}" ] || judge_file "${file}"
  done <"${tracked_files}"
  for repository in "${!vendor_entry_by_repository[@]}"; do
    [ -n "${used_vendor_repositories[${repository}]+used}" ] ||
      report_red "${VENDOR_LIST} entry ${vendor_entry_by_repository[${repository}]}" "${repository}" "a vendor entry no tracked ref uses"
  done
  echo "images: ${vendor_reference_count} vendor references"
  if [ "${app_reference_count}" -eq 0 ]; then
    echo "images: no app image reference was found"
  else
    echo "images: ${app_reference_count} app image references, none passes before the release checks exist"
  fi
  [ "${red_count}" -eq 0 ] || { echo "images: ${red_count} red" && exit 1; }
}

main "$@"
