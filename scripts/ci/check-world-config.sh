#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/lib/world-config.sh
source "$repo_root/scripts/lib/world-config.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-world-config.XXXXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
cat >"$tmp_root/packageinfo" <<'EOF'
Package: htop
Version: 1

Package: libubox
ABI-Version: 20260213

Package: libpcre2
ABI-Version: 0

Package: kmod-example
ABI-Version: 6.12.94
EOF
cat >"$tmp_root/world" <<'EOF'
htop=1
libubox20260213
libpcre2-0
kmod-example
kmod-builtin
kernel
EOF
printf 'kmod-builtin\n' >"$tmp_root/builtin"
world_config_resolve "$tmp_root/packageinfo" "$tmp_root/world" "$tmp_root/builtin" \
  >"$tmp_root/selections"
printf 'htop\thtop\nlibubox20260213\tlibubox\nlibpcre2-0\tlibpcre2\nkmod-example\tkmod-example\nkernel\t-\n' \
  >"$tmp_root/expected"
cmp -s "$tmp_root/expected" "$tmp_root/selections" || die 'incorrect APK ABI or built-in mapping'

cat >"$tmp_root/config" <<'EOF'
CONFIG_TARGET_TEST=y
CONFIG_PACKAGE_htop=m
# CONFIG_PACKAGE_libubox is not set
CONFIG_PACKAGE_libpcre2=y
CONFIG_PACKAGE_kmod-example=y
CONFIG_PACKAGE_unrelated=m
EOF
world_config_missing "$tmp_root/selections" "$tmp_root/config" >"$tmp_root/missing"
printf 'htop\nlibubox20260213\n' >"$tmp_root/expected"
cmp -s "$tmp_root/expected" "$tmp_root/missing" || die 'module-only or disabled package was considered included'
world_config_apply "$tmp_root/selections" "$tmp_root/config" >"$tmp_root/selected.config"
world_config_missing "$tmp_root/selections" "$tmp_root/selected.config" >"$tmp_root/missing"
[[ ! -s "$tmp_root/missing" ]] || die 'required packages were not selected'
grep -Fqx 'CONFIG_TARGET_TEST=y' "$tmp_root/selected.config" || die 'target selection was lost'
grep -Fqx 'CONFIG_PACKAGE_unrelated=m' "$tmp_root/selected.config" || die 'unrelated package setting changed'
[[ "$(grep -c '^CONFIG_PACKAGE_htop=' "$tmp_root/selected.config")" == 1 ]] || die 'duplicate package settings'
if grep -Eq '^CONFIG_PACKAGE_(kernel|-)=y$' "$tmp_root/selected.config"; then
  die 'the automatic kernel package generated a nonexistent Kconfig selection'
fi

for invalid in libubox20200101 missing-package 'htop@untrusted-feed'; do
  printf '%s\n' "$invalid" >"$tmp_root/world"
  if world_config_resolve "$tmp_root/packageinfo" "$tmp_root/world" "$tmp_root/builtin" \
    >"$tmp_root/selections" 2>"$tmp_root/error"; then
    die "unsupported world entry was accepted: $invalid"
  fi
  grep -Fq "$invalid" "$tmp_root/error" || die 'unresolvable package was not identified'
done
