#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
builder="$repo_root/scripts/build-image.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-imagebuilder.XXXXXXXX")"
source_repo="$tmp_root/openwrt-source"
archive_root="$tmp_root/archives"
work_root="$tmp_root/work"
cache_root="$tmp_root/cache"
input_root="$tmp_root/inputs"
lock_file="$tmp_root/build.lock"
workspace_id='test-device-ib'
workspace="$work_root/$workspace_id"
download_base='https://downloads.example.invalid/releases/test/targets/test/sub'

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

assert_file_line() {
  local file="$1"
  local line="$2"
  local message="$3"

  grep -Fqx -- "$line" "$file" || die "$message"
}

# shellcheck source=scripts/lib/imagebuilder.sh
. "$repo_root/scripts/lib/imagebuilder.sh"
# shellcheck source=scripts/lib/local-feeds.sh
. "$repo_root/scripts/lib/local-feeds.sh"

# Helper self-tests.
parsed_url=''
parsed_sha256=''
imagebuilder_parse_repository \
  "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb|$(printf '%064d' 0)" \
  parsed_url parsed_sha256 || die 'valid repository entry was rejected'
[[ "$parsed_url" == https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base/packages.adb &&
  "$parsed_sha256" == "$(printf '%064d' 0)" ]] || die 'repository entry was split incorrectly'
for bad_entry in \
  "http://downloads.openwrt.org/x/packages.adb|$(printf '%064d' 0)" \
  "https://downloads.openwrt.org/x/Packages.gz|$(printf '%064d' 0)" \
  'https://downloads.openwrt.org/x/packages.adb|ABC' \
  "https://downloads.openwrt.org/x/packages.adb|$(printf '%064d' 0)|extra" \
  'https://downloads.openwrt.org/x/packages.adb'; do
  if imagebuilder_parse_repository "$bad_entry" parsed_url parsed_sha256 2>/dev/null; then
    die "invalid repository entry was accepted: $bad_entry"
  fi
done

expected_cache_name="APKINDEX.$(printf '%s' 'https://example.invalid/a/packages.adb' | sha256sum | cut -c1-8).tar.gz"
[[ "$(imagebuilder_index_cache_name 'https://example.invalid/a/packages.adb')" == "$expected_cache_name" ]] ||
  die 'apk index cache name does not use the URL digest'

mkdir -p "$source_repo/package/kernel/mac80211" "$input_root" "$archive_root" \
  "$cache_root/dl" "$cache_root/imagebuilder/indexes"

cat >"$tmp_root/info.txt" <<'INFO'
Current Target: "test/sub"
Current Architecture: "aarch64"
Current Revision: "r1-test"
Default Packages: base dropbear-fake top-fake
Available Profiles:

other-device:
    Other Device
    Packages: other-only
fake-device:
    Fake Device
    Packages: kmod-fake-usb -removed-default
    hasImageMetadata: 1
INFO

cat >"$tmp_root/packageinfo" <<'PACKAGEINFO'
Package: base

Package: dropbear-fake

Package: fakesteer

Package: htop
Provides: top-fake @top-alias=1

Package: kmod-fake-usb

Package: kmod-mac80211

Package: kmod-mac80211-hwsim
PACKAGEINFO

printf 'kernel\t-\nbase\tbase\nhtop\thtop\nfakesteer\tfakesteer\n' >"$tmp_root/resolved.tsv"
removals="$(imagebuilder_default_removals "$tmp_root/info.txt" fake-device "$tmp_root/packageinfo" "$tmp_root/resolved.tsv")"
[[ "$removals" == $'-dropbear-fake\n-kmod-fake-usb' ]] ||
  die "unexpected ImageBuilder default removals: $removals"
if imagebuilder_info_profile_packages "$tmp_root/info.txt" missing-device >/dev/null; then
  die 'missing ImageBuilder profile was accepted'
fi
[[ "$(imagebuilder_info_profile_packages "$tmp_root/info.txt" other-device)" == 'other-only' ]] ||
  die 'profile package parsing crossed into another profile'

mkdir -p "$tmp_root/apk-dir"
: >"$tmp_root/apk-dir/kmod-mac80211-1.0-r1.apk"
: >"$tmp_root/apk-dir/kmod-mac80211-hwsim-1.0-r1.apk"
[[ "$(imagebuilder_find_package_apk "$tmp_root/apk-dir" kmod-mac80211)" == "$tmp_root/apk-dir/kmod-mac80211-1.0-r1.apk" ]] ||
  die 'package apk lookup matched a package with a longer name'
: >"$tmp_root/apk-dir/kernel-6.12.94~abc-r1.apk"
[[ "$(imagebuilder_kernel_version "$tmp_root/apk-dir")" == '6.12.94~abc-r1' ]] ||
  die 'kernel version was not read from the kernel package name'

# Fake OpenWrt source for the SDK base feed.
git -C "$source_repo" init -q
printf 'mac80211 package\n' >"$source_repo/package/kernel/mac80211/Makefile"
git -C "$source_repo" add .
git -C "$source_repo" \
  -c user.name='ImageBuilder CI' \
  -c user.email='imagebuilder@example.invalid' \
  commit -q -m 'seed fake OpenWrt'
git -C "$source_repo" tag vtest
openwrt_ref="$(git -C "$source_repo" rev-parse HEAD)"
feed_ref() {
  printf '%s' "$1" | sha1sum | cut -c1-40
}

# Fake apk packages are plain tar archives; the fake ImageBuilder apk tool
# extracts them with tar.
make_apk() {
  local dest="$1"
  local path="$2"
  local content="$3"
  local dir

  dir="$(mktemp -d "$tmp_root/apk.XXXXXXXX")"
  mkdir -p "$dir/$(dirname -- "$path")"
  printf '%s\n' "$content" >"$dir/$path"
  tar -cf "$dest" -C "$dir" .
  rm -rf "$dir"
}

sdk_tree="$archive_root/openwrt-sdk-test"
mkdir -p "$sdk_tree/scripts"
cat >"$sdk_tree/scripts/feeds" <<'FEEDS'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  update)
    [[ "${2:-}" == 'base' ]]
    [[ "$(wc -l <feeds.conf)" == '1' ]]
    read -r _kind _root name pinned <feeds.conf
    [[ "$name" == 'base' ]]
    printf 'feeds-update %s\n' "$name" >>feeds-calls.log
    mkdir -p feeds
    git clone -q "${pinned%%^*}" feeds/base_root
    git -C feeds/base_root checkout -q --detach "${pinned#*^}"
    ln -s base_root/package feeds/base
    ;;
  install)
    printf 'feeds-install %s\n' "$2" >>feeds-calls.log
    ;;
  *)
    printf 'unexpected feeds command: %s\n' "$*" >&2
    exit 1
    ;;
esac
FEEDS
chmod +x "$sdk_tree/scripts/feeds"

cat >"$sdk_tree/Makefile" <<'MAKEFILE'
PKG_DIR := bin/targets/test/sub/packages

.PHONY: defconfig package/linux/compile package/mac80211/clean package/mac80211/compile

defconfig:
	@printf 'defconfig\n' >>make-calls.log
	@printf 'CONFIG_SDK=y\nCONFIG_PACKAGE_kmod-mac80211=m\n' >.config
	@printf 'CONFIG_PACKAGE_MAC80211_MESH=y\n# CONFIG_PACKAGE_MAC80211_TRACING is not set\n' >>.config

package/linux/compile:
	@printf 'linux-compile NO_DEPS=%s\n' '$(NO_DEPS)' >>make-calls.log

package/mac80211/clean:
	@printf 'mac80211-clean\n' >>make-calls.log
	@rm -f $(PKG_DIR)/kmod-mac80211-*.apk

package/mac80211/compile:
	@printf 'mac80211-compile NO_DEPS=%s\n' '$(NO_DEPS)' >>make-calls.log
	@rm -rf tmp-pkg
	@mkdir -p tmp-pkg/lib/modules/fake $(PKG_DIR)
	@cat feeds/base/kernel/mac80211/patches/subsys/*.patch >tmp-pkg/lib/modules/fake/mac80211.ko
	@tar -cf $(PKG_DIR)/kmod-mac80211-1.0-r1.apk -C tmp-pkg .
	@printf 'hwsim\n' >$(PKG_DIR)/kmod-mac80211-hwsim-1.0-r1.apk
MAKEFILE

ib_tree="$archive_root/openwrt-imagebuilder-test"
mkdir -p "$ib_tree/packages" "$ib_tree/remote" "$ib_tree/staging_dir/host/bin"
cp "$tmp_root/info.txt" "$ib_tree/info.txt"
cp "$tmp_root/packageinfo" "$ib_tree/.packageinfo"
{
  printf 'CONFIG_TARGET_test=y\nCONFIG_SIGNATURE_CHECK=y\n'
  printf '# CONFIG_PACKAGE_MAC80211_TRACING is not set\nCONFIG_PACKAGE_MAC80211_MESH=y\n'
} >"$ib_tree/.config"
make_apk "$ib_tree/packages/kernel-6.12.94~abc-r1.apk" boot/kernel 'official kernel'
make_apk "$ib_tree/remote/base-1.0-r1.apk" etc/base 'base'
make_apk "$ib_tree/remote/htop-3.4.1-r1.apk" usr/bin/htop 'htop'
make_apk "$ib_tree/remote/dropbear-fake-1.0-r1.apk" usr/sbin/dropbear 'dropbear'
make_apk "$ib_tree/remote/kmod-fake-usb-1.0-r1.apk" lib/modules/fake/usb.ko 'usb'
make_apk "$ib_tree/remote/kmod-mac80211-1.0-r1.apk" lib/modules/fake/mac80211.ko 'official mac80211'
make_apk "$ib_tree/remote/fakesteer-1.0-r1.apk" usr/sbin/fakesteer 'official fakesteer'

cat >"$ib_tree/staging_dir/host/bin/apk" <<'APK'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == 'extract' ]]
shift
dest=''
file=''
while (($#)); do
  case "$1" in
    --destination)
      dest="$2"
      shift 2
      ;;
    --*)
      shift
      ;;
    *)
      file="$1"
      shift
      ;;
  esac
done
tar -xf "$file" -C "$dest"
APK
chmod +x "$ib_tree/staging_dir/host/bin/apk"

# The fake image target installs the requested packages, preferring the
# local package directory like the ImageBuilder's local repository.
cat >"$ib_tree/fake-image.sh" <<'IMAGE'
#!/usr/bin/env bash
set -euo pipefail

profile="$1"
packages="$2"
bin_dir="$3"

[[ -L dl ]] || { printf 'dl is not the shared apk cache link\n' >&2; exit 1; }
while read -r url; do
  index="dl/APKINDEX.$(printf '%s' "$url" | sha256sum | cut -c1-8).tar.gz"
  [[ -f "$index" ]] || { printf 'missing seeded index: %s\n' "$index" >&2; exit 1; }
done < <(grep -Ev '^[[:space:]]*(#|$)' repositories)
if [[ "${FAKE_IB_MUTATE_INDEX:-0}" == '1' ]]; then
  printf 'refreshed\n' >>"$index"
fi

find_apk() {
  local file

  for file in "$1/$2"-[0-9]*.apk; do
    if [[ -f "$file" ]]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

root='build_dir/target-test_sub/root-test'
rm -rf build_dir
mkdir -p "$root" "$bin_dir"
manifest="$bin_dir/openwrt-test-sub-$profile.manifest"
: >"$manifest"
for package in kernel $packages; do
  [[ "$package" != -* ]] || continue
  apk=''
  if [[ "${FAKE_IB_PREFER_REMOTE:-0}" == '1' ]]; then
    apk="$(find_apk remote "$package" || true)"
  fi
  if [[ -z "$apk" ]]; then
    apk="$(find_apk packages "$package" || find_apk remote "$package")" ||
      { printf 'unknown package: %s\n' "$package" >&2; exit 1; }
  fi
  tar -xf "$apk" -C "$root"
  version="$(basename "$apk" .apk)"
  version="${version#"$package"-}"
  if [[ "$package" == 'kernel' && -n "${FAKE_IB_KERNEL:-}" ]]; then
    version="$FAKE_IB_KERNEL"
  fi
  printf '%s - %s\n' "$package" "$version" >>"$manifest"
done
printf 'sysupgrade\n' >"$bin_dir/openwrt-test-sub-$profile-squashfs-sysupgrade.bin"
IMAGE
chmod +x "$ib_tree/fake-image.sh"

cat >"$ib_tree/Makefile" <<'MAKEFILE'
.PHONY: info image

info:
	@cat info.txt

image:
	@printf 'image %s\n' '$(PACKAGES)' >>image-calls.log
	@./fake-image.sh '$(PROFILE)' '$(PACKAGES)' '$(BIN_DIR)'
MAKEFILE

repository_urls=(
  "$download_base/packages/packages.adb"
  'https://downloads.example.invalid/releases/test/packages/aarch64/base/packages.adb'
)
{
  printf '# pinned test repositories\n'
  printf '%s\n' "${repository_urls[@]}"
} >"$ib_tree/repositories"

repository_entries=()
for url in "${repository_urls[@]}"; do
  index_file="$tmp_root/index-$(printf '%s' "$url" | sha256sum | cut -c1-8)"
  printf 'index for %s\n' "$url" >"$index_file"
  index_sha="$(sha256_of "$index_file")"
  cp "$index_file" "$cache_root/imagebuilder/indexes/$index_sha.adb"
  repository_entries+=("$url|$index_sha")
done

sdk_archive='openwrt-sdk-test-sub_gcc-14.3.0_musl.Linux-x86_64.tar.zst'
ib_archive='openwrt-imagebuilder-test-sub.Linux-x86_64.tar.zst'

write_sdk_feeds_default() {
  local video_ref="$1"

  {
    printf '# official SDK feeds\n'
    printf 'src-git --root=package base file://%s^%s\n' "$source_repo" "$openwrt_ref"
    printf 'src-git packages https://git.example.invalid/feed/packages.git^%s\n' "$(feed_ref packages)"
    printf 'src-git luci https://git.example.invalid/project/luci.git^%s\n' "$(feed_ref luci)"
    printf 'src-git routing https://git.example.invalid/feed/routing.git^%s\n' "$(feed_ref routing)"
    printf 'src-git telephony https://git.example.invalid/feed/telephony.git^%s\n' "$(feed_ref telephony)"
    printf 'src-git video https://git.example.invalid/feed/video.git^%s\n' "$video_ref"
  } >"$sdk_tree/feeds.conf.default"
}
write_sdk_feeds_default "$(feed_ref video)"

tar --zstd -cf "$cache_root/dl/$sdk_archive" -C "$archive_root" openwrt-sdk-test
tar --zstd -cf "$cache_root/dl/$ib_archive" -C "$archive_root" openwrt-imagebuilder-test
sdk_sha="$(sha256_of "$cache_root/dl/$sdk_archive")"
ib_sha="$(sha256_of "$cache_root/dl/$ib_archive")"

make_apk "$cache_root/dl/fakesteer-2.0-r1.apk" usr/sbin/fakesteer 'patched fakesteer'
fakesteer_sha="$(sha256_of "$cache_root/dl/fakesteer-2.0-r1.apk")"

printf 'CONFIG_TARGET_TEST=y\n' >"$input_root/diffconfig"
cat >"$input_root/world.txt" <<'WORLD'
installed packages
__WORLD__
base
fakesteer
htop
kernel
kmod-mac80211
WORLD
cat >"$input_root/reference.manifest" <<'MANIFEST'
base - 1.0-r1
fakesteer - 2.0-r1
htop - 3.4.1-r1
kernel - 6.12.90~old-r1
kmod-mac80211 - 1.0-r1
MANIFEST
printf 'mac80211 patch v1\n' >"$input_root/mac80211.patch"
mkdir -p "$input_root/feed/fakesteer"
printf 'fakesteer source\n' >"$input_root/feed/fakesteer/Makefile"

write_lock() {
  local lock="$1"
  local prebuilt="$2"
  local video_ref="${3:-$(feed_ref video)}"
  local mac80211_sha feed_sha entry

  mac80211_sha="$(sha256_of "$input_root/mac80211.patch")"
  feed_sha="$(local_feed_digest "$input_root/feed")"
  {
    cat <<LOCK
OPENWRT_REPO_URL='file://$source_repo'
OPENWRT_TAG='vtest'
OPENWRT_REF='$openwrt_ref'
FEED_PACKAGES_URL='https://git.example.invalid/feed/packages.git'
FEED_PACKAGES_REF='$(feed_ref packages)'
FEED_LUCI_URL='https://git.example.invalid/project/luci.git'
FEED_LUCI_REF='$(feed_ref luci)'
FEED_ROUTING_URL='https://git.example.invalid/feed/routing.git'
FEED_ROUTING_REF='$(feed_ref routing)'
FEED_TELEPHONY_URL='https://git.example.invalid/feed/telephony.git'
FEED_TELEPHONY_REF='$(feed_ref telephony)'
FEED_VIDEO_URL='https://git.example.invalid/feed/video.git'
FEED_VIDEO_REF='$video_ref'
LOCAL_FEEDS=('testfeed:$input_root/feed')
LOCAL_FEED_SHA256S=('testfeed:$feed_sha')
LOCAL_FEED_INSTALLS=('testfeed:fakesteer')
PATCH_SOURCE='$input_root/mac80211.patch'
PATCH_DEST='package/kernel/mac80211/patches/subsys/mac80211.patch'
PATCH_SHA256='$mac80211_sha'
CONFIG_FRAGMENT='$input_root/diffconfig'
WORLD_SOURCE='$input_root/world.txt'
REFERENCE_MANIFEST='$input_root/reference.manifest'
TARGET='test'
SUBTARGET='sub'
DEVICE_ID='fake-device'
ARTIFACT_VARIANT='test'
DEFAULT_WORK_ROOT='build'
DEFAULT_CACHE_ROOT='cache'
DEFAULT_DOWNLOAD_JOBS='2'
EXTRA_CONFIG_LINES=()
MANIFEST_BUILTIN_PACKAGE_NAMES=()
DEFAULT_BUILD_METHOD='imagebuilder'
IMAGEBUILDER_PATCHED_PACKAGES=('kmod-mac80211')
SDK_URL='$download_base/$sdk_archive'
SDK_SHA256='$sdk_sha'
IMAGEBUILDER_URL='$download_base/$ib_archive'
IMAGEBUILDER_SHA256='$ib_sha'
LOCK
    printf 'IMAGEBUILDER_REPOSITORIES=(\n'
    for entry in "${repository_entries[@]}"; do
      printf "  '%s'\n" "$entry"
    done
    printf ')\n'
    if [[ "$prebuilt" == '1' ]]; then
      printf "PREBUILT_APKS=('fakesteer|fakesteer-2.0-r1.apk|https://downloads.example.invalid/fakesteer.apk|%s')\n" \
        "$fakesteer_sha"
    fi
  } >"$lock"
}
write_lock "$lock_file" 1

run_build() {
  local session="$1"
  shift

  WORK_ROOT="$work_root" \
    CACHE_ROOT="$cache_root" \
    USE_CCACHE=0 \
    STRICT_MANIFEST=1 \
    BUILDER_PLATFORM=linux/amd64 \
    "$builder" \
      --session "$session" \
      --builder-id builder-a \
      "$@"
}

summary="$workspace/output/build-summary.txt"
sdk_calls="$workspace/sdk/make-calls.log"
ib_rootfs="$workspace/imagebuilder/build_dir/target-test_sub/root-test"
pin_set="$(printf '%s\n' "${repository_entries[@]}" | sha256sum | cut -c1-16)"

run_build seed --workspace "$workspace_id" "$lock_file"
assert_file_line "$summary" 'build_method=imagebuilder' 'lock default did not select the ImageBuilder method'
assert_file_line "$summary" 'build_mode=full' 'seed build was not recorded as full'
assert_file_line "$summary" 'initramfs_image=' 'ImageBuilder build published an initramfs image'
assert_file_line "$summary" 'reference_kernel_version=6.12.90~old-r1' 'reference kernel version was not recorded'
assert_file_line "$summary" 'image_kernel_version=6.12.94~abc-r1' 'ImageBuilder kernel version was not recorded'
assert_file_line "$summary" 'version_mismatches=0' 'ImageBuilder kernel replacement was reported as package drift'
assert_file_line "$summary" "sdk_sha256=$sdk_sha" 'SDK checksum is missing from the build summary'
assert_file_line "$summary" "imagebuilder_sha256=$ib_sha" 'ImageBuilder checksum is missing from the build summary'
[[ -f "$workspace/output/openwrt-test-sub-fake-device-squashfs-sysupgrade.bin" ]] ||
  die 'sysupgrade image was not copied to the output'
[[ "$(wc -l <"$workspace/output/sha256sums.txt")" == '1' ]] ||
  die 'sha256sums.txt does not list only the sysupgrade image'
[[ ! -e "$workspace/openwrt" ]] || die 'ImageBuilder build created an OpenWrt source checkout'
[[ "$(cat "$workspace/sdk/feeds.conf")" == "src-git --root=package base file://$source_repo^$openwrt_ref" ]] ||
  die 'SDK feeds.conf does not contain only the pinned base feed'
assert_file_line "$workspace/sdk/feeds-calls.log" 'feeds-install mac80211' 'SDK did not install the mac80211 package'
assert_file_line "$sdk_calls" 'mac80211-compile NO_DEPS=1' 'SDK did not compile mac80211 without dependencies'
[[ "$(grep -n '' "$sdk_calls" | grep -E 'linux-compile|mac80211-compile' | cut -d: -f2 | paste -sd ' ')" == \
  'linux-compile NO_DEPS=1 mac80211-compile NO_DEPS=1' ]] ||
  die 'SDK did not package kernel modules before mac80211'
if grep -Fqx 'mac80211-clean' "$sdk_calls"; then
  die 'full build cleaned mac80211'
fi
cmp -s "$input_root/mac80211.patch" "$ib_rootfs/lib/modules/fake/mac80211.ko" ||
  die 'image does not contain the SDK-built mac80211 package'
[[ "$(cat "$ib_rootfs/usr/sbin/fakesteer")" == 'patched fakesteer' ]] ||
  die 'image does not contain the prebuilt APK'
packages_file="$workspace/output/metadata/imagebuilder-packages.txt"
[[ "$(cat "$packages_file")" == $'base\nfakesteer\nhtop\nkmod-mac80211\n-dropbear-fake\n-kmod-fake-usb' ]] ||
  die "unexpected ImageBuilder package selection: $(paste -sd ' ' "$packages_file")"
injected="$workspace/output/metadata/imagebuilder-injected.tsv"
assert_file_line "$injected" \
  "$(printf 'sdk\tkmod-mac80211\tkmod-mac80211-1.0-r1.apk\t%s' "$(sha256_of "$workspace/sdk/bin/targets/test/sub/packages/kmod-mac80211-1.0-r1.apk")")" \
  'SDK-built package is missing from the injected package report'
assert_file_line "$injected" "$(printf 'prebuilt\tfakesteer\tfakesteer-2.0-r1.apk\t%s' "$fakesteer_sha")" \
  'prebuilt APK is missing from the injected package report'
assert_file_line "$workspace/output/metadata/imagebuilder-repositories.tsv" \
  "$(printf '%s\t%s' "${repository_entries[0]%|*}" "${repository_entries[0]#*|}")" \
  'pinned repository indexes are missing from the metadata'
[[ "$(readlink "$workspace/imagebuilder/dl")" == "$cache_root/imagebuilder/apk-cache/$pin_set" ]] ||
  die 'ImageBuilder dl is not the shared apk cache for the pinned indexes'
[[ -d "$workspace/imagebuilder/packages.pristine" &&
  ! -e "$workspace/imagebuilder/packages.pristine/kmod-mac80211-1.0-r1.apk" ]] ||
  die 'pristine ImageBuilder packages were modified'
assert_file_line "$workspace/.openwrt-ft-state/compatibility.tsv" $'build_method\timagebuilder' \
  'compatibility state does not record the build method'

: >"$sdk_calls"
printf 'stale\n' >"$workspace/imagebuilder-bin/stale-fake-device-squashfs-sysupgrade.bin"
run_build no-change --workspace "$workspace_id" "$lock_file"
assert_file_line "$summary" 'build_mode=incremental' 'compatible reuse was not recorded as incremental'
assert_file_line "$summary" 'rebuilt_packages=none' 'no-change reuse selected a package rebuild'
if grep -Fqx 'mac80211-clean' "$sdk_calls"; then
  die 'no-change reuse cleaned mac80211'
fi
[[ ! -e "$workspace/imagebuilder-bin/stale-fake-device-squashfs-sysupgrade.bin" ]] ||
  die 'incremental build retained a stale ImageBuilder image'

printf 'mac80211 patch v2\n' >"$input_root/mac80211.patch"
write_lock "$lock_file" 1
: >"$sdk_calls"
run_build mac80211-change --workspace "$workspace_id" "$lock_file"
assert_file_line "$summary" 'rebuilt_packages=mac80211' 'patch change did not select mac80211'
assert_file_line "$sdk_calls" 'mac80211-clean' 'patch change did not clean mac80211'
cmp -s "$input_root/mac80211.patch" "$workspace/sdk/feeds/base/kernel/mac80211/patches/subsys/mac80211.patch" ||
  die 'changed patch was not installed in the SDK base feed'
cmp -s "$input_root/mac80211.patch" "$ib_rootfs/lib/modules/fake/mac80211.ko" ||
  die 'image does not contain the rebuilt mac80211 package'

success_sha="$(sha256_of "$workspace/.openwrt-ft-state/last-success.tsv")"
expect_failure() {
  local name="$1"
  local message="$2"
  shift 2

  if "$@" >"$tmp_root/$name.log" 2>&1; then
    die "$name unexpectedly succeeded"
  fi
  grep -Fq -- "$message" "$tmp_root/$name.log" ||
    die "$name did not report: $message"
  [[ "$(sha256_of "$workspace/.openwrt-ft-state/last-success.tsv")" == "$success_sha" ]] ||
    die "$name advanced the last-success state"
}

FAKE_IB_PREFER_REMOTE=1 expect_failure official-package 'image does not contain the injected sdk package file for kmod-mac80211' \
  run_build official-package --workspace "$workspace_id" "$lock_file"
FAKE_IB_MUTATE_INDEX=1 expect_failure index-mutation 'pinned repository index changed during the image build' \
  run_build index-mutation --workspace "$workspace_id" "$lock_file"
FAKE_IB_KERNEL=9.9.9-r1 expect_failure kernel-mismatch 'image kernel 9.9.9-r1 is not the pinned ImageBuilder kernel 6.12.94~abc-r1' \
  run_build kernel-mismatch --workspace "$workspace_id" "$lock_file"

sed -i 's/^CONFIG_PACKAGE_MAC80211_MESH=y$/# CONFIG_PACKAGE_MAC80211_MESH is not set/' "$workspace/imagebuilder/.config"
: >"$sdk_calls"
expect_failure package-options 'SDK mac80211 package options differ from the release ImageBuilder config' \
  run_build package-options --workspace "$workspace_id" "$lock_file"
[[ ! -s "$sdk_calls" ]] || die 'mac80211 package option mismatch did not fail before the SDK compile'
sed -i 's/^# CONFIG_PACKAGE_MAC80211_MESH is not set$/CONFIG_PACKAGE_MAC80211_MESH=y/' "$workspace/imagebuilder/.config"

cp "$workspace/sdk/bin/targets/test/sub/packages/kmod-mac80211-1.0-r1.apk" "$workspace/imagebuilder/packages.pristine/"
expect_failure package-collision 'patched package collides with a shipped ImageBuilder package' \
  run_build package-collision --workspace "$workspace_id" "$lock_file"
rm "$workspace/imagebuilder/packages.pristine/kmod-mac80211-1.0-r1.apk"

# A rebuilt upstream index no longer matches its pin. The content-addressed
# store then misses and the refetch fails closed before any SDK compile.
first_index="$cache_root/imagebuilder/indexes/${repository_entries[0]#*|}.adb"
cp "$first_index" "$tmp_root/first-index.adb"
printf 'rebuilt upstream\n' >>"$first_index"
: >"$sdk_calls"
expect_failure index-refetch "failed to download ${repository_entries[0]%|*}" \
  run_build index-refetch --workspace "$workspace_id" "$lock_file"
[[ ! -s "$sdk_calls" ]] || die 'changed repository index did not fail before the SDK compile'
cp "$tmp_root/first-index.adb" "$first_index"

expect_failure local-feeds-rebuild 'local-feeds rebuilds need --build-method source' \
  run_build local-feeds-rebuild --workspace "$workspace_id" --rebuild-package local-feeds "$lock_file"
expect_failure source-on-ib-workspace $'build_method: stored=imagebuilder current=source' \
  run_build source-on-ib-workspace --workspace "$workspace_id" --build-method source "$lock_file"

run_build forced-mac80211 --workspace "$workspace_id" --rebuild-package mac80211 "$lock_file"
assert_file_line "$summary" 'rebuilt_packages=mac80211' 'forced rebuild did not select mac80211'

no_prebuilt_lock="$tmp_root/no-prebuilt.lock"
write_lock "$no_prebuilt_lock" 0
expect_failure missing-prebuilt 'local feed package fakesteer has no PREBUILT_APKS entry; use --build-method source' \
  run_build missing-prebuilt --workspace test-device-missing-prebuilt "$no_prebuilt_lock"
[[ ! -e "$work_root/test-device-missing-prebuilt" ]] ||
  die 'lock validation failure created a workspace'

stale_feed_lock="$tmp_root/stale-feed.lock"
write_lock "$stale_feed_lock" 1 "$(feed_ref video-next)"
expect_failure sdk-feed-mismatch 'SDK feeds.conf.default does not match the lock OpenWrt and feed pins' \
  run_build sdk-feed-mismatch --workspace test-device-feed-mismatch "$stale_feed_lock"

printf 'ImageBuilder build checks passed\n'
