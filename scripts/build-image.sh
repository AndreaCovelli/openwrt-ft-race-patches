#!/usr/bin/env bash
set -euo pipefail

umask 022
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/build-name.sh
source "$SCRIPT_DIR/lib/build-name.sh"
# shellcheck source=scripts/lib/imagebuilder.sh
source "$SCRIPT_DIR/lib/imagebuilder.sh"
# shellcheck source=scripts/lib/local-feeds.sh
source "$SCRIPT_DIR/lib/local-feeds.sh"
# shellcheck source=scripts/lib/prebuilt-apks.sh
source "$SCRIPT_DIR/lib/prebuilt-apks.sh"
# shellcheck source=scripts/lib/world-config.sh
source "$SCRIPT_DIR/lib/world-config.sh"

usage() {
  cat <<EOF
Usage:
  ${BASH_SOURCE[0]} [options] [lock-file]

Options:
  --session NAME            Current run and artifact identity.
  --workspace NAME          Reusable workspace identity. Default:
                            openwrt-ft-<device-id>-dev for source builds and
                            openwrt-ft-<device-id>-ib for ImageBuilder builds.
  --builder-id ID           Builder image identity. Required.
  --build-method METHOD     source builds OpenWrt from source; imagebuilder
                            compiles the patched packages with the pinned
                            official SDK and assembles the image with the
                            pinned official ImageBuilder. Default: the lock's
                            DEFAULT_BUILD_METHOD, or source.
  --fresh                   Clear the exact workspace and run a full build.
  --rebuild-package NAME    Force an incremental package rebuild. Repeatable;
                            NAME is mac80211, local-feeds, or all.
                            ImageBuilder builds accept mac80211 or all.
  --help                    Show this message.

Environment equivalents are BUILD_ID, WORKSPACE_ID, BUILDER_ID, BUILD_METHOD,
FRESH, and REBUILD_PACKAGES (a comma- or space-separated selector list).
WORKSPACE_PATH optionally names a fixed mount point of the same workspace, so
compiler caches see identical paths across workspaces.
EOF
}

BUILD_ID_ARG=''
WORKSPACE_ID_ARG=''
BUILDER_ID_ARG=''
BUILD_METHOD_ARG=''
FRESH_ARG=''
REBUILD_PACKAGE_ARGS=()
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      [[ $# -ge 2 ]] || {
        printf 'error: --session requires a value\n' >&2
        exit 1
      }
      BUILD_ID_ARG="$2"
      shift 2
      ;;
    --workspace)
      [[ $# -ge 2 ]] || {
        printf 'error: --workspace requires a value\n' >&2
        exit 1
      }
      WORKSPACE_ID_ARG="$2"
      shift 2
      ;;
    --builder-id)
      [[ $# -ge 2 ]] || {
        printf 'error: --builder-id requires a value\n' >&2
        exit 1
      }
      BUILDER_ID_ARG="$2"
      shift 2
      ;;
    --build-method)
      [[ $# -ge 2 ]] || {
        printf 'error: --build-method requires a value\n' >&2
        exit 1
      }
      BUILD_METHOD_ARG="$2"
      shift 2
      ;;
    --fresh)
      FRESH_ARG='1'
      shift
      ;;
    --rebuild-package)
      [[ $# -ge 2 ]] || {
        printf 'error: --rebuild-package requires a value\n' >&2
        exit 1
      }
      REBUILD_PACKAGE_ARGS+=("$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        POSITIONAL+=("$1")
        shift
      done
      ;;
    -*)
      printf 'error: unknown option: %s\n' "$1" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if ((${#POSITIONAL[@]} > 1)); then
  usage >&2
  exit 1
fi

if ((${#POSITIONAL[@]} == 1)); then
  LOCK_FILE="${POSITIONAL[0]}"
else
  LOCK_FILE="${LOCK_FILE:-}"
fi

if [[ -z "$LOCK_FILE" ]]; then
  printf 'error: set LOCK_FILE or pass a lock file path\n' >&2
  exit 1
fi

if [[ "$LOCK_FILE" != /* ]]; then
  LOCK_FILE="$REPO_ROOT/$LOCK_FILE"
fi

if [[ ! -f "$LOCK_FILE" ]]; then
  printf 'error: lock file not found: %s\n' "$LOCK_FILE" >&2
  exit 1
fi

unset OPENWRT_TAG OPENWRT_REF DEVICE_ID ARTIFACT_VARIANT
unset EXTRA_PATCH_SOURCES EXTRA_PATCH_DESTS EXTRA_PATCH_SHA256S
unset DEFAULT_BUILD_METHOD SDK_URL SDK_SHA256 IMAGEBUILDER_URL IMAGEBUILDER_SHA256
unset IMAGEBUILDER_REPOSITORIES IMAGEBUILDER_PATCHED_PACKAGES

# shellcheck source=/dev/null
source "$LOCK_FILE"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

abs_path() {
  if [[ "$1" = /* ]]; then
    printf '%s\n' "$1"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$1"
  fi
}

verify_sha256() {
  local file expected actual
  file="$1"
  expected="$2"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "sha256 mismatch for $file: expected $expected got $actual"
}

configure_pinned_patches() {
  local i

  PINNED_PATCH_SOURCES=("$PATCH_SOURCE")
  PINNED_PATCH_SOURCE_ABS=("$PATCH_SOURCE_ABS")
  PINNED_PATCH_DESTS=("$PATCH_DEST")
  PINNED_PATCH_SHA256S=("$PATCH_SHA256")

  if ! declare -p EXTRA_PATCH_SOURCES >/dev/null 2>&1 &&
    ! declare -p EXTRA_PATCH_DESTS >/dev/null 2>&1 &&
    ! declare -p EXTRA_PATCH_SHA256S >/dev/null 2>&1; then
    return 0
  fi

  declare -p EXTRA_PATCH_SOURCES >/dev/null 2>&1 ||
    die 'EXTRA_PATCH_DESTS and EXTRA_PATCH_SHA256S require EXTRA_PATCH_SOURCES'
  declare -p EXTRA_PATCH_DESTS >/dev/null 2>&1 ||
    die 'EXTRA_PATCH_SOURCES and EXTRA_PATCH_SHA256S require EXTRA_PATCH_DESTS'
  declare -p EXTRA_PATCH_SHA256S >/dev/null 2>&1 ||
    die 'EXTRA_PATCH_SOURCES and EXTRA_PATCH_DESTS require EXTRA_PATCH_SHA256S'

  local -n extra_patch_sources=EXTRA_PATCH_SOURCES
  local -n extra_patch_dests=EXTRA_PATCH_DESTS
  local -n extra_patch_sha256s=EXTRA_PATCH_SHA256S

  ((${#extra_patch_sources[@]} == ${#extra_patch_dests[@]})) ||
    die 'EXTRA_PATCH_SOURCES and EXTRA_PATCH_DESTS must have the same length'
  ((${#extra_patch_sources[@]} == ${#extra_patch_sha256s[@]})) ||
    die 'EXTRA_PATCH_SOURCES and EXTRA_PATCH_SHA256S must have the same length'

  for i in "${!extra_patch_sources[@]}"; do
    [[ -n "${extra_patch_sources[$i]}" ]] || die "EXTRA_PATCH_SOURCES[$i] is empty"
    [[ -n "${extra_patch_dests[$i]}" ]] || die "EXTRA_PATCH_DESTS[$i] is empty"
    [[ -n "${extra_patch_sha256s[$i]}" ]] || die "EXTRA_PATCH_SHA256S[$i] is empty"
    PINNED_PATCH_SOURCES+=("${extra_patch_sources[$i]}")
    PINNED_PATCH_SOURCE_ABS+=("$(abs_path "${extra_patch_sources[$i]}")")
    PINNED_PATCH_DESTS+=("${extra_patch_dests[$i]}")
    PINNED_PATCH_SHA256S+=("${extra_patch_sha256s[$i]}")
  done
}

verify_pinned_patch_files() {
  local i

  for i in "${!PINNED_PATCH_SOURCE_ABS[@]}"; do
    [[ -f "${PINNED_PATCH_SOURCE_ABS[$i]}" ]] ||
      die "patch file not found: ${PINNED_PATCH_SOURCE_ABS[$i]}"
  done
}

verify_pinned_patch_hashes() {
  local i

  for i in "${!PINNED_PATCH_SOURCE_ABS[@]}"; do
    verify_sha256 "${PINNED_PATCH_SOURCE_ABS[$i]}" "${PINNED_PATCH_SHA256S[$i]}"
  done
}

apply_pinned_patches() {
  local i source_abs dest sha256 target

  for i in "${!PINNED_PATCH_SOURCE_ABS[@]}"; do
    source_abs="${PINNED_PATCH_SOURCE_ABS[$i]}"
    dest="${PINNED_PATCH_DESTS[$i]}"
    sha256="${PINNED_PATCH_SHA256S[$i]}"
    log "Applying pinned patch: $dest"
    verify_sha256 "$source_abs" "$sha256"
    # OpenWrt includes patch mtimes in its package preparation stamps.
    target="$(patch_destination_path "$dest")"
    if ! cmp -s "$source_abs" "$target"; then
      install -D -m 0644 "$source_abs" "$target"
    fi
  done
}

write_patch_metadata() {
  local i

  for i in "${!PINNED_PATCH_SOURCES[@]}"; do
    printf '%s\t%s\t%s\n' \
      "${PINNED_PATCH_SOURCES[$i]}" \
      "${PINNED_PATCH_DESTS[$i]}" \
      "${PINNED_PATCH_SHA256S[$i]}"
  done
}

copy_pinned_patch_metadata() {
  local source_abs

  for source_abs in "${PINNED_PATCH_SOURCE_ABS[@]}"; do
    cp "$source_abs" "$METADATA_DIR/$(basename "$source_abs")"
  done
}

verify_checkout() {
  local repo expected actual
  repo="$1"
  expected="$2"
  actual="$(git -C "$repo" rev-parse HEAD)"
  [[ "$actual" == "$expected" ]] || die "unexpected revision for $repo: expected $expected got $actual"
}

verify_not_shallow() {
  local repo is_shallow
  repo="$1"
  is_shallow="$(git -C "$repo" rev-parse --is-shallow-repository)"
  [[ "$is_shallow" == 'false' ]] || die "repository is shallow: $repo"
}

verify_tracked_files_clean() {
  local repo path allowed_path is_allowed
  local -a allowed_paths=("${@:2}")
  local -a changed_paths=()
  repo="$1"

  mapfile -d '' -t changed_paths < <(git -C "$repo" diff --name-only -z HEAD --)
  for path in "${changed_paths[@]}"; do
    is_allowed=0
    for allowed_path in "${allowed_paths[@]}"; do
      if [[ "$path" == "$allowed_path" ]]; then
        is_allowed=1
        break
      fi
    done
    ((is_allowed)) ||
      die "tracked files are modified in workspace checkout: $repo/$path; rerun with --fresh"
  done
}

download_prebuilt_apks() {
  local entry name file url sha256

  if ! declare -p PREBUILT_APKS >/dev/null 2>&1; then
    return 0
  fi

  local -n prebuilt_apks=PREBUILT_APKS
  for entry in "${prebuilt_apks[@]}"; do
    prebuilt_apk_parse_entry "$entry" name file url sha256
    log "Downloading prebuilt APK: $name"
    prebuilt_apk_download_one "$DL_DIR" "$entry"
  done
}

local_feed_expected_digest() {
  local feed_name="$1"
  local entry name digest

  if ! declare -p LOCAL_FEED_SHA256S >/dev/null 2>&1; then
    return 1
  fi

  local -n local_feed_sha256s=LOCAL_FEED_SHA256S
  for entry in "${local_feed_sha256s[@]}"; do
    name="${entry%%:*}"
    digest="${entry#*:}"
    if [[ "$name" == "$feed_name" && "$digest" != "$entry" ]]; then
      printf '%s\n' "$digest"
      return 0
    fi
  done

  return 1
}

verify_local_feed_digests() {
  local entry name path abs_feed_path expected actual

  if ! declare -p LOCAL_FEEDS >/dev/null 2>&1; then
    return 0
  fi

  local -n local_feeds=LOCAL_FEEDS
  for entry in "${local_feeds[@]}"; do
    name="${entry%%:*}"
    path="${entry#*:}"
    [[ -n "$name" && -n "$path" && "$name" != "$entry" ]] ||
      die "LOCAL_FEEDS entries must use name:path format"
    expected="$(local_feed_expected_digest "$name")" ||
      die "LOCAL_FEED_SHA256S is missing digest for local feed: $name"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
      die "LOCAL_FEED_SHA256S digest for $name must be a 64-character lowercase hex checksum"
    abs_feed_path="$(abs_path "$path")"
    [[ -d "$abs_feed_path" ]] || die "local feed not found: $abs_feed_path"
    actual="$(local_feed_digest "$abs_feed_path")"
    [[ "$actual" == "$expected" ]] ||
      die "local feed checksum mismatch for $name: expected $expected got $actual"
  done
}

write_local_feeds_conf() {
  local entry name path abs_feed_path

  if ! declare -p LOCAL_FEEDS >/dev/null 2>&1; then
    return 0
  fi

  local -n local_feeds=LOCAL_FEEDS
  for entry in "${local_feeds[@]}"; do
    name="${entry%%:*}"
    path="${entry#*:}"
    [[ -n "$name" && -n "$path" && "$name" != "$entry" ]] ||
      die "LOCAL_FEEDS entries must use name:path format"
    abs_feed_path="$(abs_path "$path")"
    [[ -d "$abs_feed_path" ]] || die "local feed not found: $abs_feed_path"
    printf 'src-link %s %s\n' "$name" "$abs_feed_path"
  done
}

write_feeds_conf() {
  cat >"$OPENWRT_DIR/feeds.conf" <<EOF
$(write_local_feeds_conf)
src-git-full packages ${FEED_PACKAGES_URL}^${FEED_PACKAGES_REF}
src-git-full luci ${FEED_LUCI_URL}^${FEED_LUCI_REF}
src-git-full routing ${FEED_ROUTING_URL}^${FEED_ROUTING_REF}
src-git-full telephony ${FEED_TELEPHONY_URL}^${FEED_TELEPHONY_REF}
src-git-full video ${FEED_VIDEO_URL}^${FEED_VIDEO_REF}
EOF
}

install_local_feed_packages() {
  local entry feed package

  if ! declare -p LOCAL_FEED_INSTALLS >/dev/null 2>&1; then
    return 0
  fi

  local -n local_feed_installs=LOCAL_FEED_INSTALLS
  for entry in "${local_feed_installs[@]}"; do
    feed="${entry%%:*}"
    package="${entry#*:}"
    [[ -n "$feed" && -n "$package" && "$feed" != "$entry" ]] ||
      die "LOCAL_FEED_INSTALLS entries must use feed:package format"
    (
      cd "$OPENWRT_DIR"
      ./scripts/feeds install -f -p "$feed" "$package"
    )
  done
}

append_extra_config() {
  local line
  for line in "${EXTRA_CONFIG_LINES[@]}"; do
    printf '%s\n' "$line" >>"$OPENWRT_DIR/.config"
  done
}

write_build_options_config() {
  {
    # BUILD_LOG keeps per-package compiler output in logs/ for diagnosis.
    printf 'CONFIG_DEVEL=y\n'
    printf 'CONFIG_BUILD_LOG=y\n'
    if [[ "$USE_CCACHE_MODE" == '1' ]]; then
      printf 'CONFIG_CCACHE=y\n'
      printf 'CONFIG_CCACHE_DIR="%s"\n' "$CCACHE_DIR"
    else
      printf '# CONFIG_CCACHE is not set\n'
    fi
  } >>"$OPENWRT_DIR/.config"
}

toolchain_config_digest() {
  awk '/^CONFIG_(GCC|BINUTILS|LIBC|USE_|EXTERNAL_|TOOLCHAIN|TARGET_OPTIMIZATION|TARGET_SUFFIX|CPU_TYPE|ARCH|TARGET_ARCH)/' \
    "$OPENWRT_DIR/.config" | sha256sum | awk '{print $1}'
}

configure_ccache_environment() {
  [[ "$USE_CCACHE_MODE" == '1' ]] || return 0

  # A fresh tree rebuilds the cross-compiler, so ccache's default mtime check
  # misses every target object. The pinned OpenWrt tree, builder image, and
  # toolchain configuration determine the compilers instead. The SDK ships a
  # prebuilt toolchain identified by the SDK archive checksum.
  local toolchain_digest
  if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
    export CCACHE_COMPILERCHECK="string:sdk=$SDK_SHA256;builder=$BUILDER_ID"
  else
    toolchain_digest="$(toolchain_config_digest)"
    export CCACHE_COMPILERCHECK="string:openwrt=$OPENWRT_REF;builder=$BUILDER_ID;toolchain=$toolchain_digest"
  fi
  # Debug-info objects otherwise hash the workspace path.
  export CCACHE_NOHASHDIR=1
  log "ccache compiler check: $CCACHE_COMPILERCHECK"
}

extract_world() {
  awk 'found { print } /^__WORLD__$/ { found=1 }' "$WORLD_SOURCE_ABS"
}

parse_manifest() {
  awk -F ' - ' 'NF >= 2 { print $1 "\t" $2 }' "$1"
}

count_lines() {
  local file
  file="$1"
  wc -l <"$file" | tr -d ' '
}

write_manifest_builtin_package_names() {
  local package

  if ! declare -p MANIFEST_BUILTIN_PACKAGE_NAMES >/dev/null 2>&1; then
    return 0
  fi

  local -n builtin_packages=MANIFEST_BUILTIN_PACKAGE_NAMES
  for package in "${builtin_packages[@]}"; do
    [[ -n "$package" ]] && printf '%s\n' "$package"
  done
}

write_local_feed_digests() {
  local entry name path abs_feed_path

  if ! declare -p LOCAL_FEEDS >/dev/null 2>&1; then
    return 0
  fi

  local -n local_feeds=LOCAL_FEEDS
  for entry in "${local_feeds[@]}"; do
    name="${entry%%:*}"
    path="${entry#*:}"
    abs_feed_path="$(abs_path "$path")"
    printf '%s\t%s\t%s\n' "$name" "$path" "$(local_feed_digest "$abs_feed_path")"
  done
}

write_prebuilt_apk_digests() {
  local entry name file url sha256

  if ! declare -p PREBUILT_APKS >/dev/null 2>&1; then
    return 0
  fi

  local -n prebuilt_apks=PREBUILT_APKS
  for entry in "${prebuilt_apks[@]}"; do
    prebuilt_apk_parse_entry "$entry" name file url sha256
    printf '%s\t%s\t%s\t%s\n' "$name" "$file" "$url" "$sha256"
  done
}

state_entry() {
  local key="$1"
  local value="${2-}"

  [[ "$key" != *$'\t'* && "$key" != *$'\n'* ]] ||
    die "workspace state key contains unsupported characters: $key"
  [[ "$value" != *$'\t'* && "$value" != *$'\n'* ]] ||
    die "workspace state value for $key contains a tab or newline"
  printf '%s\t%s\n' "$key" "$value"
}

# The SDK and ImageBuilder use the official release config, so only source
# builds consume the device config inputs and local feeds.
write_source_compatibility_entries() {
  local i index entry name path

  state_entry config_fragment.path "$CONFIG_FRAGMENT"
  state_entry config_fragment.sha256 "$(sha256sum "$CONFIG_FRAGMENT_ABS" | awk '{print $1}')"

  if declare -p EXTRA_CONFIG_LINES >/dev/null 2>&1; then
    local -n extra_config_lines=EXTRA_CONFIG_LINES
    for i in "${!extra_config_lines[@]}"; do
      printf -v index '%03d' "$i"
      state_entry "extra_config.$index" "${extra_config_lines[$i]}"
    done
  fi

  if declare -p LOCAL_FEEDS >/dev/null 2>&1; then
    local -n local_feeds=LOCAL_FEEDS
    for i in "${!local_feeds[@]}"; do
      entry="${local_feeds[$i]}"
      name="${entry%%:*}"
      path="${entry#*:}"
      printf -v index '%03d' "$i"
      state_entry "local_feed.$index.name" "$name"
      state_entry "local_feed.$index.path" "$path"
    done
  fi

  if declare -p LOCAL_FEED_INSTALLS >/dev/null 2>&1; then
    local -n local_feed_installs=LOCAL_FEED_INSTALLS
    for i in "${!local_feed_installs[@]}"; do
      printf -v index '%03d' "$i"
      state_entry "local_feed_install.$index" "${local_feed_installs[$i]}"
    done
  fi
}

write_imagebuilder_compatibility_entries() {
  local i index

  state_entry imagebuilder.sha256 "$IMAGEBUILDER_SHA256"
  state_entry imagebuilder.url "$IMAGEBUILDER_URL"
  state_entry sdk.sha256 "$SDK_SHA256"
  state_entry sdk.url "$SDK_URL"
  for i in "${!IMAGEBUILDER_PATCHED_PACKAGES[@]}"; do
    printf -v index '%03d' "$i"
    state_entry "imagebuilder.patched_package.$index" "${IMAGEBUILDER_PATCHED_PACKAGES[$i]}"
  done
}

write_compatibility_manifest() {
  local i index name file url sha256

  {
    state_entry build_method "$BUILD_METHOD"
    state_entry builder_id "$BUILDER_ID"
    state_entry builder_platform "${BUILDER_PLATFORM:-unknown}"
    state_entry ccache "$USE_CCACHE_MODE"
    state_entry device_id "$DEVICE_ID"
    state_entry feed.luci.ref "$FEED_LUCI_REF"
    state_entry feed.luci.url "$FEED_LUCI_URL"
    state_entry feed.packages.ref "$FEED_PACKAGES_REF"
    state_entry feed.packages.url "$FEED_PACKAGES_URL"
    state_entry feed.routing.ref "$FEED_ROUTING_REF"
    state_entry feed.routing.url "$FEED_ROUTING_URL"
    state_entry feed.telephony.ref "$FEED_TELEPHONY_REF"
    state_entry feed.telephony.url "$FEED_TELEPHONY_URL"
    state_entry feed.video.ref "$FEED_VIDEO_REF"
    state_entry feed.video.url "$FEED_VIDEO_URL"
    state_entry openwrt.ref "$OPENWRT_REF"
    state_entry openwrt.repo_url "$OPENWRT_REPO_URL"
    state_entry openwrt.tag "${OPENWRT_TAG:-}"
    state_entry state_schema "$WORKSPACE_STATE_SCHEMA"
    state_entry subtarget "$SUBTARGET"
    state_entry target "$TARGET"
    state_entry workspace_path "$BUILD_ROOT"
    state_entry world_source.path "$WORLD_SOURCE"
    state_entry world_source.sha256 "$(sha256sum "$WORLD_SOURCE_ABS" | awk '{print $1}')"

    for i in "${!PINNED_PATCH_SOURCES[@]}"; do
      printf -v index '%03d' "$i"
      state_entry "patch.$index.source" "${PINNED_PATCH_SOURCES[$i]}"
      state_entry "patch.$index.destination" "${PINNED_PATCH_DESTS[$i]}"
    done

    if declare -p PREBUILT_APKS >/dev/null 2>&1; then
      local -n prebuilt_apks=PREBUILT_APKS
      for i in "${!prebuilt_apks[@]}"; do
        prebuilt_apk_parse_entry "${prebuilt_apks[$i]}" name file url sha256 ||
          die 'invalid PREBUILT_APKS entry'
        printf -v index '%03d' "$i"
        state_entry "prebuilt_apk.$index.name" "$name"
      done
    fi

    if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
      write_imagebuilder_compatibility_entries
    else
      write_source_compatibility_entries
    fi
  } | sort
}

# Content digests that can change without replacing the workspace. A changed
# value selects a targeted package rebuild instead of a fresh build.
write_build_state() {
  local i index entry name expected

  state_entry final_config_sha256 "$(sha256sum "$BUILD_CONFIG_FILE" | awk '{print $1}')"
  for i in "${!PINNED_PATCH_SHA256S[@]}"; do
    printf -v index '%03d' "$i"
    state_entry "patch.$index.sha256" "${PINNED_PATCH_SHA256S[$i]}"
  done

  if declare -p LOCAL_FEEDS >/dev/null 2>&1; then
    local -n state_local_feeds=LOCAL_FEEDS
    for i in "${!state_local_feeds[@]}"; do
      entry="${state_local_feeds[$i]}"
      name="${entry%%:*}"
      expected="$(local_feed_expected_digest "$name")" ||
        die "LOCAL_FEED_SHA256S is missing digest for local feed: $name"
      printf -v index '%03d' "$i"
      state_entry "local_feed.$index.sha256" "$expected"
    done
  fi

  if declare -p PREBUILT_APKS >/dev/null 2>&1; then
    local -n state_prebuilt_apks=PREBUILT_APKS
    for i in "${!state_prebuilt_apks[@]}"; do
      printf -v index '%03d' "$i"
      state_entry "prebuilt_apk.$index" "${state_prebuilt_apks[$i]}"
    done
  fi

  if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
    for i in "${!IMAGEBUILDER_REPOSITORIES[@]}"; do
      printf -v index '%03d' "$i"
      state_entry "imagebuilder.repository.$index" "${IMAGEBUILDER_REPOSITORIES[$i]}"
    done
  fi
  state_entry state_schema "$WORKSPACE_STATE_SCHEMA"
}

state_value() {
  local file="$1"
  local wanted_key="$2"

  awk -F '\t' -v wanted_key="$wanted_key" '
    $1 == wanted_key {
      sub(/^[^\t]*\t/, "")
      print
      found=1
      exit
    }
    END {
      if (!found)
        exit 1
    }
  ' "$file"
}

report_compatibility_mismatches() {
  local stored_file="$1"
  local current_file="$2"

  awk -F '\t' '
    NR == FNR {
      stored[$1]=$2
      next
    }
    {
      current[$1]=$2
    }
    END {
      for (key in stored) {
        if (!(key in current))
          printf "  %s: stored=%s current=<missing>\n", key, stored[key]
        else if (stored[key] != current[key])
          printf "  %s: stored=%s current=%s\n", key, stored[key], current[key]
      }
      for (key in current)
        if (!(key in stored))
          printf "  %s: stored=<missing> current=%s\n", key, current[key]
    }
  ' "$stored_file" "$current_file" | sort
}

patch_package_for_destination() {
  case "$1" in
    package/kernel/mac80211/*)
      printf 'mac80211\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# Absolute path that receives a pinned patch. The SDK installs OpenWrt's
# package/ tree as its base feed.
patch_destination_path() {
  local dest="$1"

  if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
    printf '%s/feeds/base/%s\n' "$SDK_DIR" "${dest#package/}"
  else
    printf '%s/%s\n' "$OPENWRT_DIR" "$dest"
  fi
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

# Download URL to DEST unless DEST already has the expected checksum. A
# mismatch fails closed; HINT explains how to refresh the pin.
fetch_verified_file() {
  local url="$1"
  local dest="$2"
  local expected="$3"
  local hint="${4:-}"
  local tmp actual

  if [[ -f "$dest" ]] && [[ "$(sha256_of "$dest")" == "$expected" ]]; then
    return 0
  fi

  mkdir -p "$(dirname -- "$dest")"
  tmp="$(mktemp "$dest.tmp.XXXXXXXX")"
  if ! curl -fsSL \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 10 \
    --max-time 1800 \
    --retry 3 \
    --retry-connrefused \
    -o "$tmp" \
    "$url"; then
    rm -f -- "$tmp"
    die "failed to download $url"
  fi

  actual="$(sha256_of "$tmp")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f -- "$tmp"
    die "sha256 mismatch for $url: expected $expected got $actual${hint:+; $hint}"
  fi
  mv -f -- "$tmp" "$dest"
}

imagebuilder_validate_lock() {
  local name value entry url sha256 dest install package prebuilt_entry
  local prebuilt_name file found

  [[ -n "${OPENWRT_TAG:-}" ]] || die 'ImageBuilder builds require OPENWRT_TAG'
  for name in SDK_URL IMAGEBUILDER_URL; do
    value="${!name:-}"
    [[ "$value" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/+-]+\.tar\.zst$ ]] ||
      die "$name must be an https .tar.zst URL for ImageBuilder builds"
  done
  for name in SDK_SHA256 IMAGEBUILDER_SHA256; do
    value="${!name:-}"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] ||
      die "$name must be a 64-character lowercase hex checksum for ImageBuilder builds"
  done

  declare -p IMAGEBUILDER_REPOSITORIES >/dev/null 2>&1 ||
    die 'ImageBuilder builds require IMAGEBUILDER_REPOSITORIES'
  ((${#IMAGEBUILDER_REPOSITORIES[@]} > 0)) || die 'IMAGEBUILDER_REPOSITORIES must not be empty'
  for entry in "${IMAGEBUILDER_REPOSITORIES[@]}"; do
    imagebuilder_parse_repository "$entry" url sha256 || die 'invalid IMAGEBUILDER_REPOSITORIES entry'
  done

  declare -p IMAGEBUILDER_PATCHED_PACKAGES >/dev/null 2>&1 ||
    die 'ImageBuilder builds require IMAGEBUILDER_PATCHED_PACKAGES'
  ((${#IMAGEBUILDER_PATCHED_PACKAGES[@]} > 0)) || die 'IMAGEBUILDER_PATCHED_PACKAGES must not be empty'
  for package in "${IMAGEBUILDER_PATCHED_PACKAGES[@]}"; do
    [[ "$package" =~ ^[a-z0-9][a-z0-9+._-]*$ ]] ||
      die "unsupported IMAGEBUILDER_PATCHED_PACKAGES entry: $package"
  done

  for dest in "${PINNED_PATCH_DESTS[@]}"; do
    patch_package_for_destination "$dest" >/dev/null ||
      die "ImageBuilder builds can only rebuild mac80211 patches: $dest; use --build-method source"
  done

  # Local feeds only repackage prebuilt APKs, which ImageBuilder builds inject
  # directly. Anything else needs the full source tree.
  if declare -p LOCAL_FEED_INSTALLS >/dev/null 2>&1; then
    for install in "${LOCAL_FEED_INSTALLS[@]}"; do
      package="${install#*:}"
      found=0
      if declare -p PREBUILT_APKS >/dev/null 2>&1; then
        for prebuilt_entry in "${PREBUILT_APKS[@]}"; do
          prebuilt_apk_parse_entry "$prebuilt_entry" prebuilt_name file url sha256 ||
            die 'invalid PREBUILT_APKS entry'
          if [[ "$prebuilt_name" == "$package" ]]; then
            found=1
            break
          fi
        done
      fi
      ((found)) ||
        die "local feed package $package has no PREBUILT_APKS entry; use --build-method source"
    done
  fi
}

# Source packages that own the pinned patches, in first-use order.
sdk_source_packages() {
  local dest package
  local -A seen=()

  for dest in "${PINNED_PATCH_DESTS[@]}"; do
    package="$(patch_package_for_destination "$dest")" || return 1
    [[ -z "${seen[$package]:-}" ]] || continue
    seen[$package]=1
    printf '%s\n' "$package"
  done
}

expected_sdk_feeds() {
  printf 'src-git --root=package base %s^%s\n' "$OPENWRT_REPO_URL" "$OPENWRT_REF"
  printf 'src-git packages %s^%s\n' "$FEED_PACKAGES_URL" "$FEED_PACKAGES_REF"
  printf 'src-git luci %s^%s\n' "$FEED_LUCI_URL" "$FEED_LUCI_REF"
  printf 'src-git routing %s^%s\n' "$FEED_ROUTING_URL" "$FEED_ROUTING_REF"
  printf 'src-git telephony %s^%s\n' "$FEED_TELEPHONY_URL" "$FEED_TELEPHONY_REF"
  printf 'src-git video %s^%s\n' "$FEED_VIDEO_URL" "$FEED_VIDEO_REF"
}

# The official SDK records the exact OpenWrt and feed commits of its release.
# They must equal the lock pins so the lock describes what is shipped.
verify_sdk_feeds() {
  local expected actual

  expected="$(expected_sdk_feeds)"
  actual="$(grep -Ev '^[[:space:]]*(#|$)' "$SDK_DIR/feeds.conf.default")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected SDK feeds:\n%s\nactual SDK feeds:\n%s\n' "$expected" "$actual" >&2
    die 'SDK feeds.conf.default does not match the lock OpenWrt and feed pins'
  fi
}

extract_pinned_archive() {
  local archive="$1"
  local dest="$2"

  [[ ! -e "$dest" ]] || die "refusing to extract over an existing path: $dest"
  mkdir -p "$dest"
  tar --zstd -xf "$archive" -C "$dest" --strip-components=1 --no-same-owner
}

prepare_sdk() {
  local archive package

  archive="$DL_DIR/$(basename -- "$SDK_URL")"
  log "Fetching pinned OpenWrt SDK"
  fetch_verified_file "$SDK_URL" "$archive" "$SDK_SHA256"
  log "Extracting OpenWrt SDK"
  extract_pinned_archive "$archive" "$SDK_DIR"
  verify_sdk_feeds

  log "Writing pinned SDK base feed definition"
  expected_sdk_feeds | head -n1 >"$SDK_DIR/feeds.conf"
  (
    cd "$SDK_DIR"
    ./scripts/feeds update base
  )
  verify_checkout "$SDK_DIR/feeds/base_root" "$OPENWRT_REF"

  for package in "${SDK_SOURCE_PACKAGES[@]}"; do
    log "Installing SDK package: $package"
    (
      cd "$SDK_DIR"
      ./scripts/feeds install "$package"
    )
  done
  apply_pinned_patches

  # The SDK's Config-build.in carries the release package selection, so
  # defconfig selects the same packages and options as the release build.
  log "Writing SDK config"
  (
    cd "$SDK_DIR"
    make defconfig
  )
  for package in "${IMAGEBUILDER_PATCHED_PACKAGES[@]}"; do
    grep -Eqx "CONFIG_PACKAGE_$package=[my]" "$SDK_DIR/.config" ||
      die "SDK config does not select patched package $package"
  done
}

sdk_package_options() {
  grep -E '^(# )?CONFIG_PACKAGE_(MAC80211|CFG80211)_[A-Z0-9_]+( is not set|=)' "$1" | LC_ALL=C sort
}

# The ImageBuilder .config is the release build config. The SDK must build
# the patched package with the same package options, or the patched module
# would not match the official modules it is loaded with.
verify_sdk_package_options() {
  local expected actual

  expected="$(sdk_package_options "$IB_DIR/.config")" ||
    die 'ImageBuilder config has no mac80211 package options'
  actual="$(sdk_package_options "$SDK_DIR/.config")" ||
    die 'SDK config has no mac80211 package options'
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected mac80211 package options:\n%s\nactual SDK options:\n%s\n' "$expected" "$actual" >&2
    die 'SDK mac80211 package options differ from the release ImageBuilder config'
  fi
}

prepare_imagebuilder() {
  local archive

  archive="$DL_DIR/$(basename -- "$IMAGEBUILDER_URL")"
  log "Fetching pinned OpenWrt ImageBuilder"
  fetch_verified_file "$IMAGEBUILDER_URL" "$archive" "$IMAGEBUILDER_SHA256"
  log "Extracting OpenWrt ImageBuilder"
  extract_pinned_archive "$archive" "$IB_DIR"
  [[ -d "$IB_DIR/packages" ]] || die "ImageBuilder has no packages directory: $IB_DIR"
  # Every image starts from the shipped package directory plus this run's
  # injected packages.
  mv -- "$IB_DIR/packages" "$IB_PRISTINE_PACKAGES_DIR"
}

verify_imagebuilder_tree() {
  local expected actual entry url sha256

  grep -Fqx 'CONFIG_SIGNATURE_CHECK=y' "$IB_DIR/.config" ||
    die 'ImageBuilder does not enforce repository signatures'

  expected="$(
    for entry in "${IMAGEBUILDER_REPOSITORIES[@]}"; do
      imagebuilder_parse_repository "$entry" url sha256
      printf '%s\n' "$url"
    done
  )"
  actual="$(grep -Ev '^[[:space:]]*(#|$)' "$IB_DIR/repositories")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected ImageBuilder repositories:\n%s\nactual ImageBuilder repositories:\n%s\n' \
      "$expected" "$actual" >&2
    die 'ImageBuilder repositories do not match IMAGEBUILDER_REPOSITORIES'
  fi
}

# Fetch every pinned repository index into a content-addressed store. Release
# indexes are rebuilt upstream, so a changed index fails closed until the
# lock is refreshed with scripts/pin-imagebuilder.sh.
fetch_imagebuilder_indexes() {
  local entry url sha256

  for entry in "${IMAGEBUILDER_REPOSITORIES[@]}"; do
    imagebuilder_parse_repository "$entry" url sha256 || die 'invalid IMAGEBUILDER_REPOSITORIES entry'
    fetch_verified_file "$url" "$IB_INDEX_STORE/$sha256.adb" "$sha256" \
      'the upstream index changed; refresh the lock with scripts/pin-imagebuilder.sh'
  done
}

# apk reuses a cached index younger than its cache age, so freshly seeded
# pinned indexes are what it resolves and verifies packages against.
seed_imagebuilder_apk_cache() {
  local entry url sha256 name tmp

  mkdir -p "$IB_APK_CACHE"
  for entry in "${IMAGEBUILDER_REPOSITORIES[@]}"; do
    imagebuilder_parse_repository "$entry" url sha256 || die 'invalid IMAGEBUILDER_REPOSITORIES entry'
    name="$(imagebuilder_index_cache_name "$url")"
    tmp="$(mktemp "$IB_APK_CACHE/.$name.XXXXXXXX")"
    cp -- "$IB_INDEX_STORE/$sha256.adb" "$tmp"
    verify_sha256 "$tmp" "$sha256"
    mv -f -- "$tmp" "$IB_APK_CACHE/$name"
  done

  if [[ -e "$IB_DIR/dl" && ! -L "$IB_DIR/dl" ]]; then
    rm -rf -- "$IB_DIR/dl"
  fi
  ln -sfn -- "$IB_APK_CACHE" "$IB_DIR/dl"
}

verify_imagebuilder_apk_cache() {
  local entry url sha256 name

  for entry in "${IMAGEBUILDER_REPOSITORIES[@]}"; do
    imagebuilder_parse_repository "$entry" url sha256 || die 'invalid IMAGEBUILDER_REPOSITORIES entry'
    name="$(imagebuilder_index_cache_name "$url")"
    [[ -f "$IB_APK_CACHE/$name" && "$(sha256_of "$IB_APK_CACHE/$name")" == "$sha256" ]] ||
      die "pinned repository index changed during the image build: $url"
  done
}

compile_sdk_packages() {
  local package
  local -a make_args=(NO_DEPS=1 DL_DIR="$DL_DIR" CONFIG_BUILD_LOG=y)

  # CONFIG_CCACHE has no prompt in the SDK, so pass it to make directly.
  if [[ "$USE_CCACHE_MODE" == '1' ]]; then
    make_args+=(CONFIG_CCACHE=y CONFIG_CCACHE_DIR="$CCACHE_DIR")
  fi

  # Package the SDK's prebuilt kernel modules first. Packaging checks each
  # module's dependencies against the files its dependency packages provide,
  # and backports drivers depend on kernel kmods such as kmod-usb-core. Only
  # IMAGEBUILDER_PATCHED_PACKAGES reach the image.
  log "Packaging SDK kernel modules"
  (
    cd "$SDK_DIR"
    make -j"$MAKE_JOBS" "${make_args[@]}" package/linux/compile
  )

  for package in "${SDK_SOURCE_PACKAGES[@]}"; do
    if [[ "$BUILD_MODE" != 'full' && -n "${REBUILD_PACKAGES_SET[$package]:-}" ]]; then
      log "Cleaning SDK package: $package"
      (
        cd "$SDK_DIR"
        make "${make_args[@]}" "package/$package/clean"
      )
    fi
    log "Compiling SDK package: $package"
    (
      cd "$SDK_DIR"
      make -j"$MAKE_JOBS" "${make_args[@]}" "package/$package/compile"
    )
  done
}

# Rebuild the ImageBuilder package directory from the shipped packages, the
# SDK-built patched packages, and the pinned prebuilt APKs.
assemble_imagebuilder_packages() {
  local package apk entry name file url sha256

  rm -rf -- "$IB_DIR/packages"
  cp -a -- "$IB_PRISTINE_PACKAGES_DIR" "$IB_DIR/packages"
  : >"$REPORT_DIR/imagebuilder-injected.tsv"

  for package in "${IMAGEBUILDER_PATCHED_PACKAGES[@]}"; do
    apk="$(imagebuilder_find_package_apk "$SDK_PACKAGE_DIR" "$package")" ||
      die "SDK did not build patched package: $package"
    [[ ! -e "$IB_DIR/packages/$(basename -- "$apk")" ]] ||
      die "patched package collides with a shipped ImageBuilder package: $(basename -- "$apk")"
    cp -- "$apk" "$IB_DIR/packages/"
    printf 'sdk\t%s\t%s\t%s\n' "$package" "$(basename -- "$apk")" "$(sha256_of "$apk")" \
      >>"$REPORT_DIR/imagebuilder-injected.tsv"
  done

  if declare -p PREBUILT_APKS >/dev/null 2>&1; then
    for entry in "${PREBUILT_APKS[@]}"; do
      prebuilt_apk_parse_entry "$entry" name file url sha256 || die 'invalid PREBUILT_APKS entry'
      verify_sha256 "$DL_DIR/$file" "$sha256"
      [[ ! -e "$IB_DIR/packages/$file" ]] ||
        die "prebuilt APK collides with an ImageBuilder package: $file"
      cp -- "$DL_DIR/$file" "$IB_DIR/packages/"
      printf 'prebuilt\t%s\t%s\t%s\n' "$name" "$file" "$sha256" \
        >>"$REPORT_DIR/imagebuilder-injected.tsv"
    done
  fi
}

build_imagebuilder_image() {
  local info="$REPORT_DIR/imagebuilder-info.txt"
  local packages

  (
    cd "$IB_DIR"
    make -s info
  ) >"$info"
  imagebuilder_info_profile_packages "$info" "$DEVICE_ID" >/dev/null ||
    die "ImageBuilder has no profile for $DEVICE_ID"

  log "Resolving apk world package selections"
  world_config_resolve "$IB_DIR/.packageinfo" \
    "$REPORT_DIR/reference.world" "$REPORT_DIR/builtin-package-names.txt" \
    | sort -u >"$REPORT_DIR/world-config.tsv"
  # The captured world replaces the default package selection, so drop
  # defaults the world neither lists nor provides.
  {
    awk -F '\t' '$2 != "-" { print $1 }' "$REPORT_DIR/world-config.tsv"
    imagebuilder_default_removals "$info" "$DEVICE_ID" \
      "$IB_DIR/.packageinfo" "$REPORT_DIR/world-config.tsv" ||
      die 'failed to resolve ImageBuilder default package removals'
  } >"$REPORT_DIR/imagebuilder-packages.txt"
  packages="$(paste -sd ' ' "$REPORT_DIR/imagebuilder-packages.txt")"

  rm -rf -- "$IB_BIN_DIR"
  log "Assembling image with ImageBuilder"
  (
    cd "$IB_DIR"
    make image PROFILE="$DEVICE_ID" PACKAGES="$packages" BIN_DIR="$IB_BIN_DIR"
  )
}

# Each injected package must be what landed in the image; apk could
# otherwise satisfy a name with the equally versioned official package.
verify_injected_packages() {
  local rootfs kind name file sha256 extract_dir path count
  local -a roots=()

  mapfile -t roots < <(find "$IB_DIR/build_dir" -mindepth 2 -maxdepth 2 -type d -name "root-$TARGET")
  ((${#roots[@]} == 1)) || die "expected one ImageBuilder rootfs, found ${#roots[@]}"
  rootfs="${roots[0]}"

  : >"$REPORT_DIR/imagebuilder-injected-files.tsv"
  while IFS=$'\t' read -r kind name file sha256; do
    extract_dir="$(mktemp -d "$BUILD_ROOT/.openwrt-ft-extract.XXXXXXXX")"
    "$IB_DIR/staging_dir/host/bin/apk" extract --allow-untrusted --no-chown \
      --destination "$extract_dir" "$IB_DIR/packages/$file" >/dev/null
    count=0
    while IFS= read -r -d '' path; do
      path="${path#./}"
      if ! cmp -s -- "$extract_dir/$path" "$rootfs/$path"; then
        rm -rf -- "$extract_dir"
        die "image does not contain the injected $kind package file for $name: /$path"
      fi
      count=$((count + 1))
    done < <(cd "$extract_dir" && find . -type f -print0)
    rm -rf -- "$extract_dir"
    ((count > 0)) || die "injected package has no files to verify: $name"
    printf '%s\t%s\t%s\n' "$name" "$sha256" "$count" >>"$REPORT_DIR/imagebuilder-injected-files.tsv"
  done <"$REPORT_DIR/imagebuilder-injected.tsv"
}

write_imagebuilder_repositories() {
  local entry url sha256

  for entry in "${IMAGEBUILDER_REPOSITORIES[@]}"; do
    imagebuilder_parse_repository "$entry" url sha256
    printf '%s\t%s\n' "$url" "$sha256"
  done
}

validate_component() {
  local name="$1"
  local value="$2"

  [[ -n "$value" ]] || die "$name must not be empty"
  case "$value" in
    *[!A-Za-z0-9._-]*|.|..)
      die "$name contains unsupported characters: $value"
      ;;
  esac
}

strict_manifest_enabled() {
  case "${STRICT_MANIFEST:-1}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    0|false|FALSE|no|NO|off|OFF)
      return 1
      ;;
    *)
      die "STRICT_MANIFEST must be 1/0, true/false, yes/no, or on/off"
      ;;
  esac
}

if strict_manifest_enabled; then
  STRICT_MANIFEST_MODE=1
else
  STRICT_MANIFEST_MODE=0
fi

ccache_enabled() {
  case "${USE_CCACHE:-0}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    0|false|FALSE|no|NO|off|OFF)
      return 1
      ;;
    *)
      die "USE_CCACHE must be 1/0, true/false, yes/no, or on/off"
      ;;
  esac
}

if ccache_enabled; then
  USE_CCACHE_MODE=1
else
  USE_CCACHE_MODE=0
fi

if [[ -n "$BUILD_METHOD_ARG" ]]; then
  BUILD_METHOD="$BUILD_METHOD_ARG"
else
  BUILD_METHOD="${BUILD_METHOD:-${DEFAULT_BUILD_METHOD:-source}}"
fi
case "$BUILD_METHOD" in
  source|imagebuilder) ;;
  *) die "unsupported build method: $BUILD_METHOD (expected source or imagebuilder)" ;;
esac

require_cmd awk cmp comm cp curl cut find flock git head install join make mkdir mktemp mv nproc paste realpath rm sed sha256sum sort tee xargs
if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
  require_cmd tar zstd
fi

PATCH_SOURCE_ABS="$(abs_path "$PATCH_SOURCE")"
CONFIG_FRAGMENT_ABS="$(abs_path "$CONFIG_FRAGMENT")"
WORLD_SOURCE_ABS="$(abs_path "$WORLD_SOURCE")"
REFERENCE_MANIFEST_ABS="$(abs_path "$REFERENCE_MANIFEST")"

configure_pinned_patches
verify_pinned_patch_files
verify_pinned_patch_hashes
[[ -f "$CONFIG_FRAGMENT_ABS" ]] || die "config fragment not found: $CONFIG_FRAGMENT_ABS"
[[ -f "$WORLD_SOURCE_ABS" ]] || die "world source not found: $WORLD_SOURCE_ABS"
[[ -f "$REFERENCE_MANIFEST_ABS" ]] || die "reference manifest not found: $REFERENCE_MANIFEST_ABS"
verify_local_feed_digests
if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
  imagebuilder_validate_lock
  mapfile -t SDK_SOURCE_PACKAGES < <(sdk_source_packages)
fi

if [[ -n "$BUILD_ID_ARG" ]]; then
  BUILD_ID="$BUILD_ID_ARG"
else
  BUILD_ID="${BUILD_ID:-$(openwrt_default_build_name)}"
fi
if [[ -n "$WORKSPACE_ID_ARG" ]]; then
  WORKSPACE_ID="$WORKSPACE_ID_ARG"
else
  WORKSPACE_ID="${WORKSPACE_ID:-$(openwrt_default_workspace_name "$BUILD_METHOD")}"
fi
if [[ -n "$BUILDER_ID_ARG" ]]; then
  BUILDER_ID="$BUILDER_ID_ARG"
else
  BUILDER_ID="${BUILDER_ID:-}"
fi
if [[ -n "$FRESH_ARG" ]]; then
  FRESH_MODE="$FRESH_ARG"
else
  FRESH_MODE="${FRESH:-0}"
fi

validate_component BUILD_ID "$BUILD_ID"
validate_component WORKSPACE_ID "$WORKSPACE_ID"
[[ -n "$BUILDER_ID" ]] || die 'set BUILDER_ID or pass --builder-id'
[[ "$BUILDER_ID" != *$'\t'* && "$BUILDER_ID" != *$'\n'* ]] ||
  die 'BUILDER_ID must not contain tabs or newlines'
case "$FRESH_MODE" in
  1|true|TRUE|yes|YES|on|ON)
    FRESH_MODE=1
    ;;
  0|false|FALSE|no|NO|off|OFF)
    FRESH_MODE=0
    ;;
  *)
    die 'FRESH must be 1/0, true/false, yes/no, or on/off'
    ;;
esac

declare -A REQUESTED_REBUILDS=()
if [[ -n "${REBUILD_PACKAGES:-}" ]]; then
  read -r -a rebuild_package_env_args <<<"${REBUILD_PACKAGES//,/ }"
  REBUILD_PACKAGE_ARGS+=("${rebuild_package_env_args[@]}")
fi
LOCAL_FEED_PACKAGE_PATHS=()
if declare -p LOCAL_FEED_INSTALLS >/dev/null 2>&1; then
  declare -n lock_local_feed_installs=LOCAL_FEED_INSTALLS
  for entry in "${lock_local_feed_installs[@]}"; do
    LOCAL_FEED_PACKAGE_PATHS+=("package/feeds/${entry%%:*}/${entry#*:}")
  done
  unset -n lock_local_feed_installs
fi

for rebuild_selector in "${REBUILD_PACKAGE_ARGS[@]}"; do
  case "$rebuild_selector" in
    mac80211)
      REQUESTED_REBUILDS[mac80211]=1
      ;;
    local-feeds)
      [[ "$BUILD_METHOD" == 'source' ]] ||
        die 'ImageBuilder builds inject prebuilt APKs directly; local-feeds rebuilds need --build-method source'
      ((${#LOCAL_FEED_PACKAGE_PATHS[@]} > 0)) ||
        die 'local-feeds rebuild requested, but the lock has no LOCAL_FEED_INSTALLS'
      REQUESTED_REBUILDS[local-feeds]=1
      ;;
    all)
      REQUESTED_REBUILDS[mac80211]=1
      if [[ "$BUILD_METHOD" == 'source' ]] && ((${#LOCAL_FEED_PACKAGE_PATHS[@]} > 0)); then
        REQUESTED_REBUILDS[local-feeds]=1
      fi
      ;;
    *)
      die "unsupported rebuild package: $rebuild_selector (expected mac80211, local-feeds, or all)"
      ;;
  esac
done

WORK_ROOT="${WORK_ROOT:-$REPO_ROOT/$DEFAULT_WORK_ROOT}"
CACHE_ROOT="${CACHE_ROOT:-$REPO_ROOT/$DEFAULT_CACHE_ROOT}"
mkdir -p "$WORK_ROOT" "$CACHE_ROOT"
WORK_ROOT="$(realpath -m -- "$WORK_ROOT")"
CACHE_ROOT="$(realpath -m -- "$CACHE_ROOT")"
[[ "$WORK_ROOT" != '/' ]] || die 'WORK_ROOT must not be the filesystem root'
BUILD_ROOT="$WORK_ROOT/$WORKSPACE_ID"
[[ "$(dirname -- "$BUILD_ROOT")" == "$WORK_ROOT" ]] ||
  die "workspace must be a direct child of the work root: $BUILD_ROOT"
[[ ! -L "$BUILD_ROOT" ]] || die "workspace must not be a symbolic link: $BUILD_ROOT"
# Wrappers mount the workspace at one fixed path, so compiler command lines
# and ccache entries are identical across workspaces and devices.
if [[ -n "${WORKSPACE_PATH:-}" ]]; then
  [[ "$WORKSPACE_PATH" == /* ]] || die "WORKSPACE_PATH must be absolute: $WORKSPACE_PATH"
  [[ -d "$WORKSPACE_PATH" && ! -L "$WORKSPACE_PATH" ]] ||
    die "WORKSPACE_PATH must be an existing directory: $WORKSPACE_PATH"
  [[ "$WORKSPACE_PATH" -ef "$BUILD_ROOT" ]] ||
    die "WORKSPACE_PATH must be the mounted workspace $BUILD_ROOT: $WORKSPACE_PATH"
  BUILD_ROOT="$WORKSPACE_PATH"
fi

WORKSPACE_LOCK_DIR="$WORK_ROOT/.openwrt-ft-locks"
[[ ! -L "$WORKSPACE_LOCK_DIR" ]] ||
  die "workspace lock directory must not be a symbolic link: $WORKSPACE_LOCK_DIR"
mkdir -p "$WORKSPACE_LOCK_DIR"
WORKSPACE_LOCK_FILE="$WORKSPACE_LOCK_DIR/$WORKSPACE_ID.lock"
[[ ! -L "$WORKSPACE_LOCK_FILE" ]] ||
  die "workspace lock file must not be a symbolic link: $WORKSPACE_LOCK_FILE"
exec {WORKSPACE_LOCK_FD}>>"$WORKSPACE_LOCK_FILE"
case "${OPENWRT_WORKSPACE_LOCK_HELD:-0}" in
  0)
    flock -n "$WORKSPACE_LOCK_FD" ||
      die "workspace is already locked by another build: $WORKSPACE_ID"
    ;;
  1)
    if flock -n "$WORKSPACE_LOCK_FD"; then
      die 'OPENWRT_WORKSPACE_LOCK_HELD=1 but no outer workspace lock is active'
    fi
    ;;
  *)
    die 'OPENWRT_WORKSPACE_LOCK_HELD must be 0 or 1'
    ;;
esac

if ((FRESH_MODE)) && [[ -e "$BUILD_ROOT" ]]; then
  [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] ||
    die "refusing to replace unsafe workspace path: $BUILD_ROOT"
  # Clear the contents only; the workspace may be a mount point.
  log "Clearing workspace for fresh build: $BUILD_ROOT"
  find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi

OPENWRT_DIR="$BUILD_ROOT/openwrt"
SDK_DIR="$BUILD_ROOT/sdk"
SDK_PACKAGE_DIR="$SDK_DIR/bin/targets/$TARGET/$SUBTARGET/packages"
IB_DIR="$BUILD_ROOT/imagebuilder"
IB_PRISTINE_PACKAGES_DIR="$IB_DIR/packages.pristine"
IB_BIN_DIR="$BUILD_ROOT/imagebuilder-bin"
if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
  BUILD_CONFIG_FILE="$SDK_DIR/.config"
  PACKAGE_LOG_DIR="$SDK_DIR/logs"
else
  BUILD_CONFIG_FILE="$OPENWRT_DIR/.config"
  PACKAGE_LOG_DIR="$OPENWRT_DIR/logs"
fi
REPORT_DIR="$BUILD_ROOT/reports"
OUTPUT_DIR="$BUILD_ROOT/output"
METADATA_DIR="$OUTPUT_DIR/metadata"
LOG_DIR="$OUTPUT_DIR/logs"
BUILD_LOG="$LOG_DIR/build.log"
OPENWRT_LOG_OUTPUT_DIR="$LOG_DIR/openwrt"
# Schema 3 added the build method and the fixed workspace path.
WORKSPACE_STATE_SCHEMA='3'
STATE_DIR="$BUILD_ROOT/.openwrt-ft-state"
COMPATIBILITY_FILE="$STATE_DIR/compatibility.tsv"
# prepared.tsv is written once a full build has fixed its inputs; a failed
# full build can then resume instead of being replaced.
PREPARED_FILE="$STATE_DIR/prepared.tsv"
SUCCESS_FILE="$STATE_DIR/last-success.tsv"

if [[ -e "$BUILD_ROOT" ]]; then
  [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] ||
    die "workspace path is not a safe directory: $BUILD_ROOT"
fi
# An empty directory is a workspace mount point awaiting its first build.
if [[ -e "$BUILD_ROOT" && -n "$(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  if [[ -f "$SUCCESS_FILE" ]]; then
    BUILD_MODE='incremental'
    REFERENCE_STATE_FILE="$SUCCESS_FILE"
  elif [[ -f "$PREPARED_FILE" ]]; then
    BUILD_MODE='resume'
    REFERENCE_STATE_FILE="$PREPARED_FILE"
  else
    die "workspace has no compatible state marker: $BUILD_ROOT; rerun with --fresh"
  fi
else
  BUILD_MODE='full'
fi

MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-$DEFAULT_DOWNLOAD_JOBS}"

export DL_DIR="${DL_DIR:-$CACHE_ROOT/dl}"
if [[ "$USE_CCACHE_MODE" == '1' ]]; then
  command -v ccache >/dev/null 2>&1 ||
    die 'USE_CCACHE=1 requires ccache in the builder image'
  export CCACHE_DIR="${CCACHE_DIR:-$CACHE_ROOT/ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
fi

IB_INDEX_STORE="$CACHE_ROOT/imagebuilder/indexes"
if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
  # Builds with the same index pins share one apk package cache.
  IB_PIN_SET="$(printf '%s\n' "${IMAGEBUILDER_REPOSITORIES[@]}" | sha256sum | cut -c1-16)"
  IB_APK_CACHE="$CACHE_ROOT/imagebuilder/apk-cache/$IB_PIN_SET"
fi

declare -A REBUILD_PACKAGES_SET=()
REBUILT_PACKAGES=()

verify_source_workspace() {
  local tag_ref

  [[ -d "$OPENWRT_DIR/.git" && -f "$OPENWRT_DIR/.config" ]] ||
    die "workspace checkout is incomplete: $BUILD_ROOT; rerun with --fresh"
  verify_checkout "$OPENWRT_DIR" "$OPENWRT_REF"
  verify_not_shallow "$OPENWRT_DIR"
  verify_tracked_files_clean "$OPENWRT_DIR" "${PINNED_PATCH_DESTS[@]}"
  verify_checkout "$OPENWRT_DIR/feeds/packages" "$FEED_PACKAGES_REF"
  verify_checkout "$OPENWRT_DIR/feeds/luci" "$FEED_LUCI_REF"
  verify_checkout "$OPENWRT_DIR/feeds/routing" "$FEED_ROUTING_REF"
  verify_checkout "$OPENWRT_DIR/feeds/telephony" "$FEED_TELEPHONY_REF"
  verify_checkout "$OPENWRT_DIR/feeds/video" "$FEED_VIDEO_REF"
  verify_not_shallow "$OPENWRT_DIR/feeds/packages"
  verify_not_shallow "$OPENWRT_DIR/feeds/luci"
  verify_not_shallow "$OPENWRT_DIR/feeds/routing"
  verify_not_shallow "$OPENWRT_DIR/feeds/telephony"
  verify_not_shallow "$OPENWRT_DIR/feeds/video"
  verify_tracked_files_clean "$OPENWRT_DIR/feeds/packages"
  verify_tracked_files_clean "$OPENWRT_DIR/feeds/luci"
  verify_tracked_files_clean "$OPENWRT_DIR/feeds/routing"
  verify_tracked_files_clean "$OPENWRT_DIR/feeds/telephony"
  verify_tracked_files_clean "$OPENWRT_DIR/feeds/video"

  if [[ -n "${OPENWRT_TAG:-}" ]]; then
    tag_ref="$(git -C "$OPENWRT_DIR" rev-list -n1 "$OPENWRT_TAG")"
    [[ "$tag_ref" == "$OPENWRT_REF" ]] ||
      die "tag $OPENWRT_TAG does not resolve to $OPENWRT_REF"
  fi
}

verify_imagebuilder_workspace() {
  [[ -f "$SDK_DIR/.config" && -d "$SDK_DIR/feeds/base_root/.git" &&
    -f "$IB_DIR/Makefile" && -d "$IB_PRISTINE_PACKAGES_DIR" ]] ||
    die "workspace SDK or ImageBuilder is incomplete: $BUILD_ROOT; rerun with --fresh"
  verify_sdk_feeds
  verify_checkout "$SDK_DIR/feeds/base_root" "$OPENWRT_REF"
  # The base feed root is OpenWrt's top level, so patch destinations are
  # also its repository paths.
  verify_tracked_files_clean "$SDK_DIR/feeds/base_root" "${PINNED_PATCH_DESTS[@]}"
}

if [[ "$BUILD_MODE" != 'full' ]]; then
  [[ -f "$COMPATIBILITY_FILE" ]] ||
    die "workspace has no compatible state marker: $BUILD_ROOT; rerun with --fresh"

  current_compatibility="$(mktemp "$WORK_ROOT/.openwrt-ft-compatibility.XXXXXXXX")"
  write_compatibility_manifest >"$current_compatibility"
  if ! cmp -s "$COMPATIBILITY_FILE" "$current_compatibility"; then
    printf 'error: workspace is incompatible; differing compatibility keys:\n' >&2
    report_compatibility_mismatches "$COMPATIBILITY_FILE" "$current_compatibility" >&2
    rm -f -- "$current_compatibility"
    die 'rerun with --fresh to replace the workspace'
  fi
  rm -f -- "$current_compatibility"

  stored_schema="$(state_value "$REFERENCE_STATE_FILE" state_schema)" ||
    die "workspace build state is missing state_schema: $REFERENCE_STATE_FILE; rerun with --fresh"
  [[ "$stored_schema" == "$WORKSPACE_STATE_SCHEMA" ]] ||
    die "workspace build state schema is $stored_schema, expected $WORKSPACE_STATE_SCHEMA; rerun with --fresh"

  if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
    verify_imagebuilder_workspace
  else
    verify_source_workspace
  fi

  stored_config_sha="$(state_value "$REFERENCE_STATE_FILE" final_config_sha256)" ||
    die "workspace build state is missing final_config_sha256; rerun with --fresh"
  verify_sha256 "$BUILD_CONFIG_FILE" "$stored_config_sha"

  for i in "${!PINNED_PATCH_SHA256S[@]}"; do
    printf -v index '%03d' "$i"
    previous_patch_sha="$(state_value "$REFERENCE_STATE_FILE" "patch.$index.sha256")" ||
      die "workspace build state is missing patch.$index.sha256; rerun with --fresh"
    patch_dest_abs="$(patch_destination_path "${PINNED_PATCH_DESTS[$i]}")"
    [[ -f "$patch_dest_abs" ]] ||
      die "workspace patch destination is missing: ${PINNED_PATCH_DESTS[$i]}; rerun with --fresh"
    destination_patch_sha="$(sha256sum "$patch_dest_abs" | awk '{print $1}')"
    if [[ "$destination_patch_sha" != "$previous_patch_sha" &&
      "$destination_patch_sha" != "${PINNED_PATCH_SHA256S[$i]}" ]]; then
      die "workspace patch destination has an unexpected checksum: ${PINNED_PATCH_DESTS[$i]}; rerun with --fresh"
    fi

    if [[ "${PINNED_PATCH_SHA256S[$i]}" != "$previous_patch_sha" ]]; then
      changed_package="$(patch_package_for_destination "${PINNED_PATCH_DESTS[$i]}")" ||
        die "changed patch destination is not incrementally supported: ${PINNED_PATCH_DESTS[$i]}; rerun with --fresh"
      REBUILD_PACKAGES_SET["$changed_package"]=1
    fi
  done

  # ImageBuilder builds reassemble the image from the current prebuilt APKs
  # on every run, so only source builds rebuild local feed packages.
  if [[ "$BUILD_METHOD" == 'source' ]]; then
    current_state="$(mktemp "$WORK_ROOT/.openwrt-ft-state-current.XXXXXXXX")"
    write_build_state >"$current_state"
    changed_local_inputs="$(
      awk -F '\t' '
        NR == FNR { previous[$1] = $2; next }
        $1 ~ /^(local_feed\.[0-9]+\.sha256|prebuilt_apk\.[0-9]+)$/ &&
          (!($1 in previous) || previous[$1] != $2) { print $1 }
      ' "$REFERENCE_STATE_FILE" "$current_state"
    )"
    rm -f -- "$current_state"
    if [[ -n "$changed_local_inputs" ]]; then
      ((${#LOCAL_FEED_PACKAGE_PATHS[@]} > 0)) ||
        die "local feed or prebuilt APK inputs changed without LOCAL_FEED_INSTALLS; rerun with --fresh"
      log "Changed local package inputs: ${changed_local_inputs//$'\n'/, }"
      REBUILD_PACKAGES_SET[local-feeds]=1
    fi
  fi
fi

for rebuild_selector in "${!REQUESTED_REBUILDS[@]}"; do
  REBUILD_PACKAGES_SET["$rebuild_selector"]=1
done
if [[ "$BUILD_MODE" == 'full' ]]; then
  REBUILT_PACKAGES=(all)
else
  for rebuild_selector in mac80211 local-feeds; do
    if [[ -n "${REBUILD_PACKAGES_SET[$rebuild_selector]:-}" ]]; then
      REBUILT_PACKAGES+=("$rebuild_selector")
    fi
  done
fi

if [[ "$BUILD_MODE" != 'full' ]]; then
  rm -rf -- "$REPORT_DIR" "$OUTPUT_DIR" "$PACKAGE_LOG_DIR"
fi
mkdir -p "$BUILD_ROOT" "$DL_DIR" "$REPORT_DIR" "$OUTPUT_DIR" "$METADATA_DIR" "$LOG_DIR"
if [[ "$USE_CCACHE_MODE" == '1' ]]; then
  mkdir -p "$CCACHE_DIR"
  ccache --max-size="$CCACHE_MAXSIZE" >/dev/null
fi
: >"$BUILD_LOG"

write_ccache_stats() {
  local label="$1"

  if [[ "$USE_CCACHE_MODE" != '1' ]]; then
    return 0
  fi

  {
    printf '== %s ==\n' "$label"
    ccache -s || true
  } >>"$REPORT_DIR/ccache-stats.txt"
}

copy_openwrt_logs() {
  [[ -d "${PACKAGE_LOG_DIR:-}" ]] || return 0
  mkdir -p "$OPENWRT_LOG_OUTPUT_DIR" || return 0
  cp -a "$PACKAGE_LOG_DIR/." "$OPENWRT_LOG_OUTPUT_DIR/" || return 0
}

finalize_logs() {
  local status=$?
  set +e
  copy_openwrt_logs
  exit "$status"
}
trap finalize_logs EXIT

# Write the workspace markers once a full build has fixed its inputs.
write_prepared_state() {
  local state_dir_tmp

  state_dir_tmp="$(mktemp -d "$BUILD_ROOT/.openwrt-ft-state.XXXXXXXX")"
  write_compatibility_manifest >"$state_dir_tmp/compatibility.tsv"
  write_build_state >"$state_dir_tmp/prepared.tsv"
  [[ ! -e "$STATE_DIR" ]] ||
    die "workspace state unexpectedly appeared during the build: $STATE_DIR"
  mv "$state_dir_tmp" "$STATE_DIR"
}

# Partial clones fetch commits and trees, and download file contents only
# for checked-out paths. OpenWrt version stamps need history, not old blobs.
clone_pinned_repository() {
  local url="$1"
  local dir="$2"
  local ref="$3"
  local branch="${4:-}"

  git clone --filter=blob:none --no-checkout "$url" "$dir"
  if [[ -n "$branch" ]]; then
    git -C "$dir" checkout -q -b "$branch" "$ref"
  else
    git -C "$dir" checkout -q --detach "$ref"
  fi
  verify_checkout "$dir" "$ref"
  verify_not_shallow "$dir"
}

run_source_build() {
  local tag_ref rebuild_selector rebuild_path
  local -a rebuild_paths=() stale_target_images=()

  if [[ "$BUILD_MODE" == 'full' ]]; then
    log "Cloning OpenWrt core"
    clone_pinned_repository "$OPENWRT_REPO_URL" "$OPENWRT_DIR" "$OPENWRT_REF"

    if [[ -n "${OPENWRT_TAG:-}" ]]; then
      tag_ref="$(git -C "$OPENWRT_DIR" rev-list -n1 "$OPENWRT_TAG")"
      [[ "$tag_ref" == "$OPENWRT_REF" ]] ||
        die "tag $OPENWRT_TAG does not resolve to $OPENWRT_REF"
    fi

    log "Writing pinned feed definitions"
    write_feeds_conf

    # scripts/feeds keeps an existing pinned checkout. Its own clone would
    # fetch every historical blob; the branch name matches its checkout.
    log "Cloning pinned feeds"
    clone_pinned_repository "$FEED_PACKAGES_URL" "$OPENWRT_DIR/feeds/packages" "$FEED_PACKAGES_REF" "$FEED_PACKAGES_REF"
    clone_pinned_repository "$FEED_LUCI_URL" "$OPENWRT_DIR/feeds/luci" "$FEED_LUCI_REF" "$FEED_LUCI_REF"
    clone_pinned_repository "$FEED_ROUTING_URL" "$OPENWRT_DIR/feeds/routing" "$FEED_ROUTING_REF" "$FEED_ROUTING_REF"
    clone_pinned_repository "$FEED_TELEPHONY_URL" "$OPENWRT_DIR/feeds/telephony" "$FEED_TELEPHONY_REF" "$FEED_TELEPHONY_REF"
    clone_pinned_repository "$FEED_VIDEO_URL" "$OPENWRT_DIR/feeds/video" "$FEED_VIDEO_REF" "$FEED_VIDEO_REF"

    log "Updating feeds"
    (
      cd "$OPENWRT_DIR"
      ./scripts/feeds update -a
    )

    verify_checkout "$OPENWRT_DIR/feeds/packages" "$FEED_PACKAGES_REF"
    verify_checkout "$OPENWRT_DIR/feeds/luci" "$FEED_LUCI_REF"
    verify_checkout "$OPENWRT_DIR/feeds/routing" "$FEED_ROUTING_REF"
    verify_checkout "$OPENWRT_DIR/feeds/telephony" "$FEED_TELEPHONY_REF"
    verify_checkout "$OPENWRT_DIR/feeds/video" "$FEED_VIDEO_REF"

    verify_not_shallow "$OPENWRT_DIR/feeds/packages"
    verify_not_shallow "$OPENWRT_DIR/feeds/luci"
    verify_not_shallow "$OPENWRT_DIR/feeds/routing"
    verify_not_shallow "$OPENWRT_DIR/feeds/telephony"
    verify_not_shallow "$OPENWRT_DIR/feeds/video"

    log "Installing feeds"
    (
      cd "$OPENWRT_DIR"
      ./scripts/feeds install -a
    )
    install_local_feed_packages

    apply_pinned_patches

    log "Writing device config"
    cp "$CONFIG_FRAGMENT_ABS" "$OPENWRT_DIR/.config"
    append_extra_config
    write_build_options_config

    (
      cd "$OPENWRT_DIR"
      make defconfig
    )
  else
    apply_pinned_patches
  fi

  log "Resolving apk world package selections"
  world_config_resolve "$OPENWRT_DIR/tmp/.packageinfo" \
    "$REPORT_DIR/reference.world" "$REPORT_DIR/builtin-package-names.txt" \
    | sort -u >"$REPORT_DIR/world-config.tsv"
  world_config_missing "$REPORT_DIR/world-config.tsv" "$OPENWRT_DIR/.config" \
    >"$REPORT_DIR/world-unselected-package-names.txt"
  if [[ "$BUILD_MODE" == 'full' && -s "$REPORT_DIR/world-unselected-package-names.txt" ]]; then
    log "Selecting captured apk world packages in device config"
    world_config_apply "$REPORT_DIR/world-config.tsv" "$OPENWRT_DIR/.config" \
      >"$OPENWRT_DIR/.config.world"
    mv "$OPENWRT_DIR/.config.world" "$OPENWRT_DIR/.config"
    (
      cd "$OPENWRT_DIR"
      make defconfig
    )
    world_config_missing "$REPORT_DIR/world-config.tsv" "$OPENWRT_DIR/.config" \
      >"$REPORT_DIR/world-unselected-package-names.txt"
  fi
  cp "$OPENWRT_DIR/.config" "$REPORT_DIR/final.config"
  if [[ -s "$REPORT_DIR/world-unselected-package-names.txt" ]]; then
    cat "$REPORT_DIR/world-unselected-package-names.txt" >&2
    die "apk world packages cannot be selected for this target; see $REPORT_DIR/world-unselected-package-names.txt"
  fi

  if [[ "$BUILD_MODE" == 'full' ]]; then
    write_prepared_state
  fi

  configure_ccache_environment

  if [[ "$BUILD_MODE" != 'incremental' ]]; then
    log "Downloading sources"
    (
      cd "$OPENWRT_DIR"
      make DL_DIR="$DL_DIR" download -j"$DOWNLOAD_JOBS"
    )
  fi

  if [[ "$BUILD_MODE" != 'full' ]]; then
    for rebuild_selector in "${REBUILT_PACKAGES[@]}"; do
      case "$rebuild_selector" in
        mac80211)
          rebuild_paths=('package/kernel/mac80211')
          ;;
        local-feeds)
          rebuild_paths=("${LOCAL_FEED_PACKAGE_PATHS[@]}")
          ;;
        *)
          die "internal error: unsupported incremental package: $rebuild_selector"
          ;;
      esac
      for rebuild_path in "${rebuild_paths[@]}"; do
        log "Cleaning incremental package: $rebuild_path"
        (
          cd "$OPENWRT_DIR"
          make DL_DIR="$DL_DIR" "$rebuild_path/clean"
        )
        log "Compiling incremental package: $rebuild_path"
        (
          cd "$OPENWRT_DIR"
          make DL_DIR="$DL_DIR" -j"$MAKE_JOBS" "$rebuild_path/compile"
        )
      done
    done

    ARTIFACT_DIR="$OPENWRT_DIR/bin/targets/$TARGET/$SUBTARGET"
    if [[ -d "$ARTIFACT_DIR" ]]; then
      mapfile -d '' -t stale_target_images < <(
        find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "*${DEVICE_ID}*" -print0
      )
      if ((${#stale_target_images[@]} > 0)); then
        log "Removing ${#stale_target_images[@]} stale target artifact(s)"
        rm -f -- "${stale_target_images[@]}"
      fi
    fi
  fi

  log "Building image"
  write_ccache_stats "before build"
  (
    cd "$OPENWRT_DIR"
    make DL_DIR="$DL_DIR" -j"$MAKE_JOBS"
  )
  write_ccache_stats "after build"
  cp "$OPENWRT_DIR/.config" "$REPORT_DIR/final.config"
  copy_openwrt_logs

  ARTIFACT_DIR="$OPENWRT_DIR/bin/targets/$TARGET/$SUBTARGET"
  SYSUPGRADE_IMAGE="$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "*${DEVICE_ID}*sysupgrade.bin" | sort | head -n1)"
  INITRAMFS_IMAGE="$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "*${DEVICE_ID}*initramfs-kernel.bin" | sort | head -n1)"
  BUILT_MANIFEST="$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "*${DEVICE_ID}.manifest" | sort | head -n1)"

  [[ -n "$SYSUPGRADE_IMAGE" ]] || die "sysupgrade image not found in $ARTIFACT_DIR"
  [[ -n "$INITRAMFS_IMAGE" ]] || die "initramfs image not found in $ARTIFACT_DIR"
  [[ -n "$BUILT_MANIFEST" ]] || die "manifest not found in $ARTIFACT_DIR"
}

run_imagebuilder_build() {
  # A changed upstream index should fail before the SDK compile.
  log "Verifying pinned ImageBuilder repository indexes"
  fetch_imagebuilder_indexes

  if [[ "$BUILD_MODE" == 'full' ]]; then
    prepare_sdk
    prepare_imagebuilder
    verify_imagebuilder_tree
    write_prepared_state
  else
    apply_pinned_patches
    verify_imagebuilder_tree
  fi
  verify_sdk_package_options
  cp "$SDK_DIR/.config" "$REPORT_DIR/sdk.config"

  configure_ccache_environment
  write_ccache_stats "before build"
  compile_sdk_packages
  write_ccache_stats "after build"
  copy_openwrt_logs

  assemble_imagebuilder_packages
  seed_imagebuilder_apk_cache
  build_imagebuilder_image
  verify_imagebuilder_apk_cache
  verify_injected_packages

  IMAGEBUILDER_KERNEL_VERSION="$(imagebuilder_kernel_version "$IB_PRISTINE_PACKAGES_DIR")" ||
    die 'failed to read the ImageBuilder kernel version'
  ARTIFACT_DIR="$IB_BIN_DIR"
  SYSUPGRADE_IMAGE="$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "*${DEVICE_ID}*sysupgrade.bin" | sort | head -n1)"
  # The ImageBuilder ships only the kernel package; initramfs images need
  # --build-method source.
  INITRAMFS_IMAGE=''
  BUILT_MANIFEST="$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "*${DEVICE_ID}.manifest" | sort | head -n1)"

  [[ -n "$SYSUPGRADE_IMAGE" ]] || die "sysupgrade image not found in $ARTIFACT_DIR"
  [[ -n "$BUILT_MANIFEST" ]] || die "manifest not found in $ARTIFACT_DIR"
}

exec > >(tee -a "$BUILD_LOG") 2>&1

log "Workspace: $BUILD_ROOT"
log "Session: $BUILD_ID"
log "Build method: $BUILD_METHOD"
log "Build mode: $BUILD_MODE"
log "Build log: $BUILD_LOG"
extract_world >"$REPORT_DIR/reference.world"
[[ -s "$REPORT_DIR/reference.world" ]] || die "failed to extract world entries from $WORLD_SOURCE_ABS"
write_manifest_builtin_package_names | sort -u >"$REPORT_DIR/builtin-package-names.txt"
download_prebuilt_apks
if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
  run_imagebuilder_build
else
  run_source_build
fi

cp "$SYSUPGRADE_IMAGE" "$OUTPUT_DIR/"
if [[ -n "$INITRAMFS_IMAGE" ]]; then
  cp "$INITRAMFS_IMAGE" "$OUTPUT_DIR/"
fi
cp "$BUILT_MANIFEST" "$OUTPUT_DIR/"

output_images=("$(basename "$SYSUPGRADE_IMAGE")")
if [[ -n "$INITRAMFS_IMAGE" ]]; then
  output_images+=("$(basename "$INITRAMFS_IMAGE")")
fi
(
  cd "$OUTPUT_DIR"
  sha256sum "${output_images[@]}" | tee sha256sums.txt
)

parse_manifest "$REFERENCE_MANIFEST_ABS" | sort >"$REPORT_DIR/reference.tsv"
parse_manifest "$BUILT_MANIFEST" | sort >"$REPORT_DIR/built.tsv"
cut -f1 "$REPORT_DIR/reference.tsv" >"$REPORT_DIR/reference.names"
cut -f1 "$REPORT_DIR/built.tsv" >"$REPORT_DIR/built.names"
write_local_feed_digests | sort >"$REPORT_DIR/local-feed-digests.tsv"
write_prebuilt_apk_digests | sort >"$REPORT_DIR/prebuilt-apks.tsv"
write_patch_metadata >"$REPORT_DIR/patches.tsv"
sort -u "$REPORT_DIR/reference.names" "$REPORT_DIR/builtin-package-names.txt" >"$REPORT_DIR/reference.effective.names"
sort -u "$REPORT_DIR/built.names" "$REPORT_DIR/builtin-package-names.txt" >"$REPORT_DIR/built.effective.names"

comm -23 "$REPORT_DIR/reference.names" "$REPORT_DIR/built.effective.names" >"$REPORT_DIR/missing-package-names.txt"
comm -13 "$REPORT_DIR/reference.effective.names" "$REPORT_DIR/built.names" >"$REPORT_DIR/extra-package-names.txt"
join -t $'\t' "$REPORT_DIR/reference.tsv" "$REPORT_DIR/built.tsv" | awk -F '\t' '$2 != $3 { print $1 "\t" $2 "\t" $3 }' >"$REPORT_DIR/version-mismatches.tsv"

image_kernel_version="$(awk -F '\t' '$1 == "kernel" { print $2; exit }' "$REPORT_DIR/built.tsv")"
reference_kernel_version="$(awk -F '\t' '$1 == "kernel" { print $2; exit }' "$REPORT_DIR/reference.tsv")"
if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
  # The ImageBuilder installs the official kernel, so official kmods match
  # it. Its version replaces the router kernel line in the strict check.
  [[ "$image_kernel_version" == "$IMAGEBUILDER_KERNEL_VERSION" ]] ||
    die "image kernel ${image_kernel_version:-<missing>} is not the pinned ImageBuilder kernel $IMAGEBUILDER_KERNEL_VERSION"
  awk -F '\t' -v kernel="$IMAGEBUILDER_KERNEL_VERSION" '!($1 == "kernel" && $3 == kernel)' \
    "$REPORT_DIR/version-mismatches.tsv" >"$REPORT_DIR/version-mismatches.tsv.tmp"
  mv "$REPORT_DIR/version-mismatches.tsv.tmp" "$REPORT_DIR/version-mismatches.tsv"
fi

sed 's/=.*$//' "$REPORT_DIR/reference.world" | sort -u >"$REPORT_DIR/world.names"
comm -23 "$REPORT_DIR/world.names" "$REPORT_DIR/built.effective.names" >"$REPORT_DIR/world-missing-package-names.txt"

builtin_package_names_count="$(count_lines "$REPORT_DIR/builtin-package-names.txt")"
missing_package_names_count="$(count_lines "$REPORT_DIR/missing-package-names.txt")"
extra_package_names_count="$(count_lines "$REPORT_DIR/extra-package-names.txt")"
version_mismatches_count="$(count_lines "$REPORT_DIR/version-mismatches.tsv")"
world_missing_package_names_count="$(count_lines "$REPORT_DIR/world-missing-package-names.txt")"

cp "$LOCK_FILE" "$METADATA_DIR/$(basename "$LOCK_FILE")"
copy_pinned_patch_metadata
cp "$REFERENCE_MANIFEST_ABS" "$METADATA_DIR/reference.manifest"
cp "$REPORT_DIR/reference.world" "$METADATA_DIR/reference.world"
if [[ "$BUILD_METHOD" == 'imagebuilder' ]]; then
  cp "$REPORT_DIR/sdk.config" "$METADATA_DIR/sdk.config"
  cp "$REPORT_DIR/imagebuilder-packages.txt" "$METADATA_DIR/imagebuilder-packages.txt"
  cp "$REPORT_DIR/imagebuilder-injected.tsv" "$METADATA_DIR/imagebuilder-injected.tsv"
  write_imagebuilder_repositories >"$METADATA_DIR/imagebuilder-repositories.tsv"
else
  cp "$CONFIG_FRAGMENT_ABS" "$METADATA_DIR/$(basename "$CONFIG_FRAGMENT_ABS")"
  cp "$REPORT_DIR/final.config" "$METADATA_DIR/final.config"
fi
cp "$REPORT_DIR/builtin-package-names.txt" "$METADATA_DIR/builtin-package-names.txt"
cp "$REPORT_DIR/local-feed-digests.tsv" "$METADATA_DIR/local-feed-digests.tsv"
cp "$REPORT_DIR/prebuilt-apks.tsv" "$METADATA_DIR/prebuilt-apks.tsv"
cp "$REPORT_DIR/patches.tsv" "$METADATA_DIR/patches.tsv"
if [[ -f "$REPORT_DIR/ccache-stats.txt" ]]; then
  cp "$REPORT_DIR/ccache-stats.txt" "$METADATA_DIR/ccache-stats.txt"
fi

sysupgrade_sha="$(sha256sum "$SYSUPGRADE_IMAGE" | awk '{print $1}')"
initramfs_name=''
initramfs_sha=''
if [[ -n "$INITRAMFS_IMAGE" ]]; then
  initramfs_name="$(basename "$INITRAMFS_IMAGE")"
  initramfs_sha="$(sha256sum "$INITRAMFS_IMAGE" | awk '{print $1}')"
fi
openwrt_logs_rel=''
if [[ -d "$OPENWRT_LOG_OUTPUT_DIR" ]]; then
  openwrt_logs_rel='logs/openwrt'
fi
if ((${#REBUILT_PACKAGES[@]} == 0)); then
  rebuilt_packages_value='none'
else
  rebuilt_packages_value="$(IFS=,; printf '%s' "${REBUILT_PACKAGES[*]}")"
fi

cat >"$REPORT_DIR/build-summary.txt" <<EOF
build_id=${BUILD_ID}
build_root=${BUILD_ROOT}
workspace_id=${WORKSPACE_ID}
build_method=${BUILD_METHOD}
build_mode=${BUILD_MODE}
builder_id=${BUILDER_ID}
rebuilt_packages=${rebuilt_packages_value}
lock_file=$(basename "$LOCK_FILE")
openwrt_ref=${OPENWRT_REF}
openwrt_tag=${OPENWRT_TAG:-}
packages_ref=${FEED_PACKAGES_REF}
luci_ref=${FEED_LUCI_REF}
routing_ref=${FEED_ROUTING_REF}
telephony_ref=${FEED_TELEPHONY_REF}
video_ref=${FEED_VIDEO_REF}
patch_sha256=${PATCH_SHA256}
patches_tsv=metadata/patches.tsv
sdk_sha256=${SDK_SHA256:-}
imagebuilder_sha256=${IMAGEBUILDER_SHA256:-}
builder_platform=${BUILDER_PLATFORM:-unknown}
build_log=logs/build.log
openwrt_logs=${openwrt_logs_rel}
sysupgrade_image=$(basename "$SYSUPGRADE_IMAGE")
sysupgrade_sha256=${sysupgrade_sha}
initramfs_image=${initramfs_name}
initramfs_sha256=${initramfs_sha}
reference_kernel_version=${reference_kernel_version}
image_kernel_version=${image_kernel_version}
strict_manifest=${STRICT_MANIFEST_MODE}
ccache=${USE_CCACHE_MODE}
ccache_dir=${CCACHE_DIR:-}
ccache_maxsize=${CCACHE_MAXSIZE:-}
ccache_stats=$(if [[ -f "$REPORT_DIR/ccache-stats.txt" ]]; then printf 'metadata/ccache-stats.txt'; fi)
builtin_package_names=${builtin_package_names_count}
missing_package_names=${missing_package_names_count}
extra_package_names=${extra_package_names_count}
version_mismatches=${version_mismatches_count}
world_missing_package_names=${world_missing_package_names_count}
EOF

cp "$REPORT_DIR/build-summary.txt" "$OUTPUT_DIR/"

if (("${world_missing_package_names_count}" > 0)); then
  die "built manifest is missing apk world packages; see $REPORT_DIR and $REPORT_DIR/build-summary.txt"
fi

if ((STRICT_MANIFEST_MODE)) && (
  (("${missing_package_names_count}" > 0)) ||
  (("${extra_package_names_count}" > 0)) ||
  (("${version_mismatches_count}" > 0))
); then
  die "built manifest differs from reference; see $REPORT_DIR and $REPORT_DIR/build-summary.txt"
fi

success_tmp="$(mktemp "$STATE_DIR/.last-success.XXXXXXXX")"
write_build_state >"$success_tmp"
cp "$COMPATIBILITY_FILE" "$METADATA_DIR/workspace-compatibility.tsv"
cp "$success_tmp" "$METADATA_DIR/workspace-last-success.tsv"
mv "$success_tmp" "$SUCCESS_FILE"

log "Build complete"
log "Output directory: $OUTPUT_DIR"
log "Report directory: $REPORT_DIR"
