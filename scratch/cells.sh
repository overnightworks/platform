#!/usr/bin/env bash
# Drives scripts/verify_image_release.sh on scratch trees. Usage: cells.sh <repo-root> <out-dir> [cell...]
set -uo pipefail
repo="$1" out="$2"; shift 2
only=("$@")
mkdir -p "${out}"
verify="${repo}/scripts/verify_image_release.sh"
base="${repo}/tests/images/base"
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=overnightworks/platform
export GITHUB_REPOSITORY_OWNER=overnightworks DEFAULT_BRANCH=main RENDER_IMAGE=ubuntu:26.04
H=ghcr.io/overnightworks/hopin V2=2026.11.06.2 V1=2026.11.06.1
D=sha256:aaa309151f36d714fe49d8a285f85c4942b4e145e0befd32472167978c496ae6
DM=sha256:9892d3c6870fd8669d5ec70a8833fc23b8780aaf07bd4bce054622f2121e3709
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

deployment() { # name image
  cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: $1, namespace: default}
spec:
  template:
    spec:
      containers:
        - {name: main, image: "$2"}
---
YAML
}
tree() { # cell, manifest on stdin
  rm -rf "${work}/$1"; mkdir -p "${work}/$1"; cp -R "${base}/." "${work}/$1"
  cat >"${work}/$1/clusters/pc/hopin.yaml"
}
want() { [ "${#only[@]}" -eq 0 ] || [[ " ${only[*]} " == *" $1 "* ]]; }
run() { # cell, script (default lane's), extra env via environment
  local cell="$1" script="${2:-${verify}}" status=0
  want "${cell}" || return 0
  "${script}" "${work}/${cell}" >"${out}/${cell}.log" 2>&1 || status=$?
  echo "${status}" >"${out}/${cell}.exit"
  echo "=== ${cell}: exit ${status}"
  grep -E '^(red|images|verify_image_release)' "${out}/${cell}.log" | grep -v 'gap G1\|renders [0-9]* objects' | cut -c1-700
}
copy() { # name sed-expression
  cp "${verify}" "${work}/$1.sh"; sed -i -e "$2" "${work}/$1.sh"
  cmp -s "${verify}" "${work}/$1.sh" && echo "COPY $1 UNCHANGED" >&2
  chmod +x "${work}/$1.sh"
  diff <(cat "${verify}") "${work}/$1.sh" >"${out}/$1.copy.diff"
}

deployment hopin "${H}:${V2}@${D}" | tree e1;                      run e1
deployment hopin "${H}:${V1}@${D}" | tree e3;                      run e3
deployment hopin "${H}:${V2}@${DM}" | tree e4;                     run e4
deployment hopin "${H}:2099.01.01.1@${D}" | tree e2;               run e2
deployment hopin "${H}:${V2}@${D}" | tree e7
copy e7 's|--repo "${owner}/${repository_name}"|--repo "${owner}/presentator"|'; run e7 "${work}/e7.sh"
quality_sha="$(gh api repos/overnightworks/quality/pulls/404 --jq .head.sha)"
deployment hopin "${H}:${V2}@${D}" | tree e8
copy e8 "s|'.\[\] \| (.verificationResult.signature.certificate.buildSignerDigest // \"\") \| tostring'|'.[] \| \"${quality_sha}\"'|"; run e8 "${work}/e8.sh"
deployment hopin "${H}:${V2}@${D}" | tree e9
copy e9 's|^RELEASE_PREDICATE_TYPE=.*|RELEASE_PREDICATE_TYPE="https://spdx.dev/Document/v2.3"|'; run e9 "${work}/e9.sh"
# E15: annotated tags in a local bare clone of hopin
if want e15 || want e15b; then
  git clone -q --bare --filter=blob:none https://github.com/overnightworks/hopin "${work}/remote/overnightworks/hopin"
  git -C "${work}/remote/overnightworks/hopin" -c user.name=scratch -c user.email=scratch@example.invalid tag -d "v${V2}" >/dev/null
  git -C "${work}/remote/overnightworks/hopin" -c user.name=scratch -c user.email=scratch@example.invalid tag -a -m scratch "v${V2}" 127f26c7606775f5f9f2a8ca940967f7ef1f30f3
  git -C "${work}/remote/overnightworks/hopin" ls-remote . "refs/tags/v${V2}*" | tee "${out}/e15.tags"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://${work}/remote/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/
  deployment hopin "${H}:${V2}@${D}" | tree e15; run e15
  git -C "${work}/remote/overnightworks/hopin" -c user.name=scratch -c user.email=scratch@example.invalid tag -a -f -m scratch "v${V2}" df39828d0e5e164694bc7b70184ed3153bc6c624
  git -C "${work}/remote/overnightworks/hopin" ls-remote . "refs/tags/v${V2}*" | tee "${out}/e15b.tags"
  deployment hopin "${H}:${V2}@${D}" | tree e15b; run e15b
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
fi
# adversarial
{ deployment one "${H}:${V2}@${D}"; deployment two "${H}:${V2}@${DM}"; } | tree a1-same-tag-two-digests; run a1-same-tag-two-digests
{ deployment web "${H}:${V2}@${D}"; cat <<YAML
apiVersion: batch/v1
kind: CronJob
metadata: {name: nightly, namespace: default}
spec:
  schedule: "0 3 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - {name: main, image: "docker.io/library/busybox:1"}
          initContainers:
            - {name: prep, image: "${H}:${V2}@${D}"}
---
YAML
} | tree a2-cronjob-initcontainer; run a2-cronjob-initcontainer
deployment hopin "${H}:2026.11.06.9@${D}" | tree a3-nonexistent-version; run a3-nonexistent-version
deployment hopin "${H}:v${V2}@${D}" | tree a4-v-prefixed-tag; run a4-v-prefixed-tag
deployment hopin "${H}/web:${V2}@${D}" | tree a5-nested-name; run a5-nested-name
deployment hopin "ghcr.io/overnightworks/quality:${V2}@${D}" | tree a6-other-repo-real-digest; run a6-other-repo-real-digest
deployment hopin "ghcr.io/overnightworks/platform-secrets:1.0@${D}" | tree a7-private-repo; run a7-private-repo
deployment hopin "ghcr.io/overnightworks/nosuchrepo-xyz:1.0@${D}" | tree a8-nonexistent-repo; run a8-nonexistent-repo
deployment hopin "${H}:${V2}@sha256:${D#sha256:}" | sed 's/aaa309151f/AAA309151F/' | tree a9-uppercase-digest; run a9-uppercase-digest
cat >"${work}/vol.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata: {name: vol, namespace: default}
spec:
  containers:
    - {name: main, image: "docker.io/library/busybox:1"}
  volumes:
    - name: data
      image: {reference: "${H}:${V2}@${D}"}
YAML
tree a10-image-volume <"${work}/vol.yaml"; run a10-image-volume
deployment hopin "ghcr.io/someoneelse/hopin:${V2}@${D}" | tree a11-other-owner; run a11-other-owner
{ deployment one "${H}:${V2}@${D}"; deployment two "${H}:${V1}@${D}"; } | tree a12-green-and-red-together; run a12-green-and-red-together
deployment hopin "${H}:${V2}@${D}" | tree a13-tag-case; sed -i "s|:${V2}@|:${V2^^}@|" "${work}/a13-tag-case/clusters/pc/hopin.yaml"; run a13-tag-case
echo "quality_sha=${quality_sha}" >"${out}/quality_sha.txt"
