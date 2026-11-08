# shellcheck shell=bash
# Sourced by the scripts under tests/.
fail() { echo "::error::$1"; exit 1; }
