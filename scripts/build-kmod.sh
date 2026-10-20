#!/usr/bin/env bash
set -euo pipefail

umask 022

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/build-name.sh
source "$SCRIPT_DIR/lib/build-name.sh"
# shellcheck source=scripts/lib/download.sh
source "$SCRIPT_DIR/lib/download.sh"
# shellcheck source=scripts/lib/imagebuilder.sh
source "$SCRIPT_DIR/lib/imagebuilder.sh"
# shellcheck source=scripts/lib/kmod.sh
source "$SCRIPT_DIR/lib/kmod.sh"

PACKAGE='kmod-mac80211'

usage() {
  cat <<EOF
Usage:
  ./scripts/build-kmod.sh [options] <openwrt-version> <target>/<subtarget>

Build a patched $PACKAGE package for an official OpenWrt release with that
release's SDK, without building a firmware image. Example:

  ./scripts/build-kmod.sh 25.12.6 mediatek/filogic

The script reads the release sha256sums and profiles.json, downloads and
verifies the SDK and the official $PACKAGE package, compiles mac80211 with
the patches, and fails unless the patched package has the official package's
file name, file list, module metadata (vermagic, depends, name), and exported
symbols. Only the module code differs.

Options:
  --patch FILE          mac80211 patch to apply. Repeatable. Default: every
                        patch in patches/<openwrt-version>/subsys, which
                        holds the patches refreshed for that release.
  --sdk-sha256 HEX      Require this SDK checksum in addition to the release
                        sha256sums entry.
  --workspace NAME      Build workspace under build/. Default:
                        openwrt-ft-kmod-<version>-<target>-<subtarget>
  --fresh               Clear an existing workspace before building.
  --artifact-dir DIR    New artifact directory (must not exist). Default:
                        openwrt-artifacts/openwrt-ft-kmod-mac80211-<version>-<target>-<subtarget>-<utc>
  --make-jobs N         Parallel make jobs. Default: nproc.
  --help                Show this message.

Environment:
  OPENWRT_DOWNLOAD_BASE_URL  Release mirror. Default: https://downloads.openwrt.org
  WORK_ROOT, CACHE_ROOT      Workspace and download cache roots. Default:
                             build and cache in this repository.
EOF
}

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
    printf '%s/%s\n' "$PWD" "$1"
  fi
}

PATCH_ARGS=()
SDK_SHA256_ARG=''
WORKSPACE_ID=''
FRESH='0'
ARTIFACT_DIR=''
MAKE_JOBS="${MAKE_JOBS:-}"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch|--sdk-sha256|--workspace|--artifact-dir|--make-jobs)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      case "$1" in
        --patch) PATCH_ARGS+=("$2") ;;
        --sdk-sha256) SDK_SHA256_ARG="$2" ;;
        --workspace) WORKSPACE_ID="$2" ;;
        --artifact-dir) ARTIFACT_DIR="$2" ;;
        --make-jobs) MAKE_JOBS="$2" ;;
      esac
      shift 2
      ;;
    --fresh)
      FRESH='1'
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

((${#POSITIONAL[@]} == 2)) || {
  usage >&2
  exit 1
}

VERSION="${POSITIONAL[0]}"
TARGET_PATH="${POSITIONAL[1]}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] ||
  die "unsupported OpenWrt release version: $VERSION"
[[ "$TARGET_PATH" =~ ^([A-Za-z0-9_-]+)/([A-Za-z0-9_-]+)$ ]] ||
  die "target must be <target>/<subtarget>: $TARGET_PATH"
TARGET="${BASH_REMATCH[1]}"
SUBTARGET="${BASH_REMATCH[2]}"
[[ -z "$SDK_SHA256_ARG" || "$SDK_SHA256_ARG" =~ ^[0-9a-f]{64}$ ]] ||
  die '--sdk-sha256 must be a 64-character lowercase hex checksum'
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
[[ "$MAKE_JOBS" =~ ^[1-9][0-9]*$ ]] || die "--make-jobs must be a positive integer: $MAKE_JOBS"

require_cmd awk cmp comm cp curl date diff find git grep install jq make mktemp mv nproc patch readelf realpath sed sha256sum sort tar tee tr wc zstd

if ((${#PATCH_ARGS[@]} == 0)); then
  DEFAULT_PATCH_DIR="patches/$VERSION/subsys"
  mapfile -t PATCH_ARGS < <(
    find "$REPO_ROOT/$DEFAULT_PATCH_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.patch' 2>/dev/null | LC_ALL=C sort
  )
  ((${#PATCH_ARGS[@]} > 0)) ||
    die "no mac80211 patches for OpenWrt $VERSION in $DEFAULT_PATCH_DIR; refresh the patch for this release or pass --patch"
fi
PATCH_FILES=()
declare -A PATCH_NAMES=()
for patch_arg in "${PATCH_ARGS[@]}"; do
  patch_file="$(abs_path "$patch_arg")"
  [[ -f "$patch_file" ]] || die "patch file not found: $patch_arg"
  patch_name="$(basename -- "$patch_file")"
  [[ "$patch_name" =~ ^[0-9]{3}-[A-Za-z0-9._-]+\.patch$ ]] ||
    die "patch file name must look like NNN-name.patch: $patch_name"
  [[ -z "${PATCH_NAMES[$patch_name]:-}" ]] || die "duplicate patch file name: $patch_name"
  PATCH_NAMES[$patch_name]=1
  PATCH_FILES+=("$patch_file")
done

WORKSPACE_ID="${WORKSPACE_ID:-openwrt-ft-kmod-$VERSION-$TARGET-$SUBTARGET}"
openwrt_build_name_require_component workspace "$WORKSPACE_ID" || exit 1
[[ "$WORKSPACE_ID" != '.' && "$WORKSPACE_ID" != '..' ]] || die "unsupported workspace: $WORKSPACE_ID"
WORK_ROOT="$(realpath -m -- "${WORK_ROOT:-$REPO_ROOT/build}")"
CACHE_ROOT="$(realpath -m -- "${CACHE_ROOT:-$REPO_ROOT/cache}")"
DL_DIR="${DL_DIR:-$CACHE_ROOT/dl}"
BUILD_ROOT="$WORK_ROOT/$WORKSPACE_ID"
SDK_DIR="$BUILD_ROOT/sdk"
RELEASE_DIR="$BUILD_ROOT/release"
REPORT_DIR="$BUILD_ROOT/reports"
OUTPUT_DIR="$BUILD_ROOT/output"
BUILD_LOG="$BUILD_ROOT/build.log"

BUILD_TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="$REPO_ROOT/openwrt-artifacts/openwrt-ft-kmod-mac80211-$VERSION-$TARGET-$SUBTARGET-$BUILD_TIMESTAMP"
fi
ARTIFACT_DIR="$(realpath -m -- "$ARTIFACT_DIR")"
[[ ! -e "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] ||
  die "artifact directory already exists: $ARTIFACT_DIR"
for root in "$BUILD_ROOT" "$CACHE_ROOT"; do
  [[ "$ARTIFACT_DIR/" != "$root/"* ]] ||
    die "artifact directory must be outside $root: $ARTIFACT_DIR"
done

[[ ! -L "$BUILD_ROOT" ]] || die "workspace must not be a symbolic link: $BUILD_ROOT"
if [[ -e "$BUILD_ROOT" && -n "$(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  [[ "$FRESH" == '1' ]] || die "workspace is not empty: $BUILD_ROOT; rerun with --fresh"
  [[ -d "$BUILD_ROOT" ]] || die "workspace is not a directory: $BUILD_ROOT"
  # Clear the contents only; the workspace may be a mount point.
  find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi
mkdir -p "$BUILD_ROOT" "$RELEASE_DIR" "$REPORT_DIR" "$OUTPUT_DIR/metadata" "$DL_DIR"

exec > >(tee -a "$BUILD_LOG") 2>&1

BASE_URL="${OPENWRT_DOWNLOAD_BASE_URL:-https://downloads.openwrt.org}"
BASE_URL="${BASE_URL%/}"
TARGET_URL="$BASE_URL/releases/$VERSION/targets/$TARGET/$SUBTARGET"

log "Release: $VERSION $TARGET/$SUBTARGET"
log "Workspace: $BUILD_ROOT"
log "Reading release metadata: $TARGET_URL"
download_https "$TARGET_URL/sha256sums" "$RELEASE_DIR/sha256sums" || exit 1
download_https "$TARGET_URL/profiles.json" "$RELEASE_DIR/profiles.json" || exit 1

profile_value() {
  jq -er "$1" "$RELEASE_DIR/profiles.json" || die "release profiles.json lacks $1"
}

[[ "$(profile_value '.version_number')" == "$VERSION" ]] ||
  die "release profiles.json is not for $VERSION"
[[ "$(profile_value '.target')" == "$TARGET/$SUBTARGET" ]] ||
  die "release profiles.json is not for $TARGET/$SUBTARGET"
KERNEL_VERSION="$(profile_value '.linux_kernel.version')"
KERNEL_RELEASE="$(profile_value '.linux_kernel.release')"
KERNEL_VERMAGIC="$(profile_value '.linux_kernel.vermagic')"
for value in "$KERNEL_VERSION" "$KERNEL_RELEASE" "$KERNEL_VERMAGIC"; do
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die "release profiles.json has an unsupported value: $value"
done
KMODS_DIR="kmods/$KERNEL_VERSION-$KERNEL_RELEASE-$KERNEL_VERMAGIC"

release_prefix="$(kmod_regex_escape "$VERSION-$TARGET-$SUBTARGET")"
sdk_entry="$(kmod_release_entry "$RELEASE_DIR/sha256sums" \
  "^openwrt-sdk-${release_prefix}_[A-Za-z0-9._-]+[.]Linux-x86_64[.]tar[.]zst$")" || exit 1
SDK_SHA256="${sdk_entry%%$'\t'*}"
SDK_FILE="${sdk_entry#*$'\t'}"
SDK_URL="$TARGET_URL/$SDK_FILE"
if [[ -n "$SDK_SHA256_ARG" && "$SDK_SHA256_ARG" != "$SDK_SHA256" ]]; then
  die "release SDK checksum is $SDK_SHA256, but --sdk-sha256 requires $SDK_SHA256_ARG"
fi

official_entry="$(kmod_release_entry "$RELEASE_DIR/sha256sums" \
  "^$(kmod_regex_escape "$KMODS_DIR")/$PACKAGE-[0-9][A-Za-z0-9._~+-]*[.]apk$")" || exit 1
OFFICIAL_SHA256="${official_entry%%$'\t'*}"
OFFICIAL_PATH="${official_entry#*$'\t'}"
OFFICIAL_FILE="$(basename -- "$OFFICIAL_PATH")"
OFFICIAL_APK="$RELEASE_DIR/$OFFICIAL_FILE"

log "Fetching official $PACKAGE package: $OFFICIAL_FILE"
download_verified_file "$TARGET_URL/$OFFICIAL_PATH" "$OFFICIAL_APK" "$OFFICIAL_SHA256" || exit 1
log "Fetching OpenWrt SDK: $SDK_FILE"
download_verified_file "$SDK_URL" "$DL_DIR/$SDK_FILE" "$SDK_SHA256" || exit 1

log "Extracting OpenWrt SDK"
mkdir -p "$SDK_DIR"
tar --zstd -xf "$DL_DIR/$SDK_FILE" -C "$SDK_DIR" --strip-components=1 --no-same-owner

read -r OPENWRT_REPO_URL OPENWRT_REF < <(kmod_sdk_base_feed "$SDK_DIR/feeds.conf.default" || printf '\n')
[[ -n "${OPENWRT_REF:-}" ]] || die 'failed to read the SDK base feed'
log "SDK base feed: $OPENWRT_REPO_URL^$OPENWRT_REF"
printf 'src-git --root=package base %s^%s\n' "$OPENWRT_REPO_URL" "$OPENWRT_REF" >"$SDK_DIR/feeds.conf"
(
  cd "$SDK_DIR"
  ./scripts/feeds update base
)
actual_ref="$(git -C "$SDK_DIR/feeds/base_root" rev-parse HEAD)"
[[ "$actual_ref" == "$OPENWRT_REF" ]] ||
  die "SDK base feed is at $actual_ref, expected $OPENWRT_REF"
(
  cd "$SDK_DIR"
  ./scripts/feeds install mac80211
)

PATCH_DIR="$SDK_DIR/feeds/base/kernel/mac80211/patches/subsys"
[[ -d "$PATCH_DIR" ]] || die "SDK mac80211 package has no subsys patch directory: $PATCH_DIR"
: >"$OUTPUT_DIR/metadata/patches.tsv"
for patch_file in "${PATCH_FILES[@]}"; do
  patch_name="$(basename -- "$patch_file")"
  [[ ! -e "$PATCH_DIR/$patch_name" ]] ||
    die "the release already ships a mac80211 patch named $patch_name"
  log "Adding mac80211 patch: $patch_name"
  install -m 0644 "$patch_file" "$PATCH_DIR/$patch_name"
  cp -- "$patch_file" "$OUTPUT_DIR/metadata/$patch_name"
  printf '%s\t%s\n' "$patch_name" "$(download_sha256 "$patch_file")" >>"$OUTPUT_DIR/metadata/patches.tsv"
done

# The SDK's Config-build.in carries the release package selection, so
# defconfig builds mac80211 with the release package options.
log "Writing SDK config"
(
  cd "$SDK_DIR"
  make defconfig
)
grep -Eqx "CONFIG_PACKAGE_$PACKAGE=[my]" "$SDK_DIR/.config" ||
  die "SDK config does not select $PACKAGE"
cp -- "$SDK_DIR/.config" "$OUTPUT_DIR/metadata/sdk.config"

make_args=(NO_DEPS=1 DL_DIR="$DL_DIR" CONFIG_BUILD_LOG=y)
# Packaging checks each module's dependencies against the files its
# dependency packages provide, so package the SDK kernel modules first.
log "Packaging SDK kernel modules"
(
  cd "$SDK_DIR"
  make -j"$MAKE_JOBS" "${make_args[@]}" package/linux/compile
)
log "Compiling mac80211"
(
  cd "$SDK_DIR"
  make -j"$MAKE_JOBS" "${make_args[@]}" package/mac80211/compile
)

# A patch that applies reverses cleanly in the prepared source tree.
mapfile -t backports_dirs < <(find "$SDK_DIR/build_dir" -mindepth 3 -maxdepth 3 -type d -name 'backports-*')
((${#backports_dirs[@]} == 1)) ||
  die "expected one mac80211 build directory, found ${#backports_dirs[@]}"
for patch_file in "${PATCH_FILES[@]}"; do
  patch -R --dry-run -f -s -p1 -d "${backports_dirs[0]}" <"$patch_file" >/dev/null ||
    die "mac80211 build directory does not contain $(basename -- "$patch_file")"
done

PATCHED_APK="$(imagebuilder_find_package_apk "$SDK_DIR/bin/targets/$TARGET/$SUBTARGET/packages" "$PACKAGE")" ||
  die "SDK did not build $PACKAGE"
[[ "$(basename -- "$PATCHED_APK")" == "$OFFICIAL_FILE" ]] ||
  die "SDK built $(basename -- "$PATCHED_APK"), but the release ships $OFFICIAL_FILE"

APK_TOOL="$SDK_DIR/staging_dir/host/bin/apk"
[[ -x "$APK_TOOL" ]] || die "SDK has no apk tool: $APK_TOOL"
for kind in official patched; do
  if [[ "$kind" == 'official' ]]; then
    apk_file="$OFFICIAL_APK"
  else
    apk_file="$PATCHED_APK"
  fi
  mkdir -p "$REPORT_DIR/$kind"
  "$APK_TOOL" extract --allow-untrusted --no-chown \
    --destination "$REPORT_DIR/$kind" "$apk_file" >/dev/null
  kmod_tree_listing "$REPORT_DIR/$kind" >"$REPORT_DIR/$kind.files"
done

log "Comparing the patched package with the official package"
if ! cmp -s "$REPORT_DIR/official.files" "$REPORT_DIR/patched.files"; then
  diff -u "$REPORT_DIR/official.files" "$REPORT_DIR/patched.files" >&2 || true
  die 'patched package file list differs from the official package'
fi

MODULES=()
changed_modules=0
: >"$REPORT_DIR/new-imports.txt"
while IFS=$'\t' read -r path entry_type; do
  [[ "$entry_type" == 'f' && "$path" == *.ko ]] || continue
  MODULES+=("$path")
  official_ko="$REPORT_DIR/official/$path"
  patched_ko="$REPORT_DIR/patched/$path"
  for check in modinfo exports; do
    "kmod_$check" "$official_ko" >"$REPORT_DIR/official.$check"
    "kmod_$check" "$patched_ko" >"$REPORT_DIR/patched.$check"
    if ! cmp -s "$REPORT_DIR/official.$check" "$REPORT_DIR/patched.$check"; then
      diff -u "$REPORT_DIR/official.$check" "$REPORT_DIR/patched.$check" >&2 || true
      die "patched $path $check differs from the official module"
    fi
  done
  grep -q '^vermagic=' "$REPORT_DIR/official.modinfo" || die "official $path has no vermagic"
  # New imports must be exported by the official kernel or modules; record
  # them for review.
  kmod_imports "$official_ko" >"$REPORT_DIR/official.imports"
  kmod_imports "$patched_ko" >"$REPORT_DIR/patched.imports"
  LC_ALL=C comm -13 "$REPORT_DIR/official.imports" "$REPORT_DIR/patched.imports" |
    sed "s|^|$path\t|" >>"$REPORT_DIR/new-imports.txt"
  cmp -s "$official_ko" "$patched_ko" || changed_modules=$((changed_modules + 1))
done <"$REPORT_DIR/official.files"
((${#MODULES[@]} > 0)) || die "official $PACKAGE package has no kernel modules"
((changed_modules > 0)) || die 'patched modules are identical to the official modules'
new_imports="$(wc -l <"$REPORT_DIR/new-imports.txt" | tr -d ' ')"
if ((new_imports > 0)); then
  log "Patched modules import symbols the official modules do not:"
  cat "$REPORT_DIR/new-imports.txt"
fi

mapfile -t mac80211_modules < <(printf '%s\n' "${MODULES[@]}" | grep -E '(^|/)mac80211\.ko$')
((${#mac80211_modules[@]} == 1)) || die "expected one mac80211.ko in $PACKAGE, found ${#mac80211_modules[@]}"
MODULE_PATH="${mac80211_modules[0]}"
vermagic="$(kmod_modinfo "$REPORT_DIR/patched/$MODULE_PATH" | sed -n 's/^vermagic=//p')"

cp -- "$PATCHED_APK" "$OUTPUT_DIR/"
cp -- "$REPORT_DIR/patched/$MODULE_PATH" "$OUTPUT_DIR/mac80211.ko"
(
  cd "$OUTPUT_DIR"
  sha256sum "$OFFICIAL_FILE" mac80211.ko >sha256sums.txt
)
cp -- "$RELEASE_DIR/sha256sums" "$OUTPUT_DIR/metadata/release-sha256sums"
cp -- "$RELEASE_DIR/profiles.json" "$OUTPUT_DIR/metadata/profiles.json"
cp -- "$REPORT_DIR/new-imports.txt" "$OUTPUT_DIR/metadata/new-imports.txt"

cat >"$OUTPUT_DIR/build-summary.txt" <<EOF
openwrt_version=${VERSION}
target=${TARGET}/${SUBTARGET}
openwrt_ref=${OPENWRT_REF}
sdk_url=${SDK_URL}
sdk_sha256=${SDK_SHA256}
kernel=${KERNEL_VERSION}-${KERNEL_RELEASE}-${KERNEL_VERMAGIC}
vermagic=${vermagic}
package=${OFFICIAL_FILE}
patched_package_sha256=$(download_sha256 "$PATCHED_APK")
official_package_url=${TARGET_URL}/${OFFICIAL_PATH}
official_package_sha256=${OFFICIAL_SHA256}
module_path=/${MODULE_PATH}
patched_module_sha256=$(download_sha256 "$REPORT_DIR/patched/$MODULE_PATH")
official_module_sha256=$(download_sha256 "$REPORT_DIR/official/$MODULE_PATH")
patches_tsv=metadata/patches.tsv
new_imports=${new_imports}
build_log=logs/build.log
EOF

log "Publishing artifacts"
mkdir -p -- "$(dirname -- "$ARTIFACT_DIR")"
ARTIFACT_STAGING_DIR="$(mktemp -d "$(dirname -- "$ARTIFACT_DIR")/.openwrt-ft-kmod.XXXXXXXX")"
trap 'rm -rf -- "$ARTIFACT_STAGING_DIR"' EXIT
cp -a -- "$OUTPUT_DIR/." "$ARTIFACT_STAGING_DIR/"
(
  cd "$ARTIFACT_STAGING_DIR"
  sha256sum -c --quiet sha256sums.txt
)
mkdir -p "$ARTIFACT_STAGING_DIR/logs"
log "Artifact directory: $ARTIFACT_DIR"
cp -- "$BUILD_LOG" "$ARTIFACT_STAGING_DIR/logs/build.log"
# -T prevents nesting into a directory created while the build ran.
mv -T --no-clobber -- "$ARTIFACT_STAGING_DIR" "$ARTIFACT_DIR"
[[ ! -d "$ARTIFACT_STAGING_DIR" ]] ||
  die "artifact destination appeared during the build: $ARTIFACT_DIR"
