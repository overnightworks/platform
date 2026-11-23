# shellcheck shell=bash
# Sourced by the cells under tests/release_bump/: the world one release bump runs in, with no way out of it. The app
# repository hopin and platform are bare repositories under $work/remote, which git reads for github.com through
# insteadOf, so a call that is not faked reaches nothing: docker and gh are fakes on PATH that answer only the calls the
# scripts make and fail any other, git has neither a global configuration nor a credential, gh has no login and
# docker's configuration is an empty directory. A cell reads $work, $checkout (a clone of platform's main), the
# fixture registry through registry_add and the fakes' records in $work/gh-calls and $work/docker-calls.
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../failure.sh
source "${repository_root}/tests/failure.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
checkout="${work}/checkout"
app_repository="${work}/app-hopin"
registry="${work}/registry"
gh_state="${work}/gh-state"
mkdir -p "${work}/bin" "${work}/remote/overnightworks" "${work}/gh-config" "${work}/docker-config" "${registry}" "${gh_state}"
: >"${work}/gh-calls"
: >"${work}/docker-calls"

export MISE_DISABLE_TOOLS=gh GH_CONFIG_DIR="${work}/gh-config" DOCKER_CONFIG="${work}/docker-config"
export MISE_TRUSTED_CONFIG_PATHS="${work}"
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://${work}/remote/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/
export FAKE_REGISTRY="${registry}" FAKE_GH_STATE="${gh_state}" FAKE_GH_CALLS="${work}/gh-calls" FAKE_DOCKER_CALLS="${work}/docker-calls"
export PATH="${work}/bin:${PATH}"

# docker answers only `buildx imagetools inspect <ref> --format ...` from the fixture registry, one file per ref holding
# its digest, and `login`, whose password it reads from stdin and never records.
cat >"${work}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $* [config ${DOCKER_CONFIG}]" >>"${FAKE_DOCKER_CALLS}"
case "$1 $2 $3" in
  "buildx imagetools inspect")
    file="${FAKE_REGISTRY}/${4//\//_}"
    [ -f "${file}" ] || { echo "ERROR: $4: not found" >&2; exit 1; }
    printf '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s"}\n' "$(cat "${file}")"
    ;;
  "login ghcr.io --username") cat >/dev/null ;;
  *) echo "the fake docker has no answer for: $*" >&2; exit 97 ;;
esac
FAKE
# gh answers the pull request calls of the publish step from one file naming the open pull request, and the two calls the
# hand command makes for its login.
cat >"${work}/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >>"${FAKE_GH_CALLS}"
case "$1 $2" in
  "pr list") [ ! -f "${FAKE_GH_STATE}/open" ] || cat "${FAKE_GH_STATE}/open" ;;
  "pr create") echo 1 >"${FAKE_GH_STATE}/open"; echo https://github.com/overnightworks/platform/pull/1 ;;
  "pr edit") ;;
  "pr close") rm -f "${FAKE_GH_STATE}/open" ;;
  "auth token") echo fixture-token ;;
  "api user") echo fixture-user ;;
  *) echo "the fake gh has no answer for: $*" >&2; exit 97 ;;
esac
FAKE
chmod +x "${work}/bin/docker" "${work}/bin/gh"

# digest_of <image name> <version>: the digest the fixture registry holds, once the image is added.
digest_of() { printf 'sha256:%s\n' "$(printf '%s:%s' "$1" "$2" | sha256sum | cut -d' ' -f1)"; }
# registry_add <image name> <version>
registry_add() { digest_of "$1" "$2" >"${registry}/${1//\//_}:$2"; }
# calls <file> <pattern>: how many recorded calls hold the pattern.
calls() { grep -c -- "$2" "$1" || true; }

# The app repository's first commit holds the pages of the real hopin copies; app_release <version> [change] commits and
# tags v<version> on the given day, with the pages changed ("text"), one page removed ("remove") or untouched.
git init --quiet --bare "${work}/remote/overnightworks/hopin"
git init --quiet --initial-branch=main "${app_repository}"
mkdir "${app_repository}/legal"
cp "${repository_root}"/infrastructure/legal/app-texts/hopin/*.html "${app_repository}/legal/"
app_release() {
  local version="$1" change="${2:-}" date
  date="$(grep -oE '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}' <<<"${version}" || echo 2026.11.20)"
  date="${date//./-}"
  case "${change}" in
    text) sed -i 's/Videoanrufe im Browser/Videoanrufe und Chats im Browser/' "${app_repository}/legal/datenschutz.html" ;;
    remove) rm "${app_repository}/legal/nutzungsbedingungen.html" ;;
  esac
  git -C "${app_repository}" add --all
  GIT_AUTHOR_DATE="${date}T12:00:00+0000" GIT_COMMITTER_DATE="${date}T12:00:00+0000" \
    git -C "${app_repository}" -c user.name=fixture -c user.email=fixture@example.org commit --quiet --allow-empty --message "release ${version}"
  git -C "${app_repository}" tag "v${version}"
  git -C "${app_repository}" push --quiet "file://${work}/remote/overnightworks/hopin" main --tags
}

# Platform's main holds the real tree of what a bump reads and writes: the legal layer and its builder, hopin's
# Component, whose version the releases of a cell are newer than, and the bump's own scripts.
git init --quiet --bare --initial-branch=main "${work}/remote/overnightworks/platform"
seed="${work}/seed"
mkdir "${seed}"
(cd "${repository_root}" && git ls-files -z -- mise.toml mise.lock src/legal/pyproject.toml src/legal/uv.lock src/legal/src \
  infrastructure/legal apps/hopin/release | xargs -0 cp --parents --target-directory "${seed}" &&
  cp --parents scripts/release_bump_*.sh "${seed}")
git -C "${seed}" init --quiet --initial-branch=main
git -C "${seed}" add --all
git -C "${seed}" -c user.name=fixture -c user.email=fixture@example.org commit --quiet --message "main"
git -C "${seed}" push --quiet "file://${work}/remote/overnightworks/platform" main
git clone --quiet https://github.com/overnightworks/platform "${checkout}"
main_version="$(yq '.images[0].newTag' "${checkout}/apps/hopin/release/kustomization.yaml")"

# clone_main <directory>: a fresh clone of the platform remote's main, on which a cell applies a patch.
clone_main() { git clone --quiet https://github.com/overnightworks/platform "$1"; }
