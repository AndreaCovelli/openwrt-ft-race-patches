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

parse_prebuilt_apk() {
  local lock="$1"
  local entry="$2"
  local -n out_name="$3"
  local -n out_file="$4"
  local -n out_url="$5"
  local -n out_sha256="$6"

  IFS='|' read -r out_name out_file out_url out_sha256 <<<"$entry"
  [[ -n "$out_name" && -n "$out_file" && -n "$out_url" && -n "$out_sha256" ]] ||
    die "$lock: PREBUILT_APKS entries must use name|filename|url|sha256 format"
}

validate_prebuilt_apks() {
  local lock="$1"
  local entry name file url sha256

  if ! declare -p PREBUILT_APKS >/dev/null 2>&1; then
    return 0
  fi

  local -n prebuilt_apks=PREBUILT_APKS
  for entry in "${prebuilt_apks[@]}"; do
    parse_prebuilt_apk "$lock" "$entry" name file url sha256
    [[ "$name" =~ ^[A-Za-z0-9_.+-]+$ ]] ||
      die "$lock: PREBUILT_APKS name has unsupported characters: $name"
    [[ "$file" =~ ^[A-Za-z0-9_.+-]+\.apk$ ]] ||
      die "$lock: PREBUILT_APKS filename must be a plain .apk basename: $file"
    [[ "$url" == https://* ]] ||
      die "$lock: PREBUILT_APKS URL must use https: $url"
    [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] ||
      die "$lock: PREBUILT_APKS sha256 for $name must be a 64-character lowercase hex checksum"
  done
}

validate_local_feeds() {
  local lock="$1"
  local entry name path digest package actual
  local -A feed_names=()
  local -A feed_digests=()

  if declare -p LOCAL_FEED_SHA256S >/dev/null 2>&1; then
    local -n local_feed_sha256s=LOCAL_FEED_SHA256S
    for entry in "${local_feed_sha256s[@]}"; do
      name="${entry%%:*}"
      digest="${entry#*:}"
      [[ -n "$name" && -n "$digest" && "$name" != "$entry" ]] ||
        die "$lock: LOCAL_FEED_SHA256S entries must use name:sha256 format"
      [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] ||
        die "$lock: local feed name has unsupported characters: $name"
      [[ "$digest" =~ ^[0-9a-f]{64}$ ]] ||
        die "$lock: LOCAL_FEED_SHA256S digest for $name must be a 64-character lowercase hex checksum"
      feed_digests["$name"]="$digest"
    done
  fi

  if declare -p LOCAL_FEEDS >/dev/null 2>&1; then
    local -n local_feeds=LOCAL_FEEDS
    for entry in "${local_feeds[@]}"; do
      name="${entry%%:*}"
      path="${entry#*:}"
      [[ -n "$name" && -n "$path" && "$name" != "$entry" ]] ||
        die "$lock: LOCAL_FEEDS entries must use name:path format"
      [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] ||
        die "$lock: local feed name has unsupported characters: $name"
      case "$path" in
        /*|../*|*/../*)
          die "$lock: LOCAL_FEEDS path must stay inside the repo: $path"
          ;;
      esac
      [[ -d "$path" ]] ||
        die "$lock: LOCAL_FEEDS path does not exist: $path"
      [[ -n "${feed_digests[$name]:-}" ]] ||
        die "$lock: LOCAL_FEED_SHA256S is missing digest for local feed: $name"
      actual="$(local_feed_digest "$path")"
      [[ "$actual" == "${feed_digests[$name]}" ]] ||
        die "$lock: local feed checksum mismatch for $name: expected ${feed_digests[$name]} got $actual"
      feed_names["$name"]=1
    done
  elif declare -p LOCAL_FEED_INSTALLS >/dev/null 2>&1; then
    die "$lock: LOCAL_FEED_INSTALLS requires LOCAL_FEEDS"
  fi

  if declare -p LOCAL_FEED_INSTALLS >/dev/null 2>&1; then
    local -n local_feed_installs=LOCAL_FEED_INSTALLS
    for entry in "${local_feed_installs[@]}"; do
      name="${entry%%:*}"
      package="${entry#*:}"
      [[ -n "$name" && -n "$package" && "$name" != "$entry" ]] ||
        die "$lock: LOCAL_FEED_INSTALLS entries must use feed:package format"
      [[ -n "${feed_names[$name]:-}" ]] ||
        die "$lock: LOCAL_FEED_INSTALLS references unknown local feed: $name"
      [[ "$package" =~ ^[A-Za-z0-9_.+-]+$ ]] ||
        die "$lock: LOCAL_FEED_INSTALLS package has unsupported characters: $package"
    done
  fi
}

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# shellcheck source=scripts/lib/build-name.sh
source "$repo_root/scripts/lib/build-name.sh"
# shellcheck source=scripts/lib/local-feeds.sh
source "$repo_root/scripts/lib/local-feeds.sh"

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
    unset OPENWRT_TAG LOCAL_FEEDS LOCAL_FEED_INSTALLS LOCAL_FEED_SHA256S PREBUILT_APKS

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

    validate_local_feeds "$lock"
    validate_prebuilt_apks "$lock"
  )
done
