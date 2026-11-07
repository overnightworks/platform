#!/usr/bin/env bash
# Scratch only: drive #56's cells E2 to E4, E7 to E9 and E15 through scripts/verify_image_release.sh, each on a copy of
# this checkout whose one app ref is the cell's, some through a script copy with the cell's one edit.
set -euo pipefail
checkout="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verify="${checkout}/scripts/verify_image_release.sh"
work="$(mktemp -d)"
INDEX="sha256:aaa309151f36d714fe49d8a285f85c4942b4e145e0befd32472167978c496ae6"
PLATFORM_MANIFEST="sha256:9892d3c6870fd8669d5ec70a8833fc23b8780aaf07bd4bce054622f2121e3709"
RELEASE_COMMIT="127f26c7606775f5f9f2a8ca940967f7ef1f30f3"
OFF_MAIN_SIGNER="239e51e7b4f6d8f8f83d2f3484f25736a5d2f9e0"
E1_REF="ghcr.io/overnightworks/hopin:2026.11.06.2@${INDEX}"

# Copy the checkout to $work/<cell> with the app ref $2 in infrastructure/scratch-hopin/hopin.yaml.
make_tree() {
  mkdir "${work}/$1"
  git -C "${checkout}" ls-files -z | (cd "${checkout}" && xargs -0 cp --parents -t "${work}/$1")
  sed -i "s|image: \"ghcr.io/overnightworks/hopin:[^\"]*\"|image: \"$2\"|" "${work}/$1/infrastructure/scratch-hopin/hopin.yaml"
  grep -F "image: \"$2\"" "${work}/$1/infrastructure/scratch-hopin/hopin.yaml" >/dev/null
}

# Copy the script to $work/<cell>.sh with the sed edit $2, and fail unless the edit changed it.
copy_script() {
  sed "$2" "${verify}" >"${work}/$1.sh"
  chmod +x "${work}/$1.sh"
  echo "cell $1: script copy edit:"
  diff "${verify}" "${work}/$1.sh" && { echo "cell $1: the edit did not apply" && exit 1; } || true
}

# Run the script $2 on the tree of cell $1 and print its exit and its verdict lines.
run_cell() {
  local status=0
  "$2" "${work}/$1" >"${work}/$1.log" 2>&1 || status=$?
  echo "cell $1: exit ${status}"
  grep -E '^red: |app image references|^images: ghcr.io/|verify_image_release' "${work}/$1.log" || true
}

echo "precondition E3: the release's tag v2026.11.06.2 and v2026.11.06.1 as git ls-remote lists them:"
git ls-remote https://github.com/overnightworks/hopin refs/tags/v2026.11.06.2 'refs/tags/v2026.11.06.2^{}' \
  refs/tags/v2026.11.06.1 'refs/tags/v2026.11.06.1^{}'
echo "precondition E4: the manifests inside hopin's index ${INDEX}:"
docker buildx imagetools inspect --raw "ghcr.io/overnightworks/hopin@${INDEX}" |
  yq --input-format json --output-format yaml '.manifests[] | [.digest, .platform.os + "/" + .platform.architecture, (.annotations."vnd.docker.reference.type" // "")] | join(" ")'

make_tree E2 "ghcr.io/overnightworks/hopin:2099.01.01.1@${INDEX}"
run_cell E2 "${verify}"
make_tree E3 "ghcr.io/overnightworks/hopin:2026.11.06.1@${INDEX}"
run_cell E3 "${verify}"
make_tree E4 "ghcr.io/overnightworks/hopin:2026.11.06.2@${PLATFORM_MANIFEST}"
run_cell E4 "${verify}"
make_tree E7 "${E1_REF}"
copy_script E7 's|--repo "${owner}/${repository_name}"|--repo "${owner}/presentator"|'
run_cell E7 "${work}/E7.sh"
make_tree E8 "${E1_REF}"
copy_script E8 "/gh verified no attestation/i\\  records=(\"\${records[@]/*/${OFF_MAIN_SIGNER}}\")"
run_cell E8 "${work}/E8.sh"
make_tree E9 "${E1_REF}"
copy_script E9 's|^RELEASE_PREDICATE_TYPE=.*|RELEASE_PREDICATE_TYPE="https://spdx.dev/Document/v2.3"|'
run_cell E9 "${work}/E9.sh"

git init -q --bare "${work}/hopin.git"
git -C "${work}/hopin.git" fetch -q --depth 1 https://github.com/overnightworks/hopin "${RELEASE_COMMIT}"
git -C "${work}/hopin.git" -c user.name=scratch -c user.email=scratch@invalid \
  tag -a -m "v2026.11.06.2, annotated" v2026.11.06.2 "${RELEASE_COMMIT}"
echo "precondition E15: the local clone's tag:"
git ls-remote "file://${work}/hopin.git" refs/tags/v2026.11.06.2 'refs/tags/v2026.11.06.2^{}'
make_tree E15 "${E1_REF}"
copy_script E15 "s|local url=\"\${GITHUB_SERVER_URL}/\${owner}/\$1\"|local url=\"file://${work}/hopin.git\"|"
run_cell E15 "${work}/E15.sh"
