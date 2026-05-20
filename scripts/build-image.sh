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

if [[ $# -gt 1 ]]; then
  printf 'usage: %s [lock-file]\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  LOCK_FILE="$1"
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

disable_ccache_config() {
  printf '# CONFIG_CCACHE is not set\n' >>"$OPENWRT_DIR/.config"
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

require_cmd awk comm cp curl cut find git head install join make mkdir mktemp mv nproc sed sha256sum sort tee xargs

PATCH_SOURCE_ABS="$(abs_path "$PATCH_SOURCE")"
CONFIG_FRAGMENT_ABS="$(abs_path "$CONFIG_FRAGMENT")"
WORLD_SOURCE_ABS="$(abs_path "$WORLD_SOURCE")"
REFERENCE_MANIFEST_ABS="$(abs_path "$REFERENCE_MANIFEST")"

[[ -f "$PATCH_SOURCE_ABS" ]] || die "patch file not found: $PATCH_SOURCE_ABS"
[[ -f "$CONFIG_FRAGMENT_ABS" ]] || die "config fragment not found: $CONFIG_FRAGMENT_ABS"
[[ -f "$WORLD_SOURCE_ABS" ]] || die "world source not found: $WORLD_SOURCE_ABS"
[[ -f "$REFERENCE_MANIFEST_ABS" ]] || die "reference manifest not found: $REFERENCE_MANIFEST_ABS"
verify_local_feed_digests

WORK_ROOT="${WORK_ROOT:-$REPO_ROOT/$DEFAULT_WORK_ROOT}"
CACHE_ROOT="${CACHE_ROOT:-$REPO_ROOT/$DEFAULT_CACHE_ROOT}"
BUILD_ID="${BUILD_ID:-$(openwrt_default_build_name)}"
BUILD_ROOT="$WORK_ROOT/$BUILD_ID"
OPENWRT_DIR="$BUILD_ROOT/openwrt"
REPORT_DIR="$BUILD_ROOT/reports"
OUTPUT_DIR="$BUILD_ROOT/output"
METADATA_DIR="$OUTPUT_DIR/metadata"
LOG_DIR="$OUTPUT_DIR/logs"
BUILD_LOG="$LOG_DIR/build.log"
OPENWRT_LOG_OUTPUT_DIR="$LOG_DIR/openwrt"

MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-$DEFAULT_DOWNLOAD_JOBS}"

export DL_DIR="${DL_DIR:-$CACHE_ROOT/dl}"

[[ ! -e "$BUILD_ROOT" ]] || die "build root already exists: $BUILD_ROOT"

mkdir -p "$WORK_ROOT" "$CACHE_ROOT" "$DL_DIR" "$REPORT_DIR" "$OUTPUT_DIR" "$METADATA_DIR" "$LOG_DIR"
: >"$BUILD_LOG"

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

log "Build root: $BUILD_ROOT"
log "Build log: $BUILD_LOG"
download_prebuilt_apks
log "Cloning OpenWrt core"
git clone "$OPENWRT_REPO_URL" "$OPENWRT_DIR"
git -C "$OPENWRT_DIR" checkout --detach "$OPENWRT_REF"
verify_checkout "$OPENWRT_DIR" "$OPENWRT_REF"
verify_not_shallow "$OPENWRT_DIR"

if [[ -n "${OPENWRT_TAG:-}" ]]; then
  tag_ref="$(git -C "$OPENWRT_DIR" rev-list -n1 "$OPENWRT_TAG")"
  [[ "$tag_ref" == "$OPENWRT_REF" ]] || die "tag $OPENWRT_TAG does not resolve to $OPENWRT_REF"
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

log "Applying pinned FT patch"
verify_sha256 "$PATCH_SOURCE_ABS" "$PATCH_SHA256"
install -D -m 0644 "$PATCH_SOURCE_ABS" "$OPENWRT_DIR/$PATCH_DEST"

log "Writing device config"
cp "$CONFIG_FRAGMENT_ABS" "$OPENWRT_DIR/.config"
append_extra_config
disable_ccache_config

(
  cd "$OPENWRT_DIR"
  make defconfig
)

cp "$OPENWRT_DIR/.config" "$REPORT_DIR/final.config"
extract_world >"$REPORT_DIR/reference.world"
[[ -s "$REPORT_DIR/reference.world" ]] || die "failed to extract world entries from $WORLD_SOURCE_ABS"

log "Downloading sources"
(
  cd "$OPENWRT_DIR"
  make download -j"$DOWNLOAD_JOBS"
)

log "Building image"
(
  cd "$OPENWRT_DIR"
  make -j"$MAKE_JOBS"
)
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
write_manifest_builtin_package_names | sort -u >"$REPORT_DIR/builtin-package-names.txt"
write_local_feed_digests | sort >"$REPORT_DIR/local-feed-digests.tsv"
write_prebuilt_apk_digests | sort >"$REPORT_DIR/prebuilt-apks.tsv"
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
cp "$PATCH_SOURCE_ABS" "$METADATA_DIR/$(basename "$PATCH_SOURCE_ABS")"
cp "$REFERENCE_MANIFEST_ABS" "$METADATA_DIR/reference.manifest"
cp "$REPORT_DIR/reference.world" "$METADATA_DIR/reference.world"
cp "$REPORT_DIR/final.config" "$METADATA_DIR/final.config"
cp "$REPORT_DIR/builtin-package-names.txt" "$METADATA_DIR/builtin-package-names.txt"
cp "$REPORT_DIR/local-feed-digests.tsv" "$METADATA_DIR/local-feed-digests.tsv"
cp "$REPORT_DIR/prebuilt-apks.tsv" "$METADATA_DIR/prebuilt-apks.tsv"

sysupgrade_sha="$(sha256sum "$SYSUPGRADE_IMAGE" | awk '{print $1}')"
initramfs_sha="$(sha256sum "$INITRAMFS_IMAGE" | awk '{print $1}')"
openwrt_logs_rel=''
if [[ -d "$OPENWRT_LOG_OUTPUT_DIR" ]]; then
  openwrt_logs_rel='logs/openwrt'
fi

cat >"$REPORT_DIR/build-summary.txt" <<EOF
build_id=${BUILD_ID}
build_root=${BUILD_ROOT}
lock_file=$(basename "$LOCK_FILE")
openwrt_ref=${OPENWRT_REF}
openwrt_tag=${OPENWRT_TAG}
packages_ref=${FEED_PACKAGES_REF}
luci_ref=${FEED_LUCI_REF}
routing_ref=${FEED_ROUTING_REF}
telephony_ref=${FEED_TELEPHONY_REF}
video_ref=${FEED_VIDEO_REF}
patch_sha256=${PATCH_SHA256}
builder_platform=${BUILDER_PLATFORM:-unknown}
build_log=logs/build.log
openwrt_logs=${openwrt_logs_rel}
sysupgrade_image=$(basename "$SYSUPGRADE_IMAGE")
sysupgrade_sha256=${sysupgrade_sha}
initramfs_image=$(basename "$INITRAMFS_IMAGE")
initramfs_sha256=${initramfs_sha}
strict_manifest=${STRICT_MANIFEST_MODE}
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

log "Build complete"
log "Output directory: $OUTPUT_DIR"
log "Report directory: $REPORT_DIR"
