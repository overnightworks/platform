# shellcheck shell=bash
# Sourced by scripts/release_bump_compute.sh, scripts/release_bump_component_version.sh, scripts/release_bump_scope.sh,
# scripts/verify_image_release.sh and the cells of tests/release_bump: the one owner of what an app name, a release
# version and an image digest look like, as extended regular expressions without anchors, and of the one suffix a
# variant image's tag adds to its version.
app_name_pattern='[a-z][a-z0-9-]*'
version_pattern='[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+'
digest_pattern='sha256:[0-9a-f]{64}'
# A release may publish a second image, tagged <version>-gpu, from the same commit with the same attestation; both
# belong to the tag v<version>. The suffix is a literal, not a pattern.
APP_IMAGE_VARIANT_SUFFIX="-gpu"
