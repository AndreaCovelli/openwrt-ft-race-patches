#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
pin_script="$repo_root/scripts/pin-imagebuilder.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-pin-imagebuilder.XXXXXXXX")"
mirror="$tmp_root/mirror"
base_url='https://downloads.example.test'
release="$mirror/releases/25.12.5"
target="$release/targets/mediatek/filogic"
target_url="$base_url/releases/25.12.5/targets/mediatek/filogic"
packages_url="$base_url/releases/25.12.5/packages/aarch64_cortex-a53"

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

mkdir -p "$tmp_root/bin" "$target/packages" "$target/kmods/6.12.94-1-5a6c1f71"
cat >"$tmp_root/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

dest=''
url=''
while (($#)); do
  case "$1" in
    -o)
      dest="$2"
      shift 2
      ;;
    --proto|--proto-redir|--connect-timeout|--max-time|--retry)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
printf '%s\n' "$url" >>"$TEST_CURL_LOG"
path="${url#https://downloads.example.test/}"
[[ "$path" != "$url" && -f "$TEST_MIRROR/$path" ]] || exit 22
cp "$TEST_MIRROR/$path" "$dest"
CURL
chmod +x "$tmp_root/bin/curl"
export PATH="$tmp_root/bin:$PATH"
export TEST_MIRROR="$mirror"
export TEST_CURL_LOG="$tmp_root/curl.log"
export OPENWRT_DOWNLOAD_BASE_URL="$base_url/"

sdk_archive='openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst'
ib_archive='openwrt-imagebuilder-25.12.5-mediatek-filogic.Linux-x86_64.tar.zst'
cat >"$target/sha256sums" <<SUMS
$(printf 'a%.0s' {1..64}) *$sdk_archive
$(printf 'b%.0s' {1..64}) *$ib_archive
$(printf 'c%.0s' {1..64}) *openwrt-imagebuilder-25.12.5-mediatek-filogic.Linux-x86_64.tar.zst.asc
$(printf 'd%.0s' {1..64}) *openwrt-25.12.5-mediatek-filogic-cudy_wr3000p-v1-squashfs-sysupgrade.bin
SUMS

cat >"$target/profiles.json" <<'JSON'
{"version_number":"25.12.5","target":"mediatek/filogic","arch_packages":"aarch64_cortex-a53",
 "linux_kernel":{"version":"6.12.94","release":"1","vermagic":"5a6c1f71"},
 "profiles":{"cudy_wr3000p-v1":{},"cudy_wr3000-v1":{}}}
JSON

feed_ref() {
  printf '%s' "$1" | sha1sum | cut -c1-40
}
feed_url() {
  case "$1" in
    luci) printf 'https://git.openwrt.org/project/luci.git' ;;
    *) printf 'https://git.openwrt.org/feed/%s.git' "$1" ;;
  esac
}
: >"$target/feeds.buildinfo"
for feed in packages luci routing telephony video; do
  printf 'src-git %s %s^%s\n' "$feed" "$(feed_url "$feed")" "$(feed_ref "$feed")" >>"$target/feeds.buildinfo"
done

expected_urls=(
  "$target_url/packages/packages.adb"
  "$packages_url/base/packages.adb"
  "$target_url/kmods/6.12.94-1-5a6c1f71/packages.adb"
  "$packages_url/luci/packages.adb"
  "$packages_url/packages/packages.adb"
  "$packages_url/routing/packages.adb"
  "$packages_url/telephony/packages.adb"
  "$packages_url/video/packages.adb"
)
for url in "${expected_urls[@]}"; do
  index="$mirror/${url#"$base_url"/}"
  mkdir -p "$(dirname -- "$index")"
  printf 'index %s\n' "$url" >"$index"
done

write_lock() {
  local lock="$1"
  local feed

  {
    printf "OPENWRT_TAG='v25.12.5'\n"
    printf "OPENWRT_REF='%s'\n" "$(feed_ref openwrt)"
    for feed in packages luci routing telephony video; do
      printf "FEED_%s_URL='%s'\n" "${feed^^}" "$(feed_url "$feed")"
      printf "FEED_%s_REF='%s'\n" "${feed^^}" "$(feed_ref "$feed")"
    done
    printf "TARGET='mediatek'\nSUBTARGET='filogic'\nDEVICE_ID='cudy_wr3000p-v1'\n"
    printf "DEFAULT_BUILD_METHOD='imagebuilder'\n"
  } >"$lock"
}

lock="$tmp_root/build.lock"
write_lock "$lock"

before="$(sha256_of "$lock")"
"$pin_script" --dry-run "$lock" >"$tmp_root/dry-run.out" 2>"$tmp_root/dry-run.err"
[[ "$(sha256_of "$lock")" == "$before" ]] || die 'dry run modified the lock'
grep -Fqx "SDK_URL='$target_url/$sdk_archive'" "$tmp_root/dry-run.out" ||
  die 'dry run did not print the SDK pin'

"$pin_script" "$lock" 2>"$tmp_root/pin.err"
# shellcheck source=/dev/null
(
  source "$lock"
  [[ "$SDK_URL" == "$target_url/$sdk_archive" ]] || die "unexpected SDK_URL: $SDK_URL"
  [[ "$SDK_SHA256" == "$(printf 'a%.0s' {1..64})" ]] || die 'unexpected SDK_SHA256'
  [[ "$IMAGEBUILDER_URL" == "$target_url/$ib_archive" ]] || die "unexpected IMAGEBUILDER_URL: $IMAGEBUILDER_URL"
  [[ "$IMAGEBUILDER_SHA256" == "$(printf 'b%.0s' {1..64})" ]] || die 'unexpected IMAGEBUILDER_SHA256'
  ((${#IMAGEBUILDER_REPOSITORIES[@]} == ${#expected_urls[@]})) ||
    die "expected ${#expected_urls[@]} repositories, got ${#IMAGEBUILDER_REPOSITORIES[@]}"
  for i in "${!expected_urls[@]}"; do
    index="$mirror/${expected_urls[$i]#"$base_url"/}"
    [[ "${IMAGEBUILDER_REPOSITORIES[$i]}" == "${expected_urls[$i]}|$(sha256_of "$index")" ]] ||
      die "unexpected repository entry $i: ${IMAGEBUILDER_REPOSITORIES[$i]}"
  done
  [[ "$DEFAULT_BUILD_METHOD" == 'imagebuilder' ]] || die 'pinning changed an unrelated assignment'
)
grep -Fqx '# with scripts/pin-imagebuilder.sh, which rewrites these assignments.' "$lock" ||
  die 'appended pins have no refresh comment'

pinned="$(sha256_of "$lock")"
"$pin_script" "$lock" 2>/dev/null
[[ "$(sha256_of "$lock")" == "$pinned" ]] || die 'repinning unchanged release metadata changed the lock'

# A rebuilt upstream index changes only its own entry.
luci_index="$release/packages/aarch64_cortex-a53/luci/packages.adb"
cp "$lock" "$tmp_root/before-rebuild.lock"
printf 'rebuilt\n' >>"$luci_index"
"$pin_script" "$lock" 2>/dev/null
diff "$tmp_root/before-rebuild.lock" "$lock" >"$tmp_root/rebuild.diff" || true
[[ "$(grep -c '^[<>]' "$tmp_root/rebuild.diff")" == '2' ]] ||
  die 'a rebuilt index changed more than its own entry'
grep -Fqx ">   '$packages_url/luci/packages.adb|$(sha256_of "$luci_index")'" "$tmp_root/rebuild.diff" ||
  die 'the rebuilt index entry was not updated'

cp "$lock" "$tmp_root/feed-mismatch.lock"
sed -i "s|^FEED_LUCI_REF=.*|FEED_LUCI_REF='$(feed_ref luci-next)'|" "$tmp_root/feed-mismatch.lock"
before="$(sha256_of "$tmp_root/feed-mismatch.lock")"
expect_failure feed-mismatch 'release feed luci is' "$pin_script" "$tmp_root/feed-mismatch.lock"
[[ "$(sha256_of "$tmp_root/feed-mismatch.lock")" == "$before" ]] || die 'feed mismatch modified the lock'

cp "$lock" "$tmp_root/missing-profile.lock"
sed -i "s|^DEVICE_ID=.*|DEVICE_ID='cudy_wr3000e-v1'|" "$tmp_root/missing-profile.lock"
expect_failure missing-profile 'release has no ImageBuilder profile for cudy_wr3000e-v1' \
  "$pin_script" "$tmp_root/missing-profile.lock"

grep -v '^SDK_SHA256=' "$lock" >"$tmp_root/partial.lock"
expect_failure partial-pins 'lock has only some ImageBuilder pin assignments' \
  "$pin_script" "$tmp_root/partial.lock"

write_lock "$tmp_root/main.lock"
sed -i "/^OPENWRT_TAG=/d" "$tmp_root/main.lock"
expect_failure untagged 'ImageBuilder pins need a release OPENWRT_TAG' "$pin_script" "$tmp_root/main.lock"

rm "$luci_index"
expect_failure missing-index "failed to download $packages_url/luci/packages.adb" "$pin_script" "$lock"

printf '%s *%s\n' "$(printf 'e%.0s' {1..64})" \
  'openwrt-sdk-25.12.5-mediatek-filogic_gcc-15.1.0_musl.Linux-x86_64.tar.zst' >>"$target/sha256sums"
expect_failure two-sdks 'expected one release archive matching' "$pin_script" "$lock"

if grep -Ev "^$base_url/" "$TEST_CURL_LOG"; then
  die 'pin script fetched from outside the configured mirror'
fi

printf 'ImageBuilder pin checks passed\n'
