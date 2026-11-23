# shellcheck shell=bash
# Sourced by scripts/release_bump_compute.sh and scripts/release_bump_scope.sh: the one owner of what an app name, a
# release version and an image digest look like, as extended regular expressions without anchors.
app_name_pattern='[a-z][a-z0-9-]*'
version_pattern='[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+'
digest_pattern='sha256:[0-9a-f]{64}'
