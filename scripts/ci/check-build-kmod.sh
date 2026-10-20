#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
builder="$repo_root/scripts/build-kmod.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-build-kmod.XXXXXXXX")"
mirror="$tmp_root/mirror"
version='25.12.9'
target_dir="$mirror/releases/$version/targets/test/sub"
kmods_rel='kmods/6.12.1-1-0123abcd'
package_file='kmod-mac80211-6.12.1.6.18.1-r1.apk'
sdk_file="openwrt-sdk-$version-test-sub_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
source_repo="$tmp_root/openwrt-source"
work_root="$tmp_root/work"
cache_root="$tmp_root/cache"
artifact_root="$tmp_root/artifacts"
cc_bin="${CC:-cc}"

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

expect_failure() {
  local name="$1"
  local message="$2"
  shift 2

  if "$@" >"$tmp_root/$name.log" 2>&1; then
    die "$name unexpectedly succeeded"
  fi
  grep -Fq -- "$message" "$tmp_root/$name.log" ||
    die "$name did not report: $message"
}

command -v "$cc_bin" >/dev/null 2>&1 || die "missing C compiler for fake modules: $cc_bin"

# shellcheck source=scripts/lib/kmod.sh
. "$repo_root/scripts/lib/kmod.sh"

# Helper self-tests.
printf '%s *a/one.apk\n%s *a/one-two.apk\nnot-a-sum *bad.apk\n' \
  "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" >"$tmp_root/sums"
[[ "$(kmod_release_entry "$tmp_root/sums" '^a/one[.]apk$')" == "$(printf 'a%.0s' {1..64})"$'\t'a/one.apk ]] ||
  die 'release entry lookup returned the wrong entry'
if kmod_release_entry "$tmp_root/sums" '^a/one' 2>/dev/null; then
  die 'ambiguous release entry was accepted'
fi
if kmod_release_entry "$tmp_root/sums" '^bad[.]apk$' 2>/dev/null; then
  die 'release entry with an invalid checksum was accepted'
fi
[[ "$(kmod_regex_escape 25.12.9-test)" == '25[.]12[.]9-test' ]] || die 'release names were not escaped'

ref="$(printf '%040d' 1)"
printf '# comment\nsrc-git --root=package base https://git.example.test/openwrt.git^%s\nsrc-git packages https://x^%s\n' \
  "$ref" "$ref" >"$tmp_root/feeds.conf.default"
[[ "$(kmod_sdk_base_feed "$tmp_root/feeds.conf.default")" == "https://git.example.test/openwrt.git $ref" ]] ||
  die 'SDK base feed was parsed incorrectly'
for bad_feed in \
  'src-git --root=package base https://git.example.test/openwrt.git^main' \
  "src-git --root=package base http://git.example.test/openwrt.git^$ref" \
  "src-git base https://git.example.test/openwrt.git^$ref"; do
  printf '%s\n' "$bad_feed" >"$tmp_root/feeds.bad"
  if kmod_sdk_base_feed "$tmp_root/feeds.bad" >/dev/null 2>&1; then
    die "unsupported SDK base feed was accepted: $bad_feed"
  fi
done

# Fake modules are real ELF objects with the sections the checks read.
mkdir -p "$tmp_root/elf"
cat >"$tmp_root/elf/module.c" <<'C'
#define MODINFO(name, value) \
  __attribute__((section(".modinfo"), used, aligned(1))) static const char modinfo_##name[] = value
MODINFO(vermagic, "vermagic=6.12.1 SMP mod_unload aarch64");
MODINFO(depends, "depends=cfg80211,compat");
MODINFO(name, "name=mac80211");
MODINFO(srcversion, "srcversion=AAAA");
__attribute__((section("__ksymtab_strings"), used, aligned(1)))
static const char ksymtab_strings[] = "ieee80211_free_hw\0ieee80211_alloc_hw_nm";
extern int kfree_fake(int);
int ieee80211_key_upload(int x) { return kfree_fake(x); }
C
"$cc_bin" -c -o "$tmp_root/elf/module.o" "$tmp_root/elf/module.c"
[[ "$(kmod_exports "$tmp_root/elf/module.o")" == $'ieee80211_alloc_hw_nm\nieee80211_free_hw' ]] ||
  die "module exports were read incorrectly: $(kmod_exports "$tmp_root/elf/module.o" | paste -sd ' ')"
[[ "$(kmod_modinfo "$tmp_root/elf/module.o")" == \
  $'depends=cfg80211,compat\nname=mac80211\nvermagic=6.12.1 SMP mod_unload aarch64' ]] ||
  die 'module metadata was read incorrectly or kept srcversion'
kmod_imports "$tmp_root/elf/module.o" | grep -Fqx kfree_fake || die 'module imports were not read'

# Fake OpenWrt source with a mac80211 package that compiles key.c into
# mac80211.ko. The official package is the unpatched build.
mkdir -p "$source_repo/package/kernel/mac80211/src/net/mac80211" \
  "$source_repo/package/kernel/mac80211/patches/subsys"
cp "$tmp_root/elf/module.c" "$source_repo/package/kernel/mac80211/src/net/mac80211/key.c"
: >"$source_repo/package/kernel/mac80211/patches/subsys/.keep"
git -C "$source_repo" init -q
git -C "$source_repo" add .
git -C "$source_repo" -c user.name='kmod CI' -c user.email='kmod@example.invalid' commit -q -m 'seed fake OpenWrt'
openwrt_ref="$(git -C "$source_repo" rev-parse HEAD)"

# Write a patch from the fake key.c to its copy edited by SED_SCRIPT.
make_patch() {
  local dest="$1"
  local sed_script="$2"
  local dir

  dir="$(mktemp -d "$tmp_root/patch.XXXXXXXX")"
  mkdir -p "$dir/a/net/mac80211" "$dir/b/net/mac80211"
  cp "$source_repo/package/kernel/mac80211/src/net/mac80211/key.c" "$dir/a/net/mac80211/key.c"
  sed "$sed_script" "$dir/a/net/mac80211/key.c" >"$dir/b/net/mac80211/key.c"
  (cd "$dir" && diff -u a/net/mac80211/key.c b/net/mac80211/key.c) >"$dest" || true
  rm -rf "$dir"
  [[ -s "$dest" ]] || die "fake patch is empty: $dest"
}

patch_dir="$tmp_root/patches"
mkdir -p "$patch_dir/good" "$patch_dir/export"
# The good patch changes code and srcversion and adds an import.
make_patch "$patch_dir/good/400-fake.patch" \
  's/srcversion=AAAA/srcversion=BBBB/; s/^extern int kfree_fake(int);$/&\nextern int new_import_fake(void);/; s/return kfree_fake(x); }/return kfree_fake(x) + new_import_fake(); }/'
make_patch "$patch_dir/export/400-fake.patch" \
  's/ieee80211_alloc_hw_nm"/ieee80211_alloc_hw_nm\\0ieee80211_new_export"/'

sdk_tree="$tmp_root/sdk-tree/openwrt-sdk"
mkdir -p "$sdk_tree/scripts" "$sdk_tree/staging_dir/host/bin"
printf 'src-git --root=package base https://git.example.test/openwrt.git^%s\nsrc-git packages https://git.example.test/packages.git^%s\n' \
  "$openwrt_ref" "$ref" >"$sdk_tree/feeds.conf.default"
cat >"$sdk_tree/scripts/feeds" <<'FEEDS'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  update)
    [[ "${2:-}" == 'base' && "$(wc -l <feeds.conf)" == '1' ]]
    read -r _kind _root name pinned <feeds.conf
    [[ "$name" == 'base' ]]
    mkdir -p feeds
    git clone -q "$TEST_OPENWRT_REPO" feeds/base_root
    git -C feeds/base_root checkout -q --detach "${pinned#*^}"
    ln -s base_root/package feeds/base
    ;;
  install)
    printf 'feeds-install %s\n' "$2" >>feeds-calls.log
    ;;
  *)
    exit 1
    ;;
esac
FEEDS
cat >"$sdk_tree/staging_dir/host/bin/apk" <<'APK'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == 'extract' ]]
shift
dest=''
file=''
while (($#)); do
  case "$1" in
    --destination) dest="$2"; shift 2 ;;
    --*) shift ;;
    *) file="$1"; shift ;;
  esac
done
tar -xf "$file" -C "$dest"
APK
chmod +x "$sdk_tree/scripts/feeds" "$sdk_tree/staging_dir/host/bin/apk"
cat >"$sdk_tree/Makefile" <<MAKEFILE
PKG_DIR := bin/targets/test/sub/packages
SRC_DIR := build_dir/target-test/linux-test_sub/backports-6.18.1

.PHONY: defconfig package/linux/compile package/mac80211/compile

defconfig:
	@printf 'CONFIG_PACKAGE_kmod-mac80211=m\n' >.config

package/linux/compile:
	@printf 'linux-compile NO_DEPS=%s\n' '\$(NO_DEPS)' >>make-calls.log

package/mac80211/compile:
	@printf 'mac80211-compile NO_DEPS=%s\n' '\$(NO_DEPS)' >>make-calls.log
	@rm -rf \$(SRC_DIR) pkg-root
	@mkdir -p \$(SRC_DIR) pkg-root/lib/modules/6.12.1 \$(PKG_DIR)
	@cp -a feeds/base/kernel/mac80211/src/. \$(SRC_DIR)/
	@for p in feeds/base/kernel/mac80211/patches/subsys/*.patch; do patch -s -p1 -d \$(SRC_DIR) <"\$\$p"; done
	@$cc_bin -c -o pkg-root/lib/modules/6.12.1/mac80211.ko \$(SRC_DIR)/net/mac80211/key.c
	@tar -cf \$(PKG_DIR)/$package_file -C pkg-root .
	@printf 'hwsim\n' >\$(PKG_DIR)/kmod-mac80211-hwsim-6.12.1.6.18.1-r1.apk
MAKEFILE
mkdir -p "$target_dir/$kmods_rel"
tar --zstd -cf "$target_dir/$sdk_file" -C "$tmp_root/sdk-tree" openwrt-sdk

official_root="$tmp_root/official-root"
mkdir -p "$official_root/lib/modules/6.12.1"
"$cc_bin" -c -o "$official_root/lib/modules/6.12.1/mac80211.ko" \
  "$source_repo/package/kernel/mac80211/src/net/mac80211/key.c"
tar -cf "$target_dir/$kmods_rel/$package_file" -C "$official_root" .

write_sums() {
  local official_sha="${1:-$(sha256_of "$target_dir/$kmods_rel/$package_file")}"

  {
    printf '%s *%s\n' "$(sha256_of "$target_dir/$sdk_file")" "$sdk_file"
    printf '%s *%s/%s\n' "$official_sha" "$kmods_rel" "$package_file"
    printf '%s *%s/kmod-mac80211-hwsim-6.12.1.6.18.1-r1.apk\n' "$(printf 'c%.0s' {1..64})" "$kmods_rel"
  } >"$target_dir/sha256sums"
}
write_sums
cat >"$target_dir/profiles.json" <<JSON
{"version_number":"$version","target":"test/sub","linux_kernel":{"version":"6.12.1","release":"1","vermagic":"0123abcd"}}
JSON

mkdir -p "$tmp_root/bin"
cat >"$tmp_root/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

dest=''
url=''
while (($#)); do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    --proto|--proto-redir|--connect-timeout|--max-time|--retry) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >>"$TEST_CURL_LOG"
path="${url#https://downloads.example.test/}"
[[ "$path" != "$url" && -f "$TEST_MIRROR/$path" ]] || exit 22
cp "$TEST_MIRROR/$path" "$dest"
CURL
chmod +x "$tmp_root/bin/curl"

run_kmod() {
  PATH="$tmp_root/bin:$PATH" \
    TEST_MIRROR="$mirror" \
    TEST_CURL_LOG="$tmp_root/curl.log" \
    TEST_OPENWRT_REPO="$source_repo" \
    OPENWRT_DOWNLOAD_BASE_URL='https://downloads.example.test/' \
    WORK_ROOT="$work_root" \
    CACHE_ROOT="$cache_root" \
    "$builder" --make-jobs 1 "$@"
}

artifact="$artifact_root/good"
run_kmod --patch "$patch_dir/good/400-fake.patch" --artifact-dir "$artifact" "$version" test/sub \
  >"$tmp_root/good.log" 2>&1 || {
  cat "$tmp_root/good.log" >&2
  die 'patched kmod build failed'
}
workspace="$work_root/openwrt-ft-kmod-$version-test-sub"
summary="$artifact/build-summary.txt"
[[ -f "$artifact/$package_file" && -f "$artifact/mac80211.ko" ]] || die 'artifacts are missing'
(cd "$artifact" && sha256sum -c --quiet sha256sums.txt) || die 'artifact checksums do not verify'
grep -Fqx "package=$package_file" "$summary" || die 'summary does not name the package'
grep -Fqx "openwrt_ref=$openwrt_ref" "$summary" || die 'summary does not record the SDK OpenWrt commit'
grep -Fqx 'vermagic=6.12.1 SMP mod_unload aarch64' "$summary" || die 'summary does not record the vermagic'
grep -Fqx 'module_path=/lib/modules/6.12.1/mac80211.ko' "$summary" || die 'summary does not record the module path'
grep -Fqx 'new_imports=1' "$summary" || die 'summary does not count the new import'
grep -Fqx "$(printf 'lib/modules/6.12.1/mac80211.ko\tnew_import_fake')" "$artifact/metadata/new-imports.txt" ||
  die 'new import was not reported'
grep -Fqx "$(printf '400-fake.patch\t%s' "$(sha256_of "$patch_dir/good/400-fake.patch")")" \
  "$artifact/metadata/patches.tsv" || die 'patch checksum was not recorded'
grep -Fq 'Comparing the patched package with the official package' "$artifact/logs/build.log" ||
  die 'build log was not published'
[[ "$(cat "$workspace/sdk/feeds.conf")" == "src-git --root=package base https://git.example.test/openwrt.git^$openwrt_ref" ]] ||
  die 'SDK feeds.conf does not contain only the pinned base feed'
grep -Fqx 'mac80211-compile NO_DEPS=1' "$workspace/sdk/make-calls.log" || die 'mac80211 was not compiled without dependencies'
[[ "$(paste -sd ' ' "$workspace/sdk/make-calls.log")" == 'linux-compile NO_DEPS=1 mac80211-compile NO_DEPS=1' ]] ||
  die 'SDK kernel modules were not packaged before mac80211'
! cmp -s "$artifact/mac80211.ko" "$official_root/lib/modules/6.12.1/mac80211.ko" ||
  die 'published module is the official module'

expect_failure workspace-reuse 'rerun with --fresh' \
  run_kmod --patch "$patch_dir/good/400-fake.patch" --artifact-dir "$artifact_root/reuse" "$version" test/sub
expect_failure artifact-exists 'artifact directory already exists' \
  run_kmod --fresh --patch "$patch_dir/good/400-fake.patch" --artifact-dir "$artifact" "$version" test/sub
expect_failure artifact-in-workspace 'artifact directory must be outside' \
  run_kmod --fresh --patch "$patch_dir/good/400-fake.patch" --artifact-dir "$workspace/out" "$version" test/sub
expect_failure sdk-pin 'but --sdk-sha256 requires' \
  run_kmod --fresh --patch "$patch_dir/good/400-fake.patch" --sdk-sha256 "$(printf 'd%.0s' {1..64})" \
  --artifact-dir "$artifact_root/pin" "$version" test/sub
# Without --patch, the release's own patch directory is required.
expect_failure default-patch-missing "no mac80211 patches for OpenWrt $version in patches/$version/subsys" \
  run_kmod --fresh --artifact-dir "$artifact_root/default" "$version" test/sub
expect_failure default-patch-found 'failed to download https://downloads.example.test/releases/25.12.5/' \
  run_kmod --artifact-dir "$artifact_root/default" 25.12.5 test/sub
expect_failure bad-target 'target must be' run_kmod "$version" test
expect_failure bad-patch-name 'NNN-name.patch' \
  run_kmod --patch "$patch_dir/good/400-fake.patch" --patch "$tmp_root/feeds.bad" "$version" test/sub
expect_failure changed-export 'exports differs from the official module' \
  run_kmod --fresh --patch "$patch_dir/export/400-fake.patch" --artifact-dir "$artifact_root/export" "$version" test/sub
[[ ! -e "$artifact_root/export" ]] || die 'failed build published artifacts'

write_sums "$(printf 'e%.0s' {1..64})"
expect_failure official-checksum 'sha256 mismatch' \
  run_kmod --fresh --patch "$patch_dir/good/400-fake.patch" --artifact-dir "$artifact_root/sum" "$version" test/sub
write_sums

printf 'build-kmod self-test passed\n'
