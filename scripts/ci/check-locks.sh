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

makefile_value() {
  local makefile="$1"
  local name="$2"

  awk -v name="$name" '
    index($0, name ":=") == 1 { print substr($0, length(name) + 3); exit }
  ' "$makefile"
}

# Local feed packages that repackage an APK must name the same file and hash
# as the PREBUILT_APKS entry that seeds DL_DIR, or OpenWrt rejects the source.
validate_prebuilt_apk_sources() {
  local lock="$1"
  local entry name file url sha256 path makefile pkg_source pkg_hash
  local -A apk_hashes=()
  local -A referenced=()

  if declare -p PREBUILT_APKS >/dev/null 2>&1; then
    local -n source_prebuilt_apks=PREBUILT_APKS
    for entry in "${source_prebuilt_apks[@]}"; do
      parse_prebuilt_apk "$lock" "$entry" name file url sha256
      apk_hashes["$file"]="$sha256"
    done
  fi

  if declare -p LOCAL_FEEDS >/dev/null 2>&1; then
    local -n source_local_feeds=LOCAL_FEEDS
    for entry in "${source_local_feeds[@]}"; do
      path="${entry#*:}"
      while IFS= read -r -d '' makefile; do
        pkg_source="$(makefile_value "$makefile" PKG_SOURCE)"
        [[ "$pkg_source" == *.apk ]] || continue
        pkg_hash="$(makefile_value "$makefile" PKG_HASH)"
        [[ -n "${apk_hashes[$pkg_source]:-}" ]] ||
          die "$lock: $makefile uses $pkg_source, but PREBUILT_APKS has no entry for it"
        [[ "$pkg_hash" == "${apk_hashes[$pkg_source]}" ]] ||
          die "$lock: $makefile PKG_HASH differs from PREBUILT_APKS for $pkg_source"
        referenced["$pkg_source"]=1
      done < <(find "$path" -name Makefile -type f -print0)
    done
  fi

  for file in "${!apk_hashes[@]}"; do
    [[ -n "${referenced[$file]:-}" ]] ||
      die "$lock: PREBUILT_APKS file is not a PKG_SOURCE in any local feed: $file"
  done
}

validate_extra_patch_dest() {
  local lock="$1"
  local dest="$2"

  case "$dest" in
    package/kernel/mac80211/patches/subsys/*.patch) ;;
    *)
      die "$lock: extra patch destination must target mac80211 subsys patches: $dest"
      ;;
  esac
}

validate_patch_checksum() {
  local lock="$1"
  local source="$2"
  local sha256="$3"
  local var_name="$4"
  local actual_sha

  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] ||
    die "$lock: $var_name must be a 64-character lowercase hex checksum"
  actual_sha="$(sha256sum "$source" | awk '{print $1}')"
  [[ "$actual_sha" == "$sha256" ]] ||
    die "$lock: $var_name mismatch for $source: expected $sha256 got $actual_sha"
}

validate_extra_patches() {
  local lock="$1"
  local i

  if ! declare -p EXTRA_PATCH_SOURCES >/dev/null 2>&1 &&
    ! declare -p EXTRA_PATCH_DESTS >/dev/null 2>&1 &&
    ! declare -p EXTRA_PATCH_SHA256S >/dev/null 2>&1; then
    return 0
  fi

  declare -p EXTRA_PATCH_SOURCES >/dev/null 2>&1 ||
    die "$lock: EXTRA_PATCH_DESTS and EXTRA_PATCH_SHA256S require EXTRA_PATCH_SOURCES"
  declare -p EXTRA_PATCH_DESTS >/dev/null 2>&1 ||
    die "$lock: EXTRA_PATCH_SOURCES and EXTRA_PATCH_SHA256S require EXTRA_PATCH_DESTS"
  declare -p EXTRA_PATCH_SHA256S >/dev/null 2>&1 ||
    die "$lock: EXTRA_PATCH_SOURCES and EXTRA_PATCH_DESTS require EXTRA_PATCH_SHA256S"

  local -n extra_patch_sources=EXTRA_PATCH_SOURCES
  local -n extra_patch_dests=EXTRA_PATCH_DESTS
  local -n extra_patch_sha256s=EXTRA_PATCH_SHA256S

  ((${#extra_patch_sources[@]} == ${#extra_patch_dests[@]})) ||
    die "$lock: EXTRA_PATCH_SOURCES and EXTRA_PATCH_DESTS must have the same length"
  ((${#extra_patch_sources[@]} == ${#extra_patch_sha256s[@]})) ||
    die "$lock: EXTRA_PATCH_SOURCES and EXTRA_PATCH_SHA256S must have the same length"

  for i in "${!extra_patch_sources[@]}"; do
    [[ -f "${extra_patch_sources[$i]}" ]] ||
      die "$lock: EXTRA_PATCH_SOURCES[$i] does not exist: ${extra_patch_sources[$i]}"
    validate_extra_patch_dest "$lock" "${extra_patch_dests[$i]}"
    [[ "$(basename "${extra_patch_sources[$i]}")" == "$(basename "${extra_patch_dests[$i]}")" ]] ||
      die "$lock: EXTRA_PATCH_SOURCES[$i] and EXTRA_PATCH_DESTS[$i] basenames differ"
    validate_patch_checksum "$lock" "${extra_patch_sources[$i]}" "${extra_patch_sha256s[$i]}" "EXTRA_PATCH_SHA256S[$i]"
  done
}

validate_local_feeds() {
  local lock="$1"
  local entry name path digest package actual expected_config config_line found
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
      declare -p EXTRA_CONFIG_LINES >/dev/null 2>&1 ||
        die "$lock: LOCAL_FEEDS requires EXTRA_CONFIG_LINES"
      expected_config="CONFIG_FEED_${name}=m"
      found=0
      local -n extra_config_lines=EXTRA_CONFIG_LINES
      for config_line in "${extra_config_lines[@]}"; do
        if [[ "$config_line" == "$expected_config" ]]; then
          found=1
          break
        fi
      done
      ((found == 1)) ||
        die "$lock: local feed $name must be build-only via $expected_config"
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

# SDK and ImageBuilder pins are all-or-nothing and must name the official
# archives of the lock's release, target, and subtarget.
validate_imagebuilder_pins() {
  local lock="$1"
  local name count=0 version release_path parsed_method entry url sha256 package install found
  local prebuilt_name file
  local -A seen_urls=()
  local -a pin_vars=(SDK_URL SDK_SHA256 IMAGEBUILDER_URL IMAGEBUILDER_SHA256)
  local -a pin_arrays=(IMAGEBUILDER_REPOSITORIES IMAGEBUILDER_PATCHED_PACKAGES)

  parsed_method="$(openwrt_default_build_method_from_lock "$lock")" ||
    die "$lock: cannot parse DEFAULT_BUILD_METHOD"
  [[ "${DEFAULT_BUILD_METHOD:-source}" == "$parsed_method" ]] ||
    die "$lock: sourced and parsed DEFAULT_BUILD_METHOD differ"

  for name in "${pin_vars[@]}"; do
    [[ -z "${!name:-}" ]] || count=$((count + 1))
  done
  for name in "${pin_arrays[@]}"; do
    ! declare -p "$name" >/dev/null 2>&1 || count=$((count + 1))
  done
  if ((count == 0)); then
    [[ "$parsed_method" == 'source' ]] ||
      die "$lock: DEFAULT_BUILD_METHOD=imagebuilder requires SDK and ImageBuilder pins"
    return 0
  fi
  ((count == ${#pin_vars[@]} + ${#pin_arrays[@]})) ||
    die "$lock: set all of ${pin_vars[*]} ${pin_arrays[*]} or none of them"

  [[ "${OPENWRT_TAG:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] ||
    die "$lock: ImageBuilder pins require a release OPENWRT_TAG"
  version="${OPENWRT_TAG#v}"
  release_path="/releases/$version/targets/$TARGET/$SUBTARGET"

  [[ "$SDK_URL" == https://*"$release_path/openwrt-sdk-$version-$TARGET-${SUBTARGET}_"*.Linux-x86_64.tar.zst ]] ||
    die "$lock: SDK_URL must be the https $version $TARGET/$SUBTARGET SDK archive: $SDK_URL"
  [[ "$IMAGEBUILDER_URL" == https://*"$release_path/openwrt-imagebuilder-$version-$TARGET-$SUBTARGET.Linux-x86_64.tar.zst" ]] ||
    die "$lock: IMAGEBUILDER_URL must be the https $version $TARGET/$SUBTARGET ImageBuilder archive: $IMAGEBUILDER_URL"
  [[ "$SDK_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    die "$lock: SDK_SHA256 must be a 64-character lowercase hex checksum"
  [[ "$IMAGEBUILDER_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    die "$lock: IMAGEBUILDER_SHA256 must be a 64-character lowercase hex checksum"

  ((${#IMAGEBUILDER_REPOSITORIES[@]} > 0)) || die "$lock: IMAGEBUILDER_REPOSITORIES must not be empty"
  for entry in "${IMAGEBUILDER_REPOSITORIES[@]}"; do
    imagebuilder_parse_repository "$entry" url sha256 ||
      die "$lock: invalid IMAGEBUILDER_REPOSITORIES entry"
    [[ "$url" == *"/releases/$version/"* ]] ||
      die "$lock: IMAGEBUILDER_REPOSITORIES URL is not for release $version: $url"
    [[ -z "${seen_urls[$url]:-}" ]] ||
      die "$lock: duplicate IMAGEBUILDER_REPOSITORIES URL: $url"
    seen_urls[$url]=1
  done

  ((${#IMAGEBUILDER_PATCHED_PACKAGES[@]} > 0)) || die "$lock: IMAGEBUILDER_PATCHED_PACKAGES must not be empty"
  for package in "${IMAGEBUILDER_PATCHED_PACKAGES[@]}"; do
    [[ "$package" =~ ^[a-z0-9][a-z0-9+._-]*$ ]] ||
      die "$lock: IMAGEBUILDER_PATCHED_PACKAGES entry has unsupported characters: $package"
  done

  # ImageBuilder builds inject prebuilt APKs instead of building local feeds.
  if declare -p LOCAL_FEED_INSTALLS >/dev/null 2>&1; then
    for install in "${LOCAL_FEED_INSTALLS[@]}"; do
      package="${install#*:}"
      found=0
      if declare -p PREBUILT_APKS >/dev/null 2>&1; then
        for entry in "${PREBUILT_APKS[@]}"; do
          parse_prebuilt_apk "$lock" "$entry" prebuilt_name file url sha256
          [[ "$prebuilt_name" != "$package" ]] || found=1
        done
      fi
      ((found == 1)) ||
        die "$lock: ImageBuilder pins need a PREBUILT_APKS entry for local feed package $package"
    done
  fi
}

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# shellcheck source=scripts/lib/build-name.sh
source "$repo_root/scripts/lib/build-name.sh"
# shellcheck source=scripts/lib/local-feeds.sh
source "$repo_root/scripts/lib/local-feeds.sh"
# shellcheck source=scripts/lib/imagebuilder.sh
source "$repo_root/scripts/lib/imagebuilder.sh"

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
    unset EXTRA_CONFIG_LINES
    unset EXTRA_PATCH_SOURCES EXTRA_PATCH_DESTS EXTRA_PATCH_SHA256S
    unset DEFAULT_BUILD_METHOD SDK_URL SDK_SHA256 IMAGEBUILDER_URL IMAGEBUILDER_SHA256
    unset IMAGEBUILDER_REPOSITORIES IMAGEBUILDER_PATCHED_PACKAGES

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

    validate_patch_checksum "$lock" "$PATCH_SOURCE" "$PATCH_SHA256" 'PATCH_SHA256'
    validate_extra_patches "$lock"

    validate_local_feeds "$lock"
    validate_prebuilt_apks "$lock"
    validate_prebuilt_apk_sources "$lock"
    validate_imagebuilder_pins "$lock"
  )
done
