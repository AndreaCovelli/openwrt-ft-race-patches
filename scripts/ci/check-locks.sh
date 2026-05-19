#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_nonempty() {
  local lock="$1"
  local var="$2"
  [[ -n "${!var:-}" ]] || die "$lock: missing required variable $var"
}

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# shellcheck source=scripts/lib/build-name.sh
source "$repo_root/scripts/lib/build-name.sh"

mapfile -t locks < <(git ls-files 'locks/*.lock' | sort)
((${#locks[@]} > 0)) || die 'no lock files found'

required_vars=(
  OPENWRT_REPO_URL
  OPENWRT_REF
  FEED_PACKAGES_URL
  FEED_PACKAGES_REF
  FEED_LUCI_URL
  FEED_LUCI_REF
  FEED_ROUTING_URL
  FEED_ROUTING_REF
  FEED_TELEPHONY_URL
  FEED_TELEPHONY_REF
  FEED_VIDEO_URL
  FEED_VIDEO_REF
  PATCH_SOURCE
  PATCH_DEST
  PATCH_SHA256
  CONFIG_FRAGMENT
  WORLD_SOURCE
  REFERENCE_MANIFEST
  TARGET
  SUBTARGET
  DEVICE_ID
  ARTIFACT_VARIANT
)

for lock in "${locks[@]}"; do
  (
    sourced_build_name=''
    parsed_build_name=''

    unset "${required_vars[@]}"
    unset OPENWRT_TAG

    # shellcheck source=/dev/null
    source "$lock"

    for var in "${required_vars[@]}"; do
      require_nonempty "$lock" "$var"
    done

    [[ "$OPENWRT_REF" =~ ^[0-9a-f]{40}$ ]] ||
      die "$lock: OPENWRT_REF must be a full 40-character hex commit"
    [[ "$FEED_PACKAGES_REF" =~ ^[0-9a-f]{40}$ ]] ||
      die "$lock: FEED_PACKAGES_REF must be a full 40-character hex commit"
    [[ "$FEED_LUCI_REF" =~ ^[0-9a-f]{40}$ ]] ||
      die "$lock: FEED_LUCI_REF must be a full 40-character hex commit"
    [[ "$FEED_ROUTING_REF" =~ ^[0-9a-f]{40}$ ]] ||
      die "$lock: FEED_ROUTING_REF must be a full 40-character hex commit"
    [[ "$FEED_TELEPHONY_REF" =~ ^[0-9a-f]{40}$ ]] ||
      die "$lock: FEED_TELEPHONY_REF must be a full 40-character hex commit"
    [[ "$FEED_VIDEO_REF" =~ ^[0-9a-f]{40}$ ]] ||
      die "$lock: FEED_VIDEO_REF must be a full 40-character hex commit"
    [[ "$PATCH_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
      die "$lock: PATCH_SHA256 must be a 64-character lowercase hex checksum"

    sourced_build_name="$(openwrt_default_build_name '20260519T143000Z')" ||
      die "$lock: cannot generate convention-compliant build artifact name"
    parsed_build_name="$(openwrt_default_build_name_from_lock "$lock" '20260519T143000Z')" ||
      die "$lock: cannot generate convention-compliant build artifact name from literal lock fields"
    [[ "$parsed_build_name" == "$sourced_build_name" ]] ||
      die "$lock: sourced and parsed build artifact names differ"

    [[ -f "$PATCH_SOURCE" ]] ||
      die "$lock: PATCH_SOURCE does not exist: $PATCH_SOURCE"
    [[ -f "$CONFIG_FRAGMENT" ]] ||
      die "$lock: CONFIG_FRAGMENT does not exist: $CONFIG_FRAGMENT"
    [[ -f "$WORLD_SOURCE" ]] ||
      die "$lock: WORLD_SOURCE does not exist: $WORLD_SOURCE"
    [[ -f "$REFERENCE_MANIFEST" ]] ||
      die "$lock: REFERENCE_MANIFEST does not exist: $REFERENCE_MANIFEST"

    case "$PATCH_DEST" in
      package/kernel/mac80211/patches/subsys/*.patch) ;;
      *)
        die "$lock: PATCH_DEST must target mac80211 subsys patches: $PATCH_DEST"
        ;;
    esac

    [[ "$(basename "$PATCH_SOURCE")" == "$(basename "$PATCH_DEST")" ]] ||
      die "$lock: PATCH_SOURCE and PATCH_DEST basenames differ"

    actual_sha="$(sha256sum "$PATCH_SOURCE" | awk '{print $1}')"
    [[ "$actual_sha" == "$PATCH_SHA256" ]] ||
      die "$lock: PATCH_SHA256 mismatch for $PATCH_SOURCE: expected $PATCH_SHA256 got $actual_sha"
  )
done
