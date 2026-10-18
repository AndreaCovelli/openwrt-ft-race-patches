#!/usr/bin/env bash
set -euo pipefail

umask 022

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/imagebuilder.sh
source "$SCRIPT_DIR/lib/imagebuilder.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/pin-imagebuilder.sh [--dry-run] <lock-file>

Pin the official OpenWrt SDK, ImageBuilder, and ImageBuilder repository
indexes for the lock's OPENWRT_TAG, TARGET, and SUBTARGET.

The script reads the release sha256sums, profiles.json, and feeds.buildinfo,
checks that the release feeds equal the lock feed pins and that the release
has a profile for DEVICE_ID, downloads every repository packages.adb, and
rewrites SDK_URL, SDK_SHA256, IMAGEBUILDER_URL, IMAGEBUILDER_SHA256, and
IMAGEBUILDER_REPOSITORIES. A lock without these assignments gets them
appended. Other lock assignments are left unchanged.

Options:
  --dry-run   Print the pins without rewriting the lock.
  --help      Show this message.

Environment:
  OPENWRT_DOWNLOAD_BASE_URL  Release mirror. Default: https://downloads.openwrt.org
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

fetch() {
  local url="$1"
  local dest="$2"

  curl -fsSL \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 10 \
    --max-time 300 \
    --retry 3 \
    --retry-connrefused \
    -o "$dest" \
    "$url" || die "failed to download $url"
}

DRY_RUN='0'
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
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
      POSITIONAL+=("$@")
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

[[ ${#POSITIONAL[@]} -eq 1 ]] || {
  usage >&2
  exit 1
}

require_cmd awk curl cut date jq mktemp mv sha256sum sort

LOCK_FILE="${POSITIONAL[0]}"
if [[ "$LOCK_FILE" != /* ]]; then
  LOCK_FILE="$PWD/$LOCK_FILE"
fi
[[ -f "$LOCK_FILE" ]] || die "lock file not found: $LOCK_FILE"

lock_value() {
  (
    unset OPENWRT_TAG TARGET SUBTARGET DEVICE_ID
    # shellcheck source=/dev/null
    source "$LOCK_FILE"
    printf '%s' "${!1:-}"
  )
}

OPENWRT_TAG="$(lock_value OPENWRT_TAG)"
TARGET="$(lock_value TARGET)"
SUBTARGET="$(lock_value SUBTARGET)"
DEVICE_ID="$(lock_value DEVICE_ID)"
[[ "$OPENWRT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] ||
  die "$LOCK_FILE: ImageBuilder pins need a release OPENWRT_TAG, got: ${OPENWRT_TAG:-<empty>}"
for name in TARGET SUBTARGET DEVICE_ID; do
  [[ "${!name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "$LOCK_FILE: unsupported $name: ${!name}"
done

VERSION="${OPENWRT_TAG#v}"
BASE_URL="${OPENWRT_DOWNLOAD_BASE_URL:-https://downloads.openwrt.org}"
BASE_URL="${BASE_URL%/}"
RELEASE_URL="$BASE_URL/releases/$VERSION"
TARGET_URL="$RELEASE_URL/targets/$TARGET/$SUBTARGET"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-pin-imagebuilder.XXXXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

log "Reading release metadata: $TARGET_URL"
fetch "$TARGET_URL/sha256sums" "$TMP_DIR/sha256sums"
fetch "$TARGET_URL/profiles.json" "$TMP_DIR/profiles.json"
fetch "$TARGET_URL/feeds.buildinfo" "$TMP_DIR/feeds.buildinfo"

release_archive() {
  local pattern="$1"
  local -a matches=()

  mapfile -t matches < <(
    awk -v pattern="$pattern" '{ file = $2; sub(/^\*/, "", file); if (file ~ pattern) print $1 "\t" file }' \
      "$TMP_DIR/sha256sums"
  )
  ((${#matches[@]} == 1)) ||
    die "expected one release archive matching $pattern, found ${#matches[@]}"
  [[ "${matches[0]%%$'\t'*}" =~ ^[0-9a-f]{64}$ ]] ||
    die "release sha256sums has an invalid checksum for ${matches[0]#*$'\t'}"
  printf '%s\n' "${matches[0]}"
}

archive_prefix="$VERSION-$TARGET-$SUBTARGET"
archive_prefix="${archive_prefix//./[.]}"
sdk_entry="$(release_archive "^openwrt-sdk-${archive_prefix}_[A-Za-z0-9._-]+[.]Linux-x86_64[.]tar[.]zst$")"
ib_entry="$(release_archive "^openwrt-imagebuilder-${archive_prefix}[.]Linux-x86_64[.]tar[.]zst$")"
SDK_SHA256="${sdk_entry%%$'\t'*}"
SDK_URL="$TARGET_URL/${sdk_entry#*$'\t'}"
IMAGEBUILDER_SHA256="${ib_entry%%$'\t'*}"
IMAGEBUILDER_URL="$TARGET_URL/${ib_entry#*$'\t'}"

profile_value() {
  jq -er "$1" "$TMP_DIR/profiles.json" || die "release profiles.json lacks $1"
}

[[ "$(profile_value '.version_number')" == "$VERSION" ]] ||
  die "release profiles.json is not for $VERSION"
[[ "$(profile_value '.target')" == "$TARGET/$SUBTARGET" ]] ||
  die "release profiles.json is not for $TARGET/$SUBTARGET"
jq -e --arg id "$DEVICE_ID" '.profiles | has($id)' "$TMP_DIR/profiles.json" >/dev/null ||
  die "release has no ImageBuilder profile for $DEVICE_ID"
ARCH_PACKAGES="$(profile_value '.arch_packages')"
KERNEL_VERSION="$(profile_value '.linux_kernel.version')"
KERNEL_RELEASE="$(profile_value '.linux_kernel.release')"
KERNEL_VERMAGIC="$(profile_value '.linux_kernel.vermagic')"
for value in "$ARCH_PACKAGES" "$KERNEL_VERSION" "$KERNEL_RELEASE" "$KERNEL_VERMAGIC"; do
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die "release profiles.json has an unsupported value: $value"
done

# The release must be built from exactly the lock's feed commits.
declare -A LOCK_FEED_URLS=()
declare -A LOCK_FEED_REFS=()
for feed in packages luci routing telephony video; do
  upper="${feed^^}"
  LOCK_FEED_URLS[$feed]="$(lock_value "FEED_${upper}_URL")"
  LOCK_FEED_REFS[$feed]="$(lock_value "FEED_${upper}_REF")"
done
FEEDS=()
while read -r type name source extra; do
  [[ -n "${type:-}" && "$type" != \#* ]] || continue
  [[ "$type" == 'src-git' && -z "${extra:-}" ]] ||
    die "unsupported release feed definition: $type $name $source"
  [[ -n "${LOCK_FEED_REFS[$name]:-}" ]] || die "release feed $name has no lock pin"
  [[ "$source" == "${LOCK_FEED_URLS[$name]}^${LOCK_FEED_REFS[$name]}" ]] ||
    die "release feed $name is $source, but the lock pins ${LOCK_FEED_URLS[$name]}^${LOCK_FEED_REFS[$name]}"
  FEEDS+=("$name")
done <"$TMP_DIR/feeds.buildinfo"
((${#FEEDS[@]} == ${#LOCK_FEED_REFS[@]})) ||
  die "release feeds.buildinfo lists ${#FEEDS[@]} feeds; the lock pins ${#LOCK_FEED_REFS[@]}"

# This is the ImageBuilder repositories order: target, base, kernel modules,
# then the package feeds by name.
REPOSITORY_URLS=(
  "$TARGET_URL/packages/packages.adb"
  "$RELEASE_URL/packages/$ARCH_PACKAGES/base/packages.adb"
  "$TARGET_URL/kmods/$KERNEL_VERSION-$KERNEL_RELEASE-$KERNEL_VERMAGIC/packages.adb"
)
while IFS= read -r feed; do
  REPOSITORY_URLS+=("$RELEASE_URL/packages/$ARCH_PACKAGES/$feed/packages.adb")
done < <(printf '%s\n' "${FEEDS[@]}" | LC_ALL=C sort)

REPOSITORY_ENTRIES=()
for i in "${!REPOSITORY_URLS[@]}"; do
  url="${REPOSITORY_URLS[$i]}"
  log "Hashing repository index: $url"
  fetch "$url" "$TMP_DIR/index-$i.adb"
  entry="$url|$(sha256sum "$TMP_DIR/index-$i.adb" | cut -d' ' -f1)"
  imagebuilder_parse_repository "$entry" parsed_url parsed_sha256 || exit 1
  REPOSITORY_ENTRIES+=("$entry")
done

print_pins() {
  local entry

  printf "SDK_URL='%s'\n" "$SDK_URL"
  printf "SDK_SHA256='%s'\n" "$SDK_SHA256"
  printf "IMAGEBUILDER_URL='%s'\n" "$IMAGEBUILDER_URL"
  printf "IMAGEBUILDER_SHA256='%s'\n" "$IMAGEBUILDER_SHA256"
  printf 'IMAGEBUILDER_REPOSITORIES=(\n'
  for entry in "${REPOSITORY_ENTRIES[@]}"; do
    printf "  '%s'\n" "$entry"
  done
  printf ')\n'
}

if [[ "$DRY_RUN" == '1' ]]; then
  log "Dry run; $LOCK_FILE is unchanged"
  print_pins
  exit 0
fi

# Replace the managed assignments in place, or append them as one block when
# the lock has none of them yet.
PINS_FILE="$TMP_DIR/pins"
print_pins >"$PINS_FILE"
tmp_lock="$(mktemp "$(dirname -- "$LOCK_FILE")/.openwrt-lock.XXXXXXXX")"
if ! awk -v pins_file="$PINS_FILE" '
  BEGIN {
    while ((getline line < pins_file) > 0) {
      if (line ~ /^IMAGEBUILDER_REPOSITORIES=\($/) {
        in_pins_array = 1
        array_pin = line
        continue
      }
      if (in_pins_array) {
        array_pin = array_pin "\n" line
        if (line == ")") in_pins_array = 0
        continue
      }
      name = line
      sub(/=.*/, "", name)
      pin[name] = line
    }
    pin["IMAGEBUILDER_REPOSITORIES"] = array_pin
    order[1] = "SDK_URL"
    order[2] = "SDK_SHA256"
    order[3] = "IMAGEBUILDER_URL"
    order[4] = "IMAGEBUILDER_SHA256"
    order[5] = "IMAGEBUILDER_REPOSITORIES"
  }
  skipping_array {
    if ($0 == ")") skipping_array = 0
    next
  }
  {
    for (i = 1; i <= 5; i++) {
      name = order[i]
      if (name == "IMAGEBUILDER_REPOSITORIES" && $0 == name "=(") {
        print pin[name]
        found[name] = 1
        skipping_array = 1
        next
      }
      if (name != "IMAGEBUILDER_REPOSITORIES" && index($0, name "='\''") == 1) {
        print pin[name]
        found[name] = 1
        next
      }
    }
    print
  }
  END {
    if (skipping_array) {
      print "unterminated IMAGEBUILDER_REPOSITORIES array" > "/dev/stderr"
      exit 2
    }
    count = 0
    for (i = 1; i <= 5; i++) count += found[order[i]]
    if (count == 5) exit 0
    if (count != 0) {
      print "lock has only some ImageBuilder pin assignments" > "/dev/stderr"
      exit 2
    }
    print ""
    print "# Official SDK and ImageBuilder for --build-method imagebuilder. Refresh"
    print "# with scripts/pin-imagebuilder.sh, which rewrites these assignments."
    for (i = 1; i <= 5; i++) print pin[order[i]]
  }
' "$LOCK_FILE" >"$tmp_lock"; then
  rm -f -- "$tmp_lock"
  die "$LOCK_FILE: failed to rewrite ImageBuilder pins"
fi

if ! bash -n "$tmp_lock"; then
  rm -f -- "$tmp_lock"
  die "$LOCK_FILE: rewritten lock is not valid Bash"
fi
chmod --reference="$LOCK_FILE" "$tmp_lock"
mv -f -- "$tmp_lock" "$LOCK_FILE"
log "Pinned ImageBuilder inputs in ${LOCK_FILE#"$REPO_ROOT"/}"
