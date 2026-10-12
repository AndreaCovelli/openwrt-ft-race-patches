#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
builder="$repo_root/scripts/build-image.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-incremental-build.XXXXXXXX")"
source_repo="$tmp_root/openwrt-source"
work_root="$tmp_root/work"
cache_root="$tmp_root/cache"
input_root="$tmp_root/inputs"
lock_file="$tmp_root/build.lock"
workspace_id='test-device-dev'
workspace="$work_root/$workspace_id"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

git_commit_all() {
  local repo="$1"
  local message="$2"

  git -C "$repo" add .
  git -C "$repo" \
    -c user.name='Incremental Build CI' \
    -c user.email='incremental-build@example.invalid' \
    commit -q -m "$message"
}

make_feed_repo() {
  local name="$1"
  local repo="$tmp_root/feed-$name"

  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '%s\n' "$name" >"$repo/README"
  git_commit_all "$repo" "seed $name"
  git -C "$repo" rev-parse HEAD
}

mkdir -p "$source_repo/scripts" "$input_root"
git -C "$source_repo" init -q

cat >"$source_repo/scripts/feeds" <<'FEEDS'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  update)
    while read -r kind name pinned; do
      [[ "$kind" == 'src-git-full' ]] || continue
      url="${pinned%%^*}"
      ref="${pinned#*^}"
      git clone -q "$url" "feeds/$name"
      git -C "feeds/$name" checkout -q --detach "$ref"
    done <feeds.conf
    ;;
  install)
    ;;
  *)
    printf 'unexpected feeds command: %s\n' "$*" >&2
    exit 1
    ;;
esac
FEEDS
chmod +x "$source_repo/scripts/feeds"

cat >"$source_repo/Makefile" <<'MAKEFILE'
.PHONY: all defconfig download \
	package/kernel/mac80211/clean package/kernel/mac80211/compile \
	package/feeds/testfeed/testpkg/clean package/feeds/testfeed/testpkg/compile

all:
	@printf 'all\n' >>make-calls.log
	@test ! -e .force-fail
	@test "$$FAKE_FORCE_FAIL" != '1'
	@mkdir -p bin/targets/test/sub
	@printf 'sysupgrade\n' >bin/targets/test/sub/openwrt-test-fake-device-squashfs-sysupgrade.bin
	@printf 'initramfs\n' >bin/targets/test/sub/openwrt-test-fake-device-initramfs-kernel.bin
	@printf 'base - 1\n' >bin/targets/test/sub/openwrt-test-fake-device.manifest
	@if grep -Fqx 'CONFIG_PACKAGE_htop=y' .config; then printf 'htop - 1\n' >>bin/targets/test/sub/openwrt-test-fake-device.manifest; fi

defconfig:
	@printf 'defconfig\n' >>make-calls.log
	@mkdir -p tmp
	@printf 'Package: base\n\nPackage: htop\n' >tmp/.packageinfo
	@if [ "$$FAKE_KCONFIG_DROP_HTOP" = '1' ]; then sed -i '/CONFIG_PACKAGE_htop=/d' .config; fi

download:
	@printf 'download\n' >>make-calls.log

package/kernel/mac80211/clean:
	@printf 'mac80211-clean\n' >>make-calls.log

package/kernel/mac80211/compile:
	@printf 'mac80211-compile\n' >>make-calls.log

package/feeds/testfeed/testpkg/clean:
	@printf 'testpkg-clean\n' >>make-calls.log

package/feeds/testfeed/testpkg/compile:
	@printf 'testpkg-compile\n' >>make-calls.log
MAKEFILE

git_commit_all "$source_repo" 'seed fake OpenWrt'
git -C "$source_repo" tag vtest
openwrt_ref="$(git -C "$source_repo" rev-parse HEAD)"
packages_ref="$(make_feed_repo packages)"
luci_ref="$(make_feed_repo luci)"
routing_ref="$(make_feed_repo routing)"
telephony_ref="$(make_feed_repo telephony)"
video_ref="$(make_feed_repo video)"

printf 'CONFIG_TARGET_TEST=y\n' >"$input_root/diffconfig"
cat >"$input_root/world.txt" <<'WORLD'
installed packages
__WORLD__
base=1
htop=1
WORLD
printf 'base - 1\nhtop - 1\n' >"$input_root/reference.manifest"
printf 'mac80211 patch v1\n' >"$input_root/mac80211.patch"
printf 'mac80211 extra patch v1\n' >"$input_root/extra.patch"
mkdir -p "$input_root/feed/testpkg"
printf 'testpkg v1\n' >"$input_root/feed/testpkg/Makefile"
reference_manifest="$input_root/reference.manifest"

# shellcheck source=scripts/lib/local-feeds.sh
. "$repo_root/scripts/lib/local-feeds.sh"

write_lock() {
  local mac80211_sha extra_sha feed_sha

  mac80211_sha="$(sha256sum "$input_root/mac80211.patch" | awk '{print $1}')"
  extra_sha="$(sha256sum "$input_root/extra.patch" | awk '{print $1}')"
  feed_sha="$(local_feed_digest "$input_root/feed")"
  cat >"$lock_file" <<LOCK
OPENWRT_REPO_URL='$source_repo'
OPENWRT_TAG='vtest'
OPENWRT_REF='$openwrt_ref'
FEED_PACKAGES_URL='$tmp_root/feed-packages'
FEED_PACKAGES_REF='$packages_ref'
FEED_LUCI_URL='$tmp_root/feed-luci'
FEED_LUCI_REF='$luci_ref'
FEED_ROUTING_URL='$tmp_root/feed-routing'
FEED_ROUTING_REF='$routing_ref'
FEED_TELEPHONY_URL='$tmp_root/feed-telephony'
FEED_TELEPHONY_REF='$telephony_ref'
FEED_VIDEO_URL='$tmp_root/feed-video'
FEED_VIDEO_REF='$video_ref'
LOCAL_FEEDS=('testfeed:$input_root/feed')
LOCAL_FEED_SHA256S=('testfeed:$feed_sha')
LOCAL_FEED_INSTALLS=('testfeed:testpkg')
PATCH_SOURCE='$input_root/mac80211.patch'
PATCH_DEST='package/kernel/mac80211/patches/subsys/mac80211.patch'
PATCH_SHA256='$mac80211_sha'
EXTRA_PATCH_SOURCES=('$input_root/extra.patch')
EXTRA_PATCH_DESTS=('package/kernel/mac80211/patches/subsys/extra.patch')
EXTRA_PATCH_SHA256S=('$extra_sha')
CONFIG_FRAGMENT='$input_root/diffconfig'
WORLD_SOURCE='$input_root/world.txt'
REFERENCE_MANIFEST='$reference_manifest'
TARGET='test'
SUBTARGET='sub'
DEVICE_ID='fake-device'
ARTIFACT_VARIANT='test'
DEFAULT_WORK_ROOT='build'
DEFAULT_CACHE_ROOT='cache'
DEFAULT_DOWNLOAD_JOBS='2'
EXTRA_CONFIG_LINES=()
MANIFEST_BUILTIN_PACKAGE_NAMES=()
LOCK
}
write_lock

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
      --workspace "$workspace_id" \
      --builder-id builder-a \
      "$@" \
      "$lock_file"
}

run_build seed
[[ -f "$workspace/.openwrt-ft-state/compatibility.tsv" ]] ||
  die 'missing full-build compatibility state'
[[ -f "$workspace/.openwrt-ft-state/last-success.tsv" ]] ||
  die 'missing full-build success state'
[[ -f "$workspace/.openwrt-ft-state/prepared.tsv" ]] ||
  die 'missing full-build prepared state'
grep -Fqx 'build_mode=full' "$workspace/output/build-summary.txt" ||
  die 'seed build was not recorded as full'
grep -Fqx "workspace_id=$workspace_id" "$workspace/output/build-summary.txt" ||
  die 'workspace ID is missing from build metadata'
grep -Fqx 'CONFIG_PACKAGE_htop=y' "$workspace/openwrt/.config" ||
  die 'captured world package absent from diffconfig was not selected'

: >"$workspace/openwrt/make-calls.log"
mac80211_dest="$workspace/openwrt/package/kernel/mac80211/patches/subsys/mac80211.patch"
extra_dest="$workspace/openwrt/package/kernel/mac80211/patches/subsys/extra.patch"
touch -t 200001010000 "$mac80211_dest" "$extra_dest"
mac80211_mtime="$(stat -c %y "$mac80211_dest")"
extra_mtime="$(stat -c %y "$extra_dest")"
printf 'stale\n' >"$workspace/openwrt/bin/targets/test/sub/old-fake-device-stale.bin"
run_build no-change
[[ "$(stat -c %y "$mac80211_dest")" == "$mac80211_mtime" && \
  "$(stat -c %y "$extra_dest")" == "$extra_mtime" ]] ||
  die 'no-change reuse touched a patch and invalidated OpenWrt preparation stamps'
grep -Fqx 'build_mode=incremental' "$workspace/output/build-summary.txt" ||
  die 'compatible reuse was not recorded as incremental'
grep -Fqx 'rebuilt_packages=none' "$workspace/output/build-summary.txt" ||
  die 'no-change reuse unexpectedly selected a package rebuild'
if grep -Eq '(mac80211|testpkg)-(clean|compile)' "$workspace/openwrt/make-calls.log"; then
  die 'no-change reuse ran a package rebuild'
fi
[[ ! -e "$workspace/openwrt/bin/targets/test/sub/old-fake-device-stale.bin" ]] ||
  die 'incremental build retained a stale matching target artifact'

summary_sha="$(sha256sum "$workspace/output/build-summary.txt" | awk '{print $1}')"
printf '# modified during diagnosis\n' >>"$workspace/openwrt/Makefile"
if run_build tracked-core-change >"$tmp_root/tracked-core.log" 2>&1; then
  die 'tracked core source modification was accepted for reuse'
fi
grep -Fq 'tracked files are modified' "$tmp_root/tracked-core.log" ||
  die 'tracked core source refusal did not identify the modified files'
[[ "$(sha256sum "$workspace/output/build-summary.txt" | awk '{print $1}')" == "$summary_sha" ]] ||
  die 'tracked core source refusal modified the existing workspace output'
git -C "$workspace/openwrt" checkout -- Makefile

printf '# modified during diagnosis\n' >>"$workspace/openwrt/feeds/packages/README"
if run_build tracked-feed-change >"$tmp_root/tracked-feed.log" 2>&1; then
  die 'tracked feed modification was accepted for reuse'
fi
grep -Fq 'tracked files are modified' "$tmp_root/tracked-feed.log" ||
  die 'tracked feed refusal did not identify the modified files'
[[ "$(sha256sum "$workspace/output/build-summary.txt" | awk '{print $1}')" == "$summary_sha" ]] ||
  die 'tracked feed refusal modified the existing workspace output'
git -C "$workspace/openwrt/feeds/packages" checkout -- README

printf 'mac80211 patch v2\n' >"$input_root/mac80211.patch"
write_lock
: >"$workspace/openwrt/make-calls.log"
run_build mac80211-change
[[ "$(stat -c %y "$extra_dest")" == "$extra_mtime" ]] ||
  die 'mac80211 patch change touched the unchanged extra patch'
cmp -s "$input_root/mac80211.patch" "$mac80211_dest" || die 'changed mac80211 patch was not installed'
grep -Fqx 'rebuilt_packages=mac80211' "$workspace/output/build-summary.txt" ||
  die 'mac80211 patch change did not select mac80211'
grep -Fqx 'mac80211-clean' "$workspace/openwrt/make-calls.log" ||
  die 'mac80211 clean was not run'
grep -Fqx 'mac80211-compile' "$workspace/openwrt/make-calls.log" ||
  die 'mac80211 compile was not run'
if grep -Eq 'testpkg-(clean|compile)' "$workspace/openwrt/make-calls.log"; then
  die 'mac80211-only change rebuilt local feed packages'
fi

previous_extra_sha="$(
  awk -F '\t' '$1 == "patch.001.sha256" { print $2 }' \
    "$workspace/.openwrt-ft-state/last-success.tsv"
)"
printf 'mac80211 extra patch v2\n' >"$input_root/extra.patch"
write_lock
touch "$workspace/openwrt/.force-fail"
if run_build extra-patch-failure; then
  die 'forced incremental failure unexpectedly succeeded'
fi
stored_extra_sha="$(
  awk -F '\t' '$1 == "patch.001.sha256" { print $2 }' \
    "$workspace/.openwrt-ft-state/last-success.tsv"
)"
[[ "$stored_extra_sha" == "$previous_extra_sha" ]] ||
  die 'failed build advanced the last-success patch state'

rm "$workspace/openwrt/.force-fail"
: >"$workspace/openwrt/make-calls.log"
run_build extra-patch-retry
cmp -s "$input_root/extra.patch" "$extra_dest" || die 'changed extra patch was not installed'
grep -Fqx 'rebuilt_packages=mac80211' "$workspace/output/build-summary.txt" ||
  die 'retry did not select the previously failed extra mac80211 patch change'
grep -Fqx 'mac80211-compile' "$workspace/openwrt/make-calls.log" ||
  die 'extra patch retry did not compile mac80211'

printf 'mac80211 patch v3\n' >"$input_root/mac80211.patch"
printf 'testpkg v2\n' >"$input_root/feed/testpkg/Makefile"
write_lock
: >"$workspace/openwrt/make-calls.log"
run_build both-changed
grep -Fqx 'rebuilt_packages=mac80211,local-feeds' "$workspace/output/build-summary.txt" ||
  die 'simultaneous patch and local feed changes did not select both groups'
grep -Fqx 'mac80211-compile' "$workspace/openwrt/make-calls.log" ||
  die 'simultaneous changes omitted mac80211'
grep -Fqx 'testpkg-compile' "$workspace/openwrt/make-calls.log" ||
  die 'simultaneous changes omitted local feed packages'

: >"$workspace/openwrt/make-calls.log"
run_build forced-all --rebuild-package all
grep -Fqx 'rebuilt_packages=mac80211,local-feeds' "$workspace/output/build-summary.txt" ||
  die 'forced all rebuild did not record every package group'
grep -Fqx 'mac80211-compile' "$workspace/openwrt/make-calls.log" ||
  die 'forced all rebuild omitted mac80211'
grep -Fqx 'testpkg-compile' "$workspace/openwrt/make-calls.log" ||
  die 'forced all rebuild omitted local feed packages'

printf 'testpkg v3\n' >"$input_root/feed/testpkg/Makefile"
write_lock
: >"$workspace/openwrt/make-calls.log"
run_build local-feed-change
grep -Fqx 'rebuilt_packages=local-feeds' "$workspace/output/build-summary.txt" ||
  die 'local feed change did not select local feed packages'
grep -Fqx 'testpkg-clean' "$workspace/openwrt/make-calls.log" ||
  die 'local feed change did not clean the installed package'
grep -Fqx 'testpkg-compile' "$workspace/openwrt/make-calls.log" ||
  die 'local feed change did not compile the installed package'
if grep -Eq 'mac80211-(clean|compile)' "$workspace/openwrt/make-calls.log"; then
  die 'local feed change rebuilt mac80211'
fi

cp "$input_root/reference.manifest" "$input_root/reference-moved.manifest"
reference_manifest="$input_root/reference-moved.manifest"
write_lock
: >"$workspace/openwrt/make-calls.log"
run_build reference-manifest-moved
grep -Fqx 'build_mode=incremental' "$workspace/output/build-summary.txt" ||
  die 'reference manifest path change invalidated the workspace'
grep -Fqx 'rebuilt_packages=none' "$workspace/output/build-summary.txt" ||
  die 'reference manifest path change selected a package rebuild'

success_state="$workspace/.openwrt-ft-state/last-success.tsv"
cp "$success_state" "$tmp_root/last-success.tsv"
sed -i 's/^state_schema\t.*$/state_schema\t1/' "$success_state"
if run_build old-schema >"$tmp_root/old-schema.log" 2>&1; then
  die 'workspace with an older state schema was accepted'
fi
grep -Fq 'state schema is 1' "$tmp_root/old-schema.log" ||
  die 'state schema refusal did not identify the stored schema'
cp "$tmp_root/last-success.tsv" "$success_state"

summary_sha="$(sha256sum "$workspace/output/build-summary.txt" | awk '{print $1}')"
if WORK_ROOT="$work_root" CACHE_ROOT="$cache_root" USE_CCACHE=0 \
  BUILDER_PLATFORM=linux/amd64 \
  "$builder" \
    --session incompatible \
    --workspace "$workspace_id" \
    --builder-id builder-b \
    "$lock_file" >"$tmp_root/incompatible.log" 2>&1; then
  die 'builder ID mismatch unexpectedly reused the workspace'
fi
grep -Fq 'builder_id:' "$tmp_root/incompatible.log" ||
  die 'compatibility mismatch did not report the differing builder_id key'
[[ "$(sha256sum "$workspace/output/build-summary.txt" | awk '{print $1}')" == "$summary_sha" ]] ||
  die 'incompatible reuse modified the existing workspace output'

WORK_ROOT="$work_root" CACHE_ROOT="$cache_root" USE_CCACHE=0 \
  STRICT_MANIFEST=1 BUILDER_PLATFORM=linux/amd64 \
  "$builder" \
    --session fresh \
    --workspace "$workspace_id" \
    --builder-id builder-b \
    --fresh \
    "$lock_file"
grep -Fqx 'build_mode=full' "$workspace/output/build-summary.txt" ||
  die 'fresh replacement was not a full build'
grep -Fqx 'builder_id=builder-b' "$workspace/output/build-summary.txt" ||
  die 'fresh replacement did not store the new builder ID'

resume_workspace="$work_root/resume"
if FAKE_FORCE_FAIL=1 run_build resume-fail --workspace resume >"$tmp_root/resume-fail.log" 2>&1; then
  die 'forced full-build failure unexpectedly succeeded'
fi
[[ -f "$resume_workspace/.openwrt-ft-state/prepared.tsv" ]] ||
  die 'failed full build did not record prepared state'
[[ ! -e "$resume_workspace/.openwrt-ft-state/last-success.tsv" ]] ||
  die 'failed full build recorded success state'
: >"$resume_workspace/openwrt/make-calls.log"
run_build resume-retry --workspace resume
grep -Fqx 'build_mode=resume' "$resume_workspace/output/build-summary.txt" ||
  die 'retry after failed full build was not recorded as resume'
grep -Fqx 'download' "$resume_workspace/openwrt/make-calls.log" ||
  die 'resume did not finish source downloads'
grep -Fqx 'all' "$resume_workspace/openwrt/make-calls.log" ||
  die 'resume did not run the image build'
if grep -Fqx 'defconfig' "$resume_workspace/openwrt/make-calls.log"; then
  die 'resume regenerated the prepared configuration'
fi
[[ -f "$resume_workspace/.openwrt-ft-state/last-success.tsv" ]] ||
  die 'successful resume did not record success state'

legacy_workspace="$work_root/legacy"
mkdir -p "$legacy_workspace"
if WORK_ROOT="$work_root" CACHE_ROOT="$cache_root" USE_CCACHE=0 \
  BUILDER_PLATFORM=linux/amd64 \
  "$builder" \
    --session legacy \
    --workspace legacy \
    --builder-id builder-a \
    "$lock_file" >"$tmp_root/legacy.log" 2>&1; then
  die 'legacy workspace without a state marker was accepted'
fi
grep -Fq 'rerun with --fresh' "$tmp_root/legacy.log" ||
  die 'legacy workspace refusal did not require --fresh'

mkdir -p "$tmp_root/symlink-target"
ln -s "$tmp_root/symlink-target" "$work_root/symlink-workspace"
if WORK_ROOT="$work_root" CACHE_ROOT="$cache_root" USE_CCACHE=0 \
  BUILDER_PLATFORM=linux/amd64 \
  "$builder" \
    --session symlink \
    --workspace symlink-workspace \
    --builder-id builder-a \
    --fresh \
    "$lock_file" >"$tmp_root/symlink.log" 2>&1; then
  die 'fresh build accepted a symlink workspace'
fi
[[ -d "$tmp_root/symlink-target" ]] ||
  die 'symlink safety check removed the symlink target'

exec 9>"$work_root/.openwrt-ft-locks/$workspace_id.lock"
flock -n 9
if WORK_ROOT="$work_root" CACHE_ROOT="$cache_root" USE_CCACHE=0 \
  BUILDER_PLATFORM=linux/amd64 \
  "$builder" \
    --session locked \
    --workspace "$workspace_id" \
    --builder-id builder-b \
    "$lock_file" >"$tmp_root/locked.log" 2>&1; then
  die 'concurrent workspace lock was not rejected'
fi
grep -Fq 'already locked' "$tmp_root/locked.log" ||
  die 'concurrent workspace failure did not identify the lock'
flock -u 9
exec 9>&-

if FAKE_KCONFIG_DROP_HTOP=1 run_build unselectable --workspace unselectable >"$tmp_root/unselectable.log" 2>&1; then
  die 'world package disabled by target Kconfig was accepted'
fi
grep -Fq 'apk world packages cannot be selected' "$tmp_root/unselectable.log" ||
  die 'Kconfig refusal did not identify unselected world packages'
if grep -Eq '^(download|all)$' "$work_root/unselectable/openwrt/make-calls.log"; then
  die 'unselectable world package was detected after downloading or compiling'
fi

printf 'missing-package\n' >>"$input_root/world.txt"
if run_build unavailable --workspace unavailable >"$tmp_root/unavailable.log" 2>&1; then
  die 'world package absent from pinned metadata was accepted'
fi
grep -Fq 'cannot resolve apk world package' "$tmp_root/unavailable.log" ||
  die 'unavailable world package was not identified'
if grep -Eq '^(download|all)$' "$work_root/unavailable/openwrt/make-calls.log"; then
  die 'unavailable world package was detected after downloading or compiling'
fi
