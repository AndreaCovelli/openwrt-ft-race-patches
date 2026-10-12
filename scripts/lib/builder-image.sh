#!/usr/bin/env bash

# Default prebuilt builder image shared by the local and EC2 wrappers.
# Keep the README reference in sync; scripts/ci/check-builder-image.sh checks it.
# shellcheck disable=SC2034 # Used by the scripts that source this file.
DEFAULT_BUILDER_IMAGE='ghcr.io/andreacovelli/openwrt-ft-race-patches/openwrt-builder:ubuntu-noble-20260410-snapshot-20260410t000000z@sha256:ddd581ad95983400564b019d362b674eb24ecd096ca8cb4fc64cc6f5a86a0ea5'

builder_image_is_digest_pinned() {
  [[ "$1" =~ @sha256:[0-9a-f]{64}$ ]]
}
