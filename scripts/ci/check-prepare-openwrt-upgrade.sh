#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) die "expected output to contain: $needle" ;;
  esac
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || die "$file does not contain: $needle"
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    die "$file unexpectedly contains: $needle"
  fi
}

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/prepare-openwrt-upgrade-test.XXXXXXXX")"
repo_tmp="$repo_root/.tmp-prepare-openwrt-upgrade-test"
cleanup() {
  rm -rf "$tmp_root" "$repo_tmp"
}
trap cleanup EXIT

mkdir -p "$tmp_root/bin" "$repo_tmp/devices/wr3000e" "$repo_tmp/devices/wr3000p"

cat >"$tmp_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "${1:-}" == '-o' ]]; do
  shift 2
done
host="$1"
shift
if [[ -n "${TEST_SSH_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$TEST_SSH_LOG"
fi
case "$*" in
  'cat /etc/openwrt_release')
    release="${TEST_ROUTER_RELEASE:-25.12.2}"
    revision='r32802-f505120278'
    if [[ "$release" == '25.12.4' ]]; then
      revision='r32933-4ccb782af7'
    fi
    cat <<RELEASE
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='$release'
DISTRIB_REVISION='$revision'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
DISTRIB_DESCRIPTION='OpenWrt $release $revision'
RELEASE
    ;;
  'cat /tmp/sysinfo/board_name 2>/dev/null || true')
    printf '%s\n' "${TEST_ROUTER_BOARD:-cudy,wr3000e-v1}"
    ;;
  'uci -q get attendedsysupgrade.server.url 2>/dev/null || true')
    printf '%s\n' "${TEST_ASU_SERVER:-https://sysupgrade.example.test}"
    ;;
  'cat /lib/apk/db/installed')
    cat <<'APKDB'
P:base-files
V:1699~f505120278

P:kernel
V:6.12.74~f8127f4e841121b7a9126117c4b2fb3c-r1

P:luci
V:26.001

P:htop
V:3.4.1-r1
APKDB
    ;;
  'apk list --installed')
    cat <<'APKLIST'
base-files-1699~f505120278 aarch64_cortex-a53 {feeds/base/base-files} (GPL-2.0) [installed]
kernel-6.12.74~f8127f4e841121b7a9126117c4b2fb3c-r1 aarch64_cortex-a53 {feeds/base/kernel} (GPL-2.0) [installed]
luci-26.001 noarch {feeds/luci/collections/luci} (Apache-2.0) [installed]
htop-3.4.1-r1 aarch64_cortex-a53 {feeds/packages/htop} (GPL-2.0) [installed]
APKLIST
    ;;
  'cat /etc/apk/world')
    cat <<'WORLD'
base-files=1699~f505120278
kernel=6.12.74~f8127f4e841121b7a9126117c4b2fb3c-r1
luci
htop=3.4.1-r1
WORLD
    ;;
  *)
    printf 'unexpected ssh command for %s: %s\n' "$host" "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$tmp_root/bin/ssh"

cat >"$tmp_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
case "$url" in
  'https://sysupgrade.example.test/json/v1/overview.json')
    cat <<'JSON'
{"latest":["24.10.6"],"branches":{"25.12":{"versions":["25.12.2","25.12.4"]}}}
JSON
    ;;
  'https://sysupgrade.example.test/json/v1/releases/25.12.4/targets/mediatek/filogic/cudy_wr3000e-v1.json')
    cat <<'JSON'
{"version_number":"25.12.4","version_code":"r32933-4ccb782af7","target":"mediatek/filogic","id":"cudy_wr3000e-v1","supported_devices":["cudy,wr3000e-v1","R53"]}
JSON
    ;;
  'https://sysupgrade.example.test/json/v1/releases/25.12.4/targets/mediatek/filogic/cudy_wr3000p-v1.json')
    cat <<'JSON'
{"version_number":"25.12.4","version_code":"r32933-4ccb782af7","target":"mediatek/filogic","id":"cudy_wr3000p-v1","supported_devices":["cudy,wr3000p-v1"]}
JSON
    ;;
  'https://downloads.openwrt.org/releases/25.12.4/targets/mediatek/filogic/feeds.buildinfo')
    cat <<'BUILDINFO'
src-git packages https://git.openwrt.org/feed/packages.git^f91b06b3faff7ad3c8cbeb1ab39cef680d2f28ed
src-git luci https://github.com/openwrt/luci.git^e9ebca7598ce2f754b76267fd66bf2b85e6e4347
src-git routing https://github.com/openwrt/routing.git^b2097c85bef85251364f59a6b2a3ed1f9f5c0c21
src-git telephony https://github.com/openwrt/telephony.git^2618106d5846a4a542fdf5809f0d3ed228ce439b
BUILDINFO
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "$url" >&2
    exit 22
    ;;
esac
EOF
chmod +x "$tmp_root/bin/curl"

real_git="$(command -v git)"
cat >"$tmp_root/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == 'ls-remote' ]]; then
  url="\$2"
  ref="\$3"
  case "\$url \$ref" in
    'https://git.openwrt.org/openwrt/openwrt.git refs/tags/v25.12.4^{}')
      printf 'ba915c2ee711d047d5be8575c1e98699119429ab\trefs/tags/v25.12.4^{}\n'
      ;;
    *)
      printf 'unexpected git ls-remote: %s %s\n' "\$url" "\$ref" >&2
      exit 2
      ;;
  esac
else
  exec "$real_git" "\$@"
fi
EOF
chmod +x "$tmp_root/bin/git"

export PATH="$tmp_root/bin:$PATH"
export PREPARE_OPENWRT_UPGRADE_PATH_PREFIX="$tmp_root/bin"

out_bad_cli_server="$tmp_root/prepare-upgrade-bad-cli-server.out"
out_up_to_date="$tmp_root/prepare-upgrade-up-to-date.out"
out_board_mismatch="$tmp_root/prepare-upgrade-board-mismatch.out"
out_bad_path="$tmp_root/prepare-upgrade-bad-path.out"
out_conflict="$tmp_root/prepare-upgrade-conflict.out"
out_downgrade="$tmp_root/prepare-upgrade-downgrade.out"
out_bad_server="$tmp_root/prepare-upgrade-bad-server.out"
out_http_server="$tmp_root/prepare-upgrade-http-server.out"
out_bad_build_script="$tmp_root/prepare-upgrade-bad-build-script.out"

before_lock="$(sha256sum locks/build-wr3000e.lock | awk '{ print $1 }')"
TEST_SSH_LOG="$tmp_root/dry-run-ssh.log"
export TEST_SSH_LOG
dry_run_output="$(
  scripts/prepare-openwrt-upgrade.sh --dry-run router locks/build-wr3000e.lock -- --make-jobs 4
)"
unset TEST_SSH_LOG
after_lock="$(sha256sum locks/build-wr3000e.lock | awk '{ print $1 }')"
[[ "$before_lock" == "$after_lock" ]] || die 'dry run modified the selected lock'
assert_contains "$dry_run_output" 'Selected release: 25.12.4 (r32933-4ccb782af7)'
assert_contains "$dry_run_output" "Would update $repo_root/locks/build-wr3000e.lock"
assert_contains "$dry_run_output" 'Build command:'
assert_contains "$dry_run_output" '--no-strict-manifest'
assert_contains "$dry_run_output" '--make-jobs'
assert_contains "$dry_run_output" 'Dry run only; build not started.'
assert_file_not_contains "$tmp_root/dry-run-ssh.log" 'cat /lib/apk/db/installed'
assert_file_not_contains "$tmp_root/dry-run-ssh.log" 'apk list --installed'
assert_file_not_contains "$tmp_root/dry-run-ssh.log" 'cat /etc/apk/world'

custom_builder_output="$(
  BUILD_SCRIPT=/tmp/custom-openwrt-build scripts/prepare-openwrt-upgrade.sh --dry-run router locks/build-wr3000e.lock
)"
assert_contains "$custom_builder_output" '/tmp/custom-openwrt-build'

TEST_SSH_LOG="$tmp_root/bad-build-script-ssh.log"
export TEST_SSH_LOG
missing_builder_lock_before="$(sha256sum locks/build-wr3000e.lock | awk '{ print $1 }')"
missing_builder_manifest_before="$(sha256sum devices/wr3000e/installed.manifest | awk '{ print $1 }')"
missing_builder_world_before="$(sha256sum devices/wr3000e/apk-installed-and-world.txt | awk '{ print $1 }')"
if BUILD_SCRIPT="$tmp_root/missing-build-wrapper" scripts/prepare-openwrt-upgrade.sh router locks/build-wr3000e.lock >"$out_bad_build_script" 2>&1; then
  die 'missing BUILD_SCRIPT unexpectedly succeeded'
fi
unset TEST_SSH_LOG
assert_file_contains "$out_bad_build_script" 'BUILD_SCRIPT is not executable'
[[ ! -e "$tmp_root/bad-build-script-ssh.log" ]] || die 'missing BUILD_SCRIPT should fail before SSH'
[[ "$(sha256sum locks/build-wr3000e.lock | awk '{ print $1 }')" == "$missing_builder_lock_before" ]] || die 'missing BUILD_SCRIPT modified the selected lock'
[[ "$(sha256sum devices/wr3000e/installed.manifest | awk '{ print $1 }')" == "$missing_builder_manifest_before" ]] || die 'missing BUILD_SCRIPT modified the reference manifest'
[[ "$(sha256sum devices/wr3000e/apk-installed-and-world.txt | awk '{ print $1 }')" == "$missing_builder_world_before" ]] || die 'missing BUILD_SCRIPT modified the world source'

if scripts/prepare-openwrt-upgrade.sh --server file:///tmp/asu --dry-run router locks/build-wr3000e.lock >"$out_bad_cli_server" 2>&1; then
  die 'bad CLI ASU server URL unexpectedly succeeded'
fi
assert_file_contains "$out_bad_cli_server" 'ASU server URL must start with https://'

cp devices/wr3000e/diffconfig "$repo_tmp/devices/wr3000e/diffconfig"
cp devices/wr3000e/installed.manifest "$repo_tmp/devices/wr3000e/installed.manifest"
cp devices/wr3000e/apk-installed-and-world.txt "$repo_tmp/devices/wr3000e/apk-installed-and-world.txt"
sed \
  -e "s|CONFIG_FRAGMENT='devices/wr3000e/diffconfig'|CONFIG_FRAGMENT='.tmp-prepare-openwrt-upgrade-test/devices/wr3000e/diffconfig'|" \
  -e "s|WORLD_SOURCE='devices/wr3000e/apk-installed-and-world.txt'|WORLD_SOURCE='.tmp-prepare-openwrt-upgrade-test/devices/wr3000e/apk-installed-and-world.txt'|" \
  -e "s|REFERENCE_MANIFEST='devices/wr3000e/installed.manifest'|REFERENCE_MANIFEST='.tmp-prepare-openwrt-upgrade-test/devices/wr3000e/installed.manifest'|" \
  locks/build-wr3000e.lock >"$repo_tmp/build-wr3000e.lock"

TEST_ROUTER_RELEASE='25.12.4' scripts/prepare-openwrt-upgrade.sh --version 25.12.4 router .tmp-prepare-openwrt-upgrade-test/build-wr3000e.lock >"$out_up_to_date"
assert_file_contains "$repo_tmp/build-wr3000e.lock" "OPENWRT_TAG='v25.12.4'"
assert_file_contains "$repo_tmp/build-wr3000e.lock" "OPENWRT_REF='ba915c2ee711d047d5be8575c1e98699119429ab'"
assert_file_contains "$repo_tmp/build-wr3000e.lock" "FEED_PACKAGES_REF='f91b06b3faff7ad3c8cbeb1ab39cef680d2f28ed'"
assert_file_contains "$repo_tmp/build-wr3000e.lock" "FEED_LUCI_REF='e9ebca7598ce2f754b76267fd66bf2b85e6e4347'"
assert_file_contains "$repo_tmp/build-wr3000e.lock" "FEED_VIDEO_REF='094bf58da6682f895255a35a84349a79dab4bf95'"
assert_file_contains "$repo_tmp/devices/wr3000e/installed.manifest" 'base-files - 1699~f505120278'
assert_file_contains "$repo_tmp/devices/wr3000e/apk-installed-and-world.txt" '__WORLD__'
assert_file_contains "$repo_tmp/devices/wr3000e/apk-installed-and-world.txt" 'kernel'
assert_file_not_contains "$repo_tmp/devices/wr3000e/apk-installed-and-world.txt" 'kernel='
assert_file_contains "$out_up_to_date" 'Router is already on 25.12.4; build not started.'

cat >"$tmp_root/build-wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$PATH" == "$EXPECTED_BUILDER_PATH" ]]
[[ "$1" == --no-strict-manifest && "$2" == --make-jobs && "$3" == 4 ]]
# shellcheck source=/dev/null
source "${@: -1}"
awk 'found { print } /^__WORLD__$/ { found=1 }' "$WORLD_SOURCE" >"$TEST_CAPTURED_WORLD"
EOF
chmod +x "$tmp_root/build-wrapper"
EXPECTED_BUILDER_PATH="$PATH" TEST_CAPTURED_WORLD="$tmp_root/captured.world" \
  BUILD_SCRIPT="$tmp_root/build-wrapper" scripts/prepare-openwrt-upgrade.sh \
    --version 25.12.4 router .tmp-prepare-openwrt-upgrade-test/build-wr3000e.lock \
    -- --make-jobs 4 >"$tmp_root/prepare-and-build.out"
grep -Fqx 'htop' "$tmp_root/captured.world" || die 'newly installed package was not passed to the builder world input'
assert_file_contains "$repo_tmp/devices/wr3000e/installed.manifest" 'htop - 3.4.1-r1'

if TEST_ROUTER_BOARD='cudy,wr3000-v1' scripts/prepare-openwrt-upgrade.sh --dry-run router locks/build-wr3000e.lock >"$out_board_mismatch" 2>&1; then
  die 'board mismatch unexpectedly succeeded'
fi
assert_file_contains "$out_board_mismatch" 'does not support router board cudy,wr3000-v1'

out_prebuilt_dry_run="$tmp_root/prepare-upgrade-prebuilt-dry-run.out"
p_lock_before="$(sha256sum locks/build-wr3000p.lock | awk '{ print $1 }')"
TEST_ROUTER_BOARD='cudy,wr3000p-v1' scripts/prepare-openwrt-upgrade.sh \
  --version 25.12.4 --dry-run router locks/build-wr3000p.lock >"$out_prebuilt_dry_run" 2>&1
assert_file_contains "$out_prebuilt_dry_run" 'Prebuilt APK built for 25.12.5, not 25.12.4: usteer-'
assert_file_contains "$out_prebuilt_dry_run" 'Warning: publish matching prebuilt APKs'
[[ "$(sha256sum locks/build-wr3000p.lock | awk '{ print $1 }')" == "$p_lock_before" ]] ||
  die 'prebuilt APK dry run modified the selected lock'

cp devices/wr3000p/diffconfig devices/wr3000p/installed.manifest \
  devices/wr3000p/apk-installed-and-world.txt "$repo_tmp/devices/wr3000p/"
sed \
  -e "s|'devices/wr3000p/|'.tmp-prepare-openwrt-upgrade-test/devices/wr3000p/|" \
  locks/build-wr3000p.lock >"$repo_tmp/build-wr3000p.lock"
p_tmp_lock_before="$(sha256sum "$repo_tmp/build-wr3000p.lock" | awk '{ print $1 }')"
out_prebuilt_mismatch="$tmp_root/prepare-upgrade-prebuilt-mismatch.out"
if TEST_ROUTER_BOARD='cudy,wr3000p-v1' BUILD_SCRIPT="$tmp_root/build-wrapper" \
  scripts/prepare-openwrt-upgrade.sh --version 25.12.4 router \
    .tmp-prepare-openwrt-upgrade-test/build-wr3000p.lock >"$out_prebuilt_mismatch" 2>&1; then
  die 'prebuilt APK release mismatch unexpectedly succeeded'
fi
assert_file_contains "$out_prebuilt_mismatch" 'pass --allow-prebuilt-apk-mismatch'
[[ "$(sha256sum "$repo_tmp/build-wr3000p.lock" | awk '{ print $1 }')" == "$p_tmp_lock_before" ]] ||
  die 'prebuilt APK release mismatch modified the selected lock'

EXPECTED_BUILDER_PATH="$PATH" TEST_CAPTURED_WORLD="$tmp_root/captured-p.world" \
  TEST_ROUTER_BOARD='cudy,wr3000p-v1' BUILD_SCRIPT="$tmp_root/build-wrapper" \
  scripts/prepare-openwrt-upgrade.sh --version 25.12.4 --allow-prebuilt-apk-mismatch \
    router .tmp-prepare-openwrt-upgrade-test/build-wr3000p.lock \
    -- --make-jobs 4 >"$tmp_root/prepare-upgrade-prebuilt-allowed.out" 2>&1
assert_file_contains "$repo_tmp/build-wr3000p.lock" "OPENWRT_TAG='v25.12.4'"

bad_lock="$repo_tmp/bad-path.lock"
sed "s|REFERENCE_MANIFEST='devices/wr3000e/installed.manifest'|REFERENCE_MANIFEST='../outside.manifest'|" locks/build-wr3000e.lock >"$bad_lock"
if scripts/prepare-openwrt-upgrade.sh --dry-run router "$bad_lock" >"$out_bad_path" 2>&1; then
  die 'bad reference manifest path unexpectedly succeeded'
fi
assert_file_contains "$out_bad_path" 'reference manifest not found'

if scripts/prepare-openwrt-upgrade.sh --dry-run router locks/build-wr3000e.lock -- --strict-manifest >"$out_conflict" 2>&1; then
  die 'conflicting strict manifest flag unexpectedly succeeded'
fi
assert_file_contains "$out_conflict" 'do not pass --strict-manifest'

if TEST_ROUTER_RELEASE='25.12.5' scripts/prepare-openwrt-upgrade.sh --dry-run router locks/build-wr3000e.lock >"$out_downgrade" 2>&1; then
  die 'same-branch downgrade unexpectedly succeeded'
fi
assert_file_contains "$out_downgrade" 'refusing downgrade to 25.12.4'

if TEST_ASU_SERVER='file:///tmp/asu' scripts/prepare-openwrt-upgrade.sh --dry-run router locks/build-wr3000e.lock >"$out_bad_server" 2>&1; then
  die 'bad ASU server URL unexpectedly succeeded'
fi
assert_file_contains "$out_bad_server" 'ASU server URL must start with https://'

if TEST_ASU_SERVER='http://sysupgrade.example.test' scripts/prepare-openwrt-upgrade.sh --dry-run router locks/build-wr3000e.lock >"$out_http_server" 2>&1; then
  die 'plain HTTP ASU server URL unexpectedly succeeded'
fi
assert_file_contains "$out_http_server" 'ASU server URL must start with https://'
