#!/usr/bin/env bash
set -euo pipefail

umask 022
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
if [[ -n "${PREPARE_OPENWRT_UPGRADE_PATH_PREFIX:-}" ]]; then
  export PATH="$PREPARE_OPENWRT_UPGRADE_PATH_PREFIX:$PATH"
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/prepare-openwrt-upgrade.sh [options] <ssh-target> <lock-file> [-- <run-ec2-build args...>]

Options:
  --version VERSION  Prepare this OpenWrt release instead of the latest same-branch
                     ASU release, for example 25.12.4.
  --server URL       ASU server URL. Default: router config or
                     https://sysupgrade.openwrt.org.
  --dry-run          Print planned changes and build command without writing
                     files or starting a build.
  --help             Show this message.

The command prepares a patched repo-built upgrade image using ASU metadata for
release discovery. It does not copy the image to the router or run sysupgrade.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

abs_repo_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$path"
  fi
}

repo_existing_path() {
  local path="$1"
  local description="$2"
  local absolute canonical

  absolute="$(abs_repo_path "$path")"
  [[ -e "$absolute" ]] || die "$description not found: $path"
  canonical="$(realpath -e "$absolute")"
  case "$canonical" in
    "$REPO_ROOT"/*) ;;
    *) die "$description must be inside this repository: $path" ;;
  esac

  printf '%s\n' "$canonical"
}

trim_trailing_slash() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

validate_asu_server_url() {
  local url="$1"

  case "$url" in
    https://*) ;;
    *) die "ASU server URL must start with https://: $url" ;;
  esac

  case "$url" in
    *[[:space:]]*) die "ASU server URL must not contain whitespace: $url" ;;
  esac
}

compare_versions() {
  local left="$1"
  local right="$2"
  local first

  if [[ "$left" == "$right" ]]; then
    printf '0\n'
    return 0
  fi

  first="$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -n1)"
  if [[ "$first" == "$left" ]]; then
    printf -- '-1\n'
  else
    printf '1\n'
  fi
}

lock_value() {
  local file="$1"
  local name="$2"
  awk -F"'" -v name="$name" '$0 ~ "^" name "='\''" { print $2; exit }' "$file"
}

replace_lock_assignment() {
  local file="$1"
  local name="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp "${TMPDIR:-/tmp}/openwrt-lock.XXXXXXXX")"
  awk -v name="$name" -v value="$value" '
    $0 ~ "^" name "='\''" {
      print name "='\''" value "'\''"
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        exit 2
      }
    }
  ' "$file" >"$tmp" || {
    rm -f "$tmp"
    die "$file: missing lock assignment $name"
  }

  if ! cmp -s "$file" "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

rewrite_upgrade_lock() {
  local file="$1"
  local tmp
  shift

  tmp="$(mktemp "$(dirname -- "$file")/.openwrt-lock.XXXXXXXX")"
  awk \
    -v openwrt_tag="$1" \
    -v openwrt_ref="$2" \
    -v packages_ref="$3" \
    -v luci_ref="$4" \
    -v routing_ref="$5" \
    -v telephony_ref="$6" \
    -v video_ref="$7" '
    function replacement(name) {
      if (name == "OPENWRT_TAG") return openwrt_tag
      if (name == "OPENWRT_REF") return openwrt_ref
      if (name == "FEED_PACKAGES_REF") return packages_ref
      if (name == "FEED_LUCI_REF") return luci_ref
      if (name == "FEED_ROUTING_REF") return routing_ref
      if (name == "FEED_TELEPHONY_REF") return telephony_ref
      if (name == "FEED_VIDEO_REF") return video_ref
      return ""
    }
    function update(name) {
      if ($0 ~ "^" name "='\''") {
        print name "='\''" replacement(name) "'\''"
        found[name] = 1
        return 1
      }
      return 0
    }
    update("OPENWRT_TAG") ||
    update("OPENWRT_REF") ||
    update("FEED_PACKAGES_REF") ||
    update("FEED_LUCI_REF") ||
    update("FEED_ROUTING_REF") ||
    update("FEED_TELEPHONY_REF") ||
    update("FEED_VIDEO_REF") {
      next
    }
    { print }
    END {
      required[1] = "OPENWRT_TAG"
      required[2] = "OPENWRT_REF"
      required[3] = "FEED_PACKAGES_REF"
      required[4] = "FEED_LUCI_REF"
      required[5] = "FEED_ROUTING_REF"
      required[6] = "FEED_TELEPHONY_REF"
      required[7] = "FEED_VIDEO_REF"
      for (i = 1; i <= 7; i++) {
        if (!found[required[i]]) {
          print "missing lock assignment " required[i] > "/dev/stderr"
          exit 2
        }
      }
    }
  ' "$file" >"$tmp" || {
    rm -f "$tmp"
    die "$file: failed to rewrite lock assignments"
  }

  if ! cmp -s "$file" "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

install_file_atomic() {
  local source="$1"
  local destination="$2"
  local tmp

  tmp="$(mktemp "$(dirname -- "$destination")/.openwrt-upgrade.$(basename -- "$destination").XXXXXXXX")"
  cp "$source" "$tmp" || {
    rm -f "$tmp"
    die "failed to stage $destination"
  }
  mv "$tmp" "$destination"
}

fetch_json() {
  local url="$1"
  curl --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 -fsSL "$url"
}

fetch_text() {
  local url="$1"
  curl --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 -fsSL "$url"
}

run_ssh() {
  local host="$1"
  shift
  timeout 30 ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=10 \
    -o ServerAliveCountMax=2 \
    "$host" "$@"
}

git_ls_remote_one() {
  local url="$1"
  local ref="$2"
  local result

  result="$(timeout 60 git ls-remote "$url" "$ref")"
  [[ -n "$result" ]] || die "remote ref not found: $url $ref"

  printf '%s\n' "$result" | awk 'NR == 1 { print $1 }'
}

git_ls_remote_tag_commit() {
  local url="$1"
  local tag="$2"
  local result

  result="$(timeout 60 git ls-remote "$url" "refs/tags/${tag}^{}")"
  if [[ -n "$result" ]]; then
    printf '%s\n' "$result" | awk 'NR == 1 { print $1 }'
    return 0
  fi

  git_ls_remote_one "$url" "refs/tags/$tag"
}

select_latest_same_branch() {
  local overview_file="$1"
  local series="$2"
  local latest

  latest="$(
    jq -r --arg series "$series" '
      .branches[$series].versions[]? |
        select(startswith($series + ".")) |
        select(test("-rc") | not)
    ' "$overview_file" |
      sort -V |
      tail -n1
  )"
  [[ -n "$latest" ]] || die "ASU overview has no stable release for branch $series"

  printf '%s\n' "$latest"
}

read_router_release_field() {
  local release_file="$1"
  local name="$2"
  awk -F"'" -v name="$name" '$0 ~ "^" name "=" { print $2; exit }' "$release_file"
}

read_router_asu_server() {
  local host="$1"
  run_ssh "$host" "uci -q get attendedsysupgrade.server.url 2>/dev/null || true"
}

read_router_board_name() {
  local host="$1"
  run_ssh "$host" "cat /tmp/sysinfo/board_name 2>/dev/null || true"
}

feed_ref_from_buildinfo() {
  local buildinfo="$1"
  local feed_name="$2"
  local expected_url="$3"
  local fallback_ref="${4:-}"
  local line actual_url ref

  line="$(awk -v feed="$feed_name" '$1 == "src-git" && $2 == feed { print $3; exit }' "$buildinfo")"
  if [[ -z "$line" ]]; then
    if [[ -n "$fallback_ref" ]]; then
      printf '%s\n' "$fallback_ref"
      return 0
    fi
    die "feeds.buildinfo missing feed $feed_name"
  fi
  case "$line" in
    *^*) ;;
    *) die "feeds.buildinfo feed $feed_name is not pinned: $line" ;;
  esac

  actual_url="${line%%^*}"
  ref="${line#*^}"
  feed_url_matches "$feed_name" "$actual_url" "$expected_url" ||
    die "feeds.buildinfo $feed_name URL mismatch: expected $expected_url got $actual_url"
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] ||
    die "feeds.buildinfo $feed_name ref is not a full commit: $ref"

  printf '%s\n' "$ref"
}

feed_url_matches() {
  local feed_name="$1"
  local actual_url="$2"
  local expected_url="$3"

  [[ "$actual_url" == "$expected_url" ]] && return 0

  case "$feed_name:$expected_url:$actual_url" in
    packages:https://git.openwrt.org/feed/packages.git:https://github.com/openwrt/packages.git) return 0 ;;
    luci:https://git.openwrt.org/project/luci.git:https://github.com/openwrt/luci.git) return 0 ;;
    routing:https://git.openwrt.org/feed/routing.git:https://github.com/openwrt/routing.git) return 0 ;;
    telephony:https://git.openwrt.org/feed/telephony.git:https://github.com/openwrt/telephony.git) return 0 ;;
  esac

  return 1
}

profile_supports_router_board() {
  local profile_json="$1"
  local router_board="$2"

  jq -e --arg board "$router_board" '
    (.supported_devices // []) | index($board) != null
  ' "$profile_json" >/dev/null
}

write_manifest_from_apk_db() {
  local input="$1"
  local output="$2"

  awk '
    BEGIN { RS = ""; FS = "\n" }
    {
      package = ""
      version = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^P:/) package = substr($i, 3)
        if ($i ~ /^V:/) version = substr($i, 3)
      }
      if (package != "" && version != "") {
        print package " - " version
      }
    }
  ' "$input" | sort >"$output"
}

write_apk_installed_and_world() {
  local installed_list="$1"
  local world_file="$2"
  local output="$3"

  {
    cat "$installed_list"
    printf '__WORLD__\n'
    sed 's/=.*$//' "$world_file"
  } >"$output"
}

print_lock_plan() {
  local lock_file="$1"
  local openwrt_tag="$2"
  local openwrt_ref="$3"
  local packages_ref="$4"
  local luci_ref="$5"
  local routing_ref="$6"
  local telephony_ref="$7"
  local video_ref="$8"

  printf 'Would update %s:\n' "$lock_file"
  printf "  OPENWRT_TAG: '%s' -> '%s'\n" "$(lock_value "$lock_file" OPENWRT_TAG)" "$openwrt_tag"
  printf "  OPENWRT_REF: '%s' -> '%s'\n" "$(lock_value "$lock_file" OPENWRT_REF)" "$openwrt_ref"
  printf "  FEED_PACKAGES_REF: '%s' -> '%s'\n" "$(lock_value "$lock_file" FEED_PACKAGES_REF)" "$packages_ref"
  printf "  FEED_LUCI_REF: '%s' -> '%s'\n" "$(lock_value "$lock_file" FEED_LUCI_REF)" "$luci_ref"
  printf "  FEED_ROUTING_REF: '%s' -> '%s'\n" "$(lock_value "$lock_file" FEED_ROUTING_REF)" "$routing_ref"
  printf "  FEED_TELEPHONY_REF: '%s' -> '%s'\n" "$(lock_value "$lock_file" FEED_TELEPHONY_REF)" "$telephony_ref"
  printf "  FEED_VIDEO_REF: '%s' -> '%s'\n" "$(lock_value "$lock_file" FEED_VIDEO_REF)" "$video_ref"
}

TARGET_VERSION=''
ASU_SERVER=''
DRY_RUN='0'
RUN_ARGS=()
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      TARGET_VERSION="$2"
      shift 2
      ;;
    --server)
      [[ $# -ge 2 ]] || die "--server requires a value"
      ASU_SERVER="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN='1'
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      RUN_ARGS=("$@")
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

((${#POSITIONAL[@]} == 2)) || {
  usage >&2
  exit 1
}

for arg in "${RUN_ARGS[@]}"; do
  case "$arg" in
    --strict-manifest|--no-strict-manifest)
      die "do not pass $arg; prepare-openwrt-upgrade controls strict manifest mode"
      ;;
  esac
done

SSH_TARGET="${POSITIONAL[0]}"
LOCK_FILE="${POSITIONAL[1]}"
BUILD_SCRIPT="${BUILD_SCRIPT:-$SCRIPT_DIR/run-ec2-build.sh}"
[[ -n "$BUILD_SCRIPT" ]] || die "BUILD_SCRIPT must not be empty"
if [[ "$DRY_RUN" != '1' ]]; then
  if [[ "$BUILD_SCRIPT" == */* ]]; then
    [[ -x "$BUILD_SCRIPT" ]] || die "BUILD_SCRIPT is not executable: $BUILD_SCRIPT"
  else
    command -v "$BUILD_SCRIPT" >/dev/null || die "BUILD_SCRIPT is not found in PATH: $BUILD_SCRIPT"
  fi
fi

cd "$REPO_ROOT"
require_cmd awk cat cmp curl date git jq mktemp mv realpath rm sed sort ssh tail timeout

if [[ -n "$ASU_SERVER" ]]; then
  ASU_SERVER="$(trim_trailing_slash "$ASU_SERVER")"
  validate_asu_server_url "$ASU_SERVER"
fi

LOCK_FILE_ABS="$(repo_existing_path "$LOCK_FILE" 'lock file')"
[[ -f "$LOCK_FILE_ABS" ]] || die "lock file is not a regular file: $LOCK_FILE"
LOCK_FILE_REL="${LOCK_FILE_ABS#"$REPO_ROOT"/}"

lock_vars=(
  OPENWRT_REPO_URL OPENWRT_TAG OPENWRT_REF
  FEED_PACKAGES_URL FEED_PACKAGES_REF
  FEED_LUCI_URL FEED_LUCI_REF
  FEED_ROUTING_URL FEED_ROUTING_REF
  FEED_TELEPHONY_URL FEED_TELEPHONY_REF
  FEED_VIDEO_URL FEED_VIDEO_REF
  TARGET SUBTARGET DEVICE_ID CONFIG_FRAGMENT WORLD_SOURCE REFERENCE_MANIFEST
)
for var in "${lock_vars[@]}"; do
  value="$(lock_value "$LOCK_FILE_ABS" "$var")"
  printf -v "$var" '%s' "$value"
done

for var in OPENWRT_REPO_URL OPENWRT_REF FEED_PACKAGES_URL FEED_PACKAGES_REF FEED_LUCI_URL FEED_LUCI_REF FEED_ROUTING_URL FEED_ROUTING_REF FEED_TELEPHONY_URL FEED_TELEPHONY_REF FEED_VIDEO_URL FEED_VIDEO_REF TARGET SUBTARGET DEVICE_ID CONFIG_FRAGMENT WORLD_SOURCE REFERENCE_MANIFEST; do
  [[ -n "${!var:-}" ]] || die "$LOCK_FILE_REL: missing required variable $var"
done

if [[ -z "${OPENWRT_TAG:-}" ]]; then
  die "$LOCK_FILE_REL: OPENWRT_TAG is empty; latest-release preparation is only for tagged stable locks"
fi

CONFIG_FRAGMENT_ABS="$(repo_existing_path "$CONFIG_FRAGMENT" "$LOCK_FILE_REL: config fragment")"
WORLD_SOURCE_ABS="$(repo_existing_path "$WORLD_SOURCE" "$LOCK_FILE_REL: world source")"
REFERENCE_MANIFEST_ABS="$(repo_existing_path "$REFERENCE_MANIFEST" "$LOCK_FILE_REL: reference manifest")"

[[ -f "$CONFIG_FRAGMENT_ABS" ]] || die "$LOCK_FILE_REL: config fragment is not a regular file: $CONFIG_FRAGMENT"
[[ -f "$WORLD_SOURCE_ABS" ]] || die "$LOCK_FILE_REL: world source is not a regular file: $WORLD_SOURCE"
[[ -f "$REFERENCE_MANIFEST_ABS" ]] || die "$LOCK_FILE_REL: reference manifest is not a regular file: $REFERENCE_MANIFEST"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-upgrade.XXXXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ROUTER_RELEASE_FILE="$TMP_DIR/openwrt_release"
ROUTER_APK_DB="$TMP_DIR/apk-installed-db"
ROUTER_APK_LIST="$TMP_DIR/apk-list-installed"
ROUTER_WORLD="$TMP_DIR/apk-world"
OVERVIEW_JSON="$TMP_DIR/asu-overview.json"
PROFILE_JSON="$TMP_DIR/asu-profile.json"
FEEDS_BUILDINFO="$TMP_DIR/feeds.buildinfo"
CAPTURED_MANIFEST="$TMP_DIR/installed.manifest"
CAPTURED_WORLD_SOURCE="$TMP_DIR/apk-installed-and-world.txt"

log "Reading router metadata from $SSH_TARGET"
run_ssh "$SSH_TARGET" cat /etc/openwrt_release >"$ROUTER_RELEASE_FILE"
ROUTER_BOARD="$(read_router_board_name "$SSH_TARGET")"
ROUTER_RELEASE="$(read_router_release_field "$ROUTER_RELEASE_FILE" DISTRIB_RELEASE)"
ROUTER_TARGET="$(read_router_release_field "$ROUTER_RELEASE_FILE" DISTRIB_TARGET)"
[[ -n "$ROUTER_BOARD" ]] || die "could not read /tmp/sysinfo/board_name from $SSH_TARGET"
[[ -n "$ROUTER_RELEASE" ]] || die "could not read DISTRIB_RELEASE from $SSH_TARGET"
[[ -n "$ROUTER_TARGET" ]] || die "could not read DISTRIB_TARGET from $SSH_TARGET"

EXPECTED_TARGET="$TARGET/$SUBTARGET"
[[ "$ROUTER_TARGET" == "$EXPECTED_TARGET" ]] ||
  die "$LOCK_FILE_REL targets $EXPECTED_TARGET but $SSH_TARGET reports $ROUTER_TARGET"

if [[ -z "$ASU_SERVER" ]]; then
  ASU_SERVER="$(read_router_asu_server "$SSH_TARGET")"
fi
ASU_SERVER="${ASU_SERVER:-https://sysupgrade.openwrt.org}"
ASU_SERVER="$(trim_trailing_slash "$ASU_SERVER")"
validate_asu_server_url "$ASU_SERVER"

CURRENT_SERIES="${ROUTER_RELEASE%.*}"
if [[ -z "$TARGET_VERSION" ]]; then
  log "Querying ASU overview from $ASU_SERVER"
  fetch_json "$ASU_SERVER/json/v1/overview.json" >"$OVERVIEW_JSON"
  TARGET_VERSION="$(select_latest_same_branch "$OVERVIEW_JSON" "$CURRENT_SERIES")"
fi
[[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "target version must look like 25.12.4: $TARGET_VERSION"

TARGET_SERIES="${TARGET_VERSION%.*}"
[[ "$TARGET_SERIES" == "$CURRENT_SERIES" ]] ||
  die "$SSH_TARGET is on $CURRENT_SERIES; refusing cross-branch upgrade to $TARGET_VERSION"
version_cmp="$(compare_versions "$TARGET_VERSION" "$ROUTER_RELEASE")"
[[ "$version_cmp" != '-1' ]] ||
  die "$SSH_TARGET is on $ROUTER_RELEASE; refusing downgrade to $TARGET_VERSION"

log "Validating ASU profile metadata for $TARGET_VERSION $EXPECTED_TARGET $DEVICE_ID"
fetch_json "$ASU_SERVER/json/v1/releases/$TARGET_VERSION/targets/$TARGET/$SUBTARGET/$DEVICE_ID.json" >"$PROFILE_JSON"
PROFILE_VERSION="$(jq -r '.version_number // empty' "$PROFILE_JSON")"
PROFILE_CODE="$(jq -r '.version_code // empty' "$PROFILE_JSON")"
PROFILE_TARGET="$(jq -r '.target // empty' "$PROFILE_JSON")"
PROFILE_ID="$(jq -r '.id // empty' "$PROFILE_JSON")"
[[ "$PROFILE_VERSION" == "$TARGET_VERSION" ]] || die "ASU profile version mismatch: expected $TARGET_VERSION got ${PROFILE_VERSION:-empty}"
[[ "$PROFILE_TARGET" == "$EXPECTED_TARGET" ]] || die "ASU profile target mismatch: expected $EXPECTED_TARGET got ${PROFILE_TARGET:-empty}"
[[ "$PROFILE_ID" == "$DEVICE_ID" ]] || die "ASU profile id mismatch: expected $DEVICE_ID got ${PROFILE_ID:-empty}"
[[ -n "$PROFILE_CODE" ]] || die "ASU profile has no version_code"
profile_supports_router_board "$PROFILE_JSON" "$ROUTER_BOARD" ||
  die "$LOCK_FILE_REL profile $DEVICE_ID does not support router board $ROUTER_BOARD"

OPENWRT_TAG_NEW="v$TARGET_VERSION"
FEED_BRANCH="openwrt-$TARGET_SERIES"

log "Resolving OpenWrt git ref and release feed pins"
OPENWRT_REF_NEW="$(git_ls_remote_tag_commit "$OPENWRT_REPO_URL" "$OPENWRT_TAG_NEW")"
fetch_text "https://downloads.openwrt.org/releases/$TARGET_VERSION/targets/$TARGET/$SUBTARGET/feeds.buildinfo" >"$FEEDS_BUILDINFO"
FEED_PACKAGES_REF_NEW="$(feed_ref_from_buildinfo "$FEEDS_BUILDINFO" packages "$FEED_PACKAGES_URL")"
FEED_LUCI_REF_NEW="$(feed_ref_from_buildinfo "$FEEDS_BUILDINFO" luci "$FEED_LUCI_URL")"
FEED_ROUTING_REF_NEW="$(feed_ref_from_buildinfo "$FEEDS_BUILDINFO" routing "$FEED_ROUTING_URL")"
FEED_TELEPHONY_REF_NEW="$(feed_ref_from_buildinfo "$FEEDS_BUILDINFO" telephony "$FEED_TELEPHONY_URL")"
FEED_VIDEO_REF_NEW="$(feed_ref_from_buildinfo "$FEEDS_BUILDINFO" video "$FEED_VIDEO_URL" "$FEED_VIDEO_REF")"

printf 'Router release: %s\n' "$ROUTER_RELEASE"
printf 'Selected release: %s (%s)\n' "$TARGET_VERSION" "$PROFILE_CODE"
printf 'ASU server: %s\n' "$ASU_SERVER"
printf 'Target/profile: %s %s\n' "$EXPECTED_TARGET" "$DEVICE_ID"
printf 'Router board: %s\n' "$ROUTER_BOARD"
printf 'Feed branch: %s\n' "$FEED_BRANCH"

if [[ "$DRY_RUN" == '1' ]]; then
  print_lock_plan "$LOCK_FILE_ABS" "$OPENWRT_TAG_NEW" "$OPENWRT_REF_NEW" "$FEED_PACKAGES_REF_NEW" "$FEED_LUCI_REF_NEW" "$FEED_ROUTING_REF_NEW" "$FEED_TELEPHONY_REF_NEW" "$FEED_VIDEO_REF_NEW"
  printf 'Would refresh %s and %s from %s\n' "$REFERENCE_MANIFEST" "$WORLD_SOURCE" "$SSH_TARGET"
else
  log "Capturing package baseline from $SSH_TARGET"
  run_ssh "$SSH_TARGET" cat /lib/apk/db/installed >"$ROUTER_APK_DB"
  run_ssh "$SSH_TARGET" apk list --installed >"$ROUTER_APK_LIST"
  run_ssh "$SSH_TARGET" cat /etc/apk/world >"$ROUTER_WORLD"
  write_manifest_from_apk_db "$ROUTER_APK_DB" "$CAPTURED_MANIFEST"
  write_apk_installed_and_world "$ROUTER_APK_LIST" "$ROUTER_WORLD" "$CAPTURED_WORLD_SOURCE"

  install_file_atomic "$CAPTURED_MANIFEST" "$REFERENCE_MANIFEST_ABS"
  install_file_atomic "$CAPTURED_WORLD_SOURCE" "$WORLD_SOURCE_ABS"
  rewrite_upgrade_lock \
    "$LOCK_FILE_ABS" \
    "$OPENWRT_TAG_NEW" \
    "$OPENWRT_REF_NEW" \
    "$FEED_PACKAGES_REF_NEW" \
    "$FEED_LUCI_REF_NEW" \
    "$FEED_ROUTING_REF_NEW" \
    "$FEED_TELEPHONY_REF_NEW" \
    "$FEED_VIDEO_REF_NEW"
fi

if [[ "$ROUTER_RELEASE" == "$TARGET_VERSION" ]]; then
  printf 'Router is already on %s; build not started.\n' "$TARGET_VERSION"
  exit 0
fi

BUILD_CMD=("$BUILD_SCRIPT" --no-strict-manifest)
if ((${#RUN_ARGS[@]} > 0)); then
  BUILD_CMD+=("${RUN_ARGS[@]}")
fi
BUILD_CMD+=("$LOCK_FILE_REL")

printf 'Build command:'
printf ' %q' "${BUILD_CMD[@]}"
printf '\n'

if [[ "$DRY_RUN" == '1' ]]; then
  printf 'Dry run only; build not started.\n'
  exit 0
fi

trap - EXIT
cleanup
exec "${BUILD_CMD[@]}"
