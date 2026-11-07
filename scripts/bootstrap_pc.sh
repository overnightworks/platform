#!/usr/bin/env bash
# Install the pinned mise, check its sha256, trust this checkout's mise.toml and hand over to `mise bootstrap`.
# Pin source: the release assets of https://github.com/jdx/mise/releases/tag/v2026.11.3 (asset digest and SHASUMS256.txt).
# Usage: scripts/bootstrap_pc.sh [mise bootstrap flags], for example `--only tools`.
# A fresh machine needs git, curl and sha256sum first; the script names the first one missing and installs nothing.
set -euo pipefail

MISE_VERSION="v2026.11.3"
MISE_SHA256="c2f7e814cb39f60b7f67a0ff36cb805e94128bf2dff09d175309d0f095b8cc3b"
MISE_ASSET="mise-${MISE_VERSION}-linux-x64"
MISE_URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/${MISE_ASSET}"
MISE_BINARY="${HOME}/.local/bin/mise"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$(uname -sm)" != "Linux x86_64" ]; then
  echo "bootstrap_pc: the pin covers only ${MISE_ASSET}, this machine is $(uname -sm)" >&2
  exit 1
fi

for prerequisite in git curl sha256sum; do
  if ! command -v "${prerequisite}" >/dev/null; then
    echo "bootstrap_pc: ${prerequisite} is missing; install it first" >&2
    exit 1
  fi
done

has_pinned_checksum() {
  echo "${MISE_SHA256}  $1" | sha256sum --check --status
}

install_pinned_mise() {
  mkdir -p "$(dirname "${MISE_BINARY}")"
  staging="$(mktemp "${MISE_BINARY}.staging.XXXXXX")"
  trap 'rm -f "${staging}"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "${staging}" "${MISE_URL}"
  if ! has_pinned_checksum "${staging}"; then
    echo "bootstrap_pc: ${MISE_URL} does not match the pinned sha256 ${MISE_SHA256}; nothing was installed" >&2
    exit 1
  fi
  chmod 0755 "${staging}"
  mv -f "${staging}" "${MISE_BINARY}"
  trap - EXIT
}

if [ ! -f "${MISE_BINARY}" ] || ! has_pinned_checksum "${MISE_BINARY}"; then
  install_pinned_mise
fi

cd "${repository_root}"
# mise reads ufw's output as English ("Status: active", "Default:"), and sudo keeps LC_ALL, so a German ufw reads as inactive.
export LC_ALL=C
"${MISE_BINARY}" trust "${repository_root}/mise.toml"
exec "${MISE_BINARY}" bootstrap "$@"
