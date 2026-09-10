#!/usr/bin/env bash
set -euo pipefail

umask 022
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/build-name.sh
source "$SCRIPT_DIR/lib/build-name.sh"
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
                            openwrt-ft-<device-id>-dev.
  --builder-id ID           Builder image identity. Required.
  --fresh                   Replace the exact workspace and run a full build.
  --rebuild-package NAME    Force an incremental package rebuild. Repeatable;
                            NAME is mac80211, hostapd, or all.
  --help                    Show this message.

Environment equivalents are BUILD_ID, WORKSPACE_ID, BUILDER_ID, FRESH, and
REBUILD_PACKAGES (a comma- or space-separated selector list).
EOF
}

BUILD_ID_ARG=''
WORKSPACE_ID_ARG=''
BUILDER_ID_ARG=''
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
  local i source_abs dest sha256

  for i in "${!PINNED_PATCH_SOURCE_ABS[@]}"; do
    source_abs="${PINNED_PATCH_SOURCE_ABS[$i]}"
    dest="${PINNED_PATCH_DESTS[$i]}"
    sha256="${PINNED_PATCH_SHA256S[$i]}"
    log "Applying pinned patch: $dest"
    verify_sha256 "$source_abs" "$sha256"
    # OpenWrt includes patch mtimes in its package preparation stamps.
    if ! cmp -s "$source_abs" "$OPENWRT_DIR/$dest"; then
      install -D -m 0644 "$source_abs" "$OPENWRT_DIR/$dest"
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

write_ccache_config() {
  if [[ "$USE_CCACHE_MODE" == '1' ]]; then
    printf 'CONFIG_DEVEL=y\n' >>"$OPENWRT_DIR/.config"
    printf 'CONFIG_CCACHE=y\n' >>"$OPENWRT_DIR/.config"
    printf 'CONFIG_CCACHE_DIR="%s"\n' "$CCACHE_DIR" >>"$OPENWRT_DIR/.config"
  else
    printf '# CONFIG_CCACHE is not set\n' >>"$OPENWRT_DIR/.config"
  fi
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

write_compatibility_manifest() {
  local i index entry name path expected

  {
    state_entry builder_id "$BUILDER_ID"
    state_entry builder_platform "${BUILDER_PLATFORM:-unknown}"
    state_entry ccache "$USE_CCACHE_MODE"
    state_entry config_fragment.path "$CONFIG_FRAGMENT"
    state_entry config_fragment.sha256 "$(sha256sum "$CONFIG_FRAGMENT_ABS" | awk '{print $1}')"
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
    state_entry reference_manifest.path "$REFERENCE_MANIFEST"
    state_entry reference_manifest.sha256 "$(sha256sum "$REFERENCE_MANIFEST_ABS" | awk '{print $1}')"
    state_entry state_schema "$WORKSPACE_STATE_SCHEMA"
    state_entry subtarget "$SUBTARGET"
    state_entry target "$TARGET"
    state_entry world_source.path "$WORLD_SOURCE"
    state_entry world_source.sha256 "$(sha256sum "$WORLD_SOURCE_ABS" | awk '{print $1}')"

    for i in "${!PINNED_PATCH_SOURCES[@]}"; do
      printf -v index '%03d' "$i"
      state_entry "patch.$index.source" "${PINNED_PATCH_SOURCES[$i]}"
      state_entry "patch.$index.destination" "${PINNED_PATCH_DESTS[$i]}"
    done

    if declare -p EXTRA_CONFIG_LINES >/dev/null 2>&1; then
      local -n extra_config_lines=EXTRA_CONFIG_LINES
      for i in "${!extra_config_lines[@]}"; do
        printf -v index '%03d' "$i"
        state_entry "extra_config.$index" "${extra_config_lines[$i]}"
      done
    fi

    if declare -p MANIFEST_BUILTIN_PACKAGE_NAMES >/dev/null 2>&1; then
      local -n builtin_package_names=MANIFEST_BUILTIN_PACKAGE_NAMES
      for i in "${!builtin_package_names[@]}"; do
        printf -v index '%03d' "$i"
        state_entry "manifest_builtin_package.$index" "${builtin_package_names[$i]}"
      done
    fi

    if declare -p LOCAL_FEEDS >/dev/null 2>&1; then
      local -n local_feeds=LOCAL_FEEDS
      for i in "${!local_feeds[@]}"; do
        entry="${local_feeds[$i]}"
        name="${entry%%:*}"
        path="${entry#*:}"
        expected="$(local_feed_expected_digest "$name")" ||
          die "LOCAL_FEED_SHA256S is missing digest for local feed: $name"
        printf -v index '%03d' "$i"
        state_entry "local_feed.$index.name" "$name"
        state_entry "local_feed.$index.path" "$path"
        state_entry "local_feed.$index.sha256" "$expected"
      done
    fi

    if declare -p LOCAL_FEED_INSTALLS >/dev/null 2>&1; then
      local -n local_feed_installs=LOCAL_FEED_INSTALLS
      for i in "${!local_feed_installs[@]}"; do
        printf -v index '%03d' "$i"
        state_entry "local_feed_install.$index" "${local_feed_installs[$i]}"
      done
    fi

    if declare -p PREBUILT_APKS >/dev/null 2>&1; then
      local -n prebuilt_apks=PREBUILT_APKS
      for i in "${!prebuilt_apks[@]}"; do
        printf -v index '%03d' "$i"
        state_entry "prebuilt_apk.$index" "${prebuilt_apks[$i]}"
      done
    fi
  } | sort
}

write_success_state() {
  local i index

  state_entry final_config_sha256 "$(sha256sum "$OPENWRT_DIR/.config" | awk '{print $1}')"
  for i in "${!PINNED_PATCH_SHA256S[@]}"; do
    printf -v index '%03d' "$i"
    state_entry "patch.$index.sha256" "${PINNED_PATCH_SHA256S[$i]}"
  done
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
    package/network/services/hostapd/*)
      printf 'hostapd\n'
      ;;
    *)
      return 1
      ;;
  esac
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

require_cmd awk cmp comm cp curl cut find flock git head install join make mkdir mktemp mv nproc realpath rm sed sha256sum sort tee xargs

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

if [[ -n "$BUILD_ID_ARG" ]]; then
  BUILD_ID="$BUILD_ID_ARG"
else
  BUILD_ID="${BUILD_ID:-$(openwrt_default_build_name)}"
fi
if [[ -n "$WORKSPACE_ID_ARG" ]]; then
  WORKSPACE_ID="$WORKSPACE_ID_ARG"
else
  WORKSPACE_ID="${WORKSPACE_ID:-$(openwrt_default_workspace_name)}"
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
for rebuild_selector in "${REBUILD_PACKAGE_ARGS[@]}"; do
  case "$rebuild_selector" in
    mac80211|hostapd)
      REQUESTED_REBUILDS["$rebuild_selector"]=1
      ;;
    all)
      REQUESTED_REBUILDS[mac80211]=1
      REQUESTED_REBUILDS[hostapd]=1
      ;;
    *)
      die "unsupported rebuild package: $rebuild_selector (expected mac80211, hostapd, or all)"
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
  log "Removing workspace for fresh build: $BUILD_ROOT"
  rm -rf -- "$BUILD_ROOT"
fi

if [[ -e "$BUILD_ROOT" ]]; then
  [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] ||
    die "workspace path is not a safe directory: $BUILD_ROOT"
  BUILD_MODE='incremental'
else
  BUILD_MODE='full'
fi

OPENWRT_DIR="$BUILD_ROOT/openwrt"
REPORT_DIR="$BUILD_ROOT/reports"
OUTPUT_DIR="$BUILD_ROOT/output"
METADATA_DIR="$OUTPUT_DIR/metadata"
LOG_DIR="$OUTPUT_DIR/logs"
BUILD_LOG="$LOG_DIR/build.log"
OPENWRT_LOG_OUTPUT_DIR="$LOG_DIR/openwrt"
WORKSPACE_STATE_SCHEMA='1'
STATE_DIR="$BUILD_ROOT/.openwrt-ft-state"
COMPATIBILITY_FILE="$STATE_DIR/compatibility.tsv"
SUCCESS_FILE="$STATE_DIR/last-success.tsv"

MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-$DEFAULT_DOWNLOAD_JOBS}"

export DL_DIR="${DL_DIR:-$CACHE_ROOT/dl}"
if [[ "$USE_CCACHE_MODE" == '1' ]]; then
  command -v ccache >/dev/null 2>&1 ||
    die 'USE_CCACHE=1 requires ccache in the builder image'
  export CCACHE_DIR="${CCACHE_DIR:-$CACHE_ROOT/ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
fi

declare -A REBUILD_PACKAGES_SET=()
REBUILT_PACKAGES=()

if [[ "$BUILD_MODE" == 'incremental' ]]; then
  [[ -f "$COMPATIBILITY_FILE" && -f "$SUCCESS_FILE" ]] ||
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

  stored_schema="$(state_value "$SUCCESS_FILE" state_schema)" ||
    die "workspace success state is missing state_schema: $SUCCESS_FILE; rerun with --fresh"
  [[ "$stored_schema" == "$WORKSPACE_STATE_SCHEMA" ]] ||
    die "workspace success state schema is $stored_schema, expected $WORKSPACE_STATE_SCHEMA; rerun with --fresh"

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

  stored_config_sha="$(state_value "$SUCCESS_FILE" final_config_sha256)" ||
    die "workspace success state is missing final_config_sha256; rerun with --fresh"
  verify_sha256 "$OPENWRT_DIR/.config" "$stored_config_sha"

  for i in "${!PINNED_PATCH_SHA256S[@]}"; do
    printf -v index '%03d' "$i"
    previous_patch_sha="$(state_value "$SUCCESS_FILE" "patch.$index.sha256")" ||
      die "workspace success state is missing patch.$index.sha256; rerun with --fresh"
    patch_dest_abs="$OPENWRT_DIR/${PINNED_PATCH_DESTS[$i]}"
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
fi

for rebuild_selector in "${!REQUESTED_REBUILDS[@]}"; do
  REBUILD_PACKAGES_SET["$rebuild_selector"]=1
done
if [[ "$BUILD_MODE" == 'full' ]]; then
  REBUILT_PACKAGES=(all)
else
  for rebuild_selector in mac80211 hostapd; do
    if [[ -n "${REBUILD_PACKAGES_SET[$rebuild_selector]:-}" ]]; then
      REBUILT_PACKAGES+=("$rebuild_selector")
    fi
  done
fi

if [[ "$BUILD_MODE" == 'incremental' ]]; then
  rm -rf -- "$REPORT_DIR" "$OUTPUT_DIR" "$OPENWRT_DIR/logs"
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
  [[ -d "${OPENWRT_DIR:-}/logs" ]] || return 0
  mkdir -p "$OPENWRT_LOG_OUTPUT_DIR" || return 0
  cp -a "$OPENWRT_DIR/logs/." "$OPENWRT_LOG_OUTPUT_DIR/" || return 0
}

finalize_logs() {
  local status=$?
  set +e
  copy_openwrt_logs
  exit "$status"
}
trap finalize_logs EXIT

exec > >(tee -a "$BUILD_LOG") 2>&1

log "Workspace: $BUILD_ROOT"
log "Session: $BUILD_ID"
log "Build mode: $BUILD_MODE"
log "Build log: $BUILD_LOG"
extract_world >"$REPORT_DIR/reference.world"
[[ -s "$REPORT_DIR/reference.world" ]] || die "failed to extract world entries from $WORLD_SOURCE_ABS"
write_manifest_builtin_package_names | sort -u >"$REPORT_DIR/builtin-package-names.txt"
download_prebuilt_apks
if [[ "$BUILD_MODE" == 'full' ]]; then
  log "Cloning OpenWrt core"
  git clone "$OPENWRT_REPO_URL" "$OPENWRT_DIR"
  git -C "$OPENWRT_DIR" checkout --detach "$OPENWRT_REF"
  verify_checkout "$OPENWRT_DIR" "$OPENWRT_REF"
  verify_not_shallow "$OPENWRT_DIR"

  if [[ -n "${OPENWRT_TAG:-}" ]]; then
    tag_ref="$(git -C "$OPENWRT_DIR" rev-list -n1 "$OPENWRT_TAG")"
    [[ "$tag_ref" == "$OPENWRT_REF" ]] ||
      die "tag $OPENWRT_TAG does not resolve to $OPENWRT_REF"
  fi

  log "Writing pinned feed definitions"
  write_feeds_conf

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
  write_ccache_config

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
  log "Downloading sources"
  (
    cd "$OPENWRT_DIR"
    make DL_DIR="$DL_DIR" download -j"$DOWNLOAD_JOBS"
  )
fi

if [[ "$BUILD_MODE" == 'incremental' ]]; then
  for rebuild_selector in "${REBUILT_PACKAGES[@]}"; do
    case "$rebuild_selector" in
      mac80211)
        rebuild_path='package/kernel/mac80211'
        ;;
      hostapd)
        rebuild_path='package/network/services/hostapd'
        ;;
      *)
        die "internal error: unsupported incremental package: $rebuild_selector"
        ;;
    esac
    log "Cleaning incremental package: $rebuild_selector"
    (
      cd "$OPENWRT_DIR"
      make DL_DIR="$DL_DIR" "$rebuild_path/clean"
    )
    log "Compiling incremental package: $rebuild_selector"
    (
      cd "$OPENWRT_DIR"
      make DL_DIR="$DL_DIR" -j"$MAKE_JOBS" "$rebuild_path/compile"
    )
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

cp "$SYSUPGRADE_IMAGE" "$OUTPUT_DIR/"
cp "$INITRAMFS_IMAGE" "$OUTPUT_DIR/"
cp "$BUILT_MANIFEST" "$OUTPUT_DIR/"

(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$SYSUPGRADE_IMAGE")" "$(basename "$INITRAMFS_IMAGE")" | tee sha256sums.txt
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

sed 's/=.*$//' "$REPORT_DIR/reference.world" | sort -u >"$REPORT_DIR/world.names"
comm -23 "$REPORT_DIR/world.names" "$REPORT_DIR/built.effective.names" >"$REPORT_DIR/world-missing-package-names.txt"

builtin_package_names_count="$(count_lines "$REPORT_DIR/builtin-package-names.txt")"
missing_package_names_count="$(count_lines "$REPORT_DIR/missing-package-names.txt")"
extra_package_names_count="$(count_lines "$REPORT_DIR/extra-package-names.txt")"
version_mismatches_count="$(count_lines "$REPORT_DIR/version-mismatches.tsv")"
world_missing_package_names_count="$(count_lines "$REPORT_DIR/world-missing-package-names.txt")"

cp "$LOCK_FILE" "$METADATA_DIR/$(basename "$LOCK_FILE")"
cp "$CONFIG_FRAGMENT_ABS" "$METADATA_DIR/$(basename "$CONFIG_FRAGMENT_ABS")"
copy_pinned_patch_metadata
cp "$REFERENCE_MANIFEST_ABS" "$METADATA_DIR/reference.manifest"
cp "$REPORT_DIR/reference.world" "$METADATA_DIR/reference.world"
cp "$REPORT_DIR/final.config" "$METADATA_DIR/final.config"
cp "$REPORT_DIR/builtin-package-names.txt" "$METADATA_DIR/builtin-package-names.txt"
cp "$REPORT_DIR/local-feed-digests.tsv" "$METADATA_DIR/local-feed-digests.tsv"
cp "$REPORT_DIR/prebuilt-apks.tsv" "$METADATA_DIR/prebuilt-apks.tsv"
cp "$REPORT_DIR/patches.tsv" "$METADATA_DIR/patches.tsv"
if [[ -f "$REPORT_DIR/ccache-stats.txt" ]]; then
  cp "$REPORT_DIR/ccache-stats.txt" "$METADATA_DIR/ccache-stats.txt"
fi

sysupgrade_sha="$(sha256sum "$SYSUPGRADE_IMAGE" | awk '{print $1}')"
initramfs_sha="$(sha256sum "$INITRAMFS_IMAGE" | awk '{print $1}')"
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
builder_platform=${BUILDER_PLATFORM:-unknown}
build_log=logs/build.log
openwrt_logs=${openwrt_logs_rel}
sysupgrade_image=$(basename "$SYSUPGRADE_IMAGE")
sysupgrade_sha256=${sysupgrade_sha}
initramfs_image=$(basename "$INITRAMFS_IMAGE")
initramfs_sha256=${initramfs_sha}
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

if [[ "$BUILD_MODE" == 'full' ]]; then
  state_dir_tmp="$(mktemp -d "$WORK_ROOT/.openwrt-ft-state.XXXXXXXX")"
  write_compatibility_manifest >"$state_dir_tmp/compatibility.tsv"
  write_success_state >"$state_dir_tmp/last-success.tsv"
  cp "$state_dir_tmp/compatibility.tsv" "$METADATA_DIR/workspace-compatibility.tsv"
  cp "$state_dir_tmp/last-success.tsv" "$METADATA_DIR/workspace-last-success.tsv"
  [[ ! -e "$STATE_DIR" ]] ||
    die "workspace state unexpectedly appeared during the build: $STATE_DIR"
  mv "$state_dir_tmp" "$STATE_DIR"
else
  success_tmp="$(mktemp "$WORK_ROOT/.openwrt-ft-success.XXXXXXXX")"
  write_success_state >"$success_tmp"
  cp "$COMPATIBILITY_FILE" "$METADATA_DIR/workspace-compatibility.tsv"
  cp "$success_tmp" "$METADATA_DIR/workspace-last-success.tsv"
  mv "$success_tmp" "$SUCCESS_FILE"
fi

log "Build complete"
log "Output directory: $OUTPUT_DIR"
log "Report directory: $REPORT_DIR"
