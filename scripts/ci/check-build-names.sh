#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"

# shellcheck source=scripts/lib/build-name.sh
source "$repo_root/scripts/lib/build-name.sh"

assert_name() {
  local description="$1"
  local expected="$2"
  local actual="$3"

  [[ "$actual" == "$expected" ]] || {
    printf 'error: %s: expected %s got %s\n' "$description" "$expected" "$actual" >&2
    exit 1
  }
}

assert_fails() {
  local description="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'error: %s: command unexpectedly succeeded\n' "$description" >&2
    exit 1
  fi
}

tagged_name="$(
  OPENWRT_TAG='v25.12.2'
  OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
  DEVICE_ID='cudy_wr3000p-v1'
  ARTIFACT_VARIANT='patched'
  openwrt_default_build_name '20260519T143000Z'
)"
assert_name \
  'tagged build name' \
  'openwrt-ft-cudy_wr3000p-v1-25.12.2-patched-20260519T143000Z' \
  "$tagged_name"

untagged_name="$(
  OPENWRT_TAG=''
  OPENWRT_REF='8de418547f61d48315d115ed035b61464b3f1140'
  DEVICE_ID='cudy_wr3000e-v1'
  ARTIFACT_VARIANT='main-compilecheck'
  openwrt_default_build_name '20260519T143000Z'
)"
assert_name \
  'untagged build name' \
  'openwrt-ft-cudy_wr3000e-v1-ref-8de418547f61-main-compilecheck-20260519T143000Z' \
  "$untagged_name"

assert_fails 'invalid device id' bash -c '
  source "$1"
  OPENWRT_TAG=v25.12.2
  OPENWRT_REF=d266501ad6188cce279a487b1ce61f4f327cd496
  DEVICE_ID="bad/device"
  ARTIFACT_VARIANT=patched
  openwrt_default_build_name 20260519T143000Z
' bash "$repo_root/scripts/lib/build-name.sh"

assert_fails 'untagged build without full ref' bash -c '
  source "$1"
  OPENWRT_TAG=
  OPENWRT_REF=8de418
  DEVICE_ID=cudy_wr3000e-v1
  ARTIFACT_VARIANT=main-compilecheck
  openwrt_default_build_name 20260519T143000Z
' bash "$repo_root/scripts/lib/build-name.sh"

tmp_lock="$(mktemp "${TMPDIR:-/tmp}/openwrt-build-name-lock.XXXXXXXX")"
trap 'rm -f "$tmp_lock"' EXIT

cat >"$tmp_lock" <<'EOF'
OPENWRT_TAG='v25.12.2'
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
DEVICE_ID='cudy_wr3000p-v1'
ARTIFACT_VARIANT='patched'
SESSION_NAME='bad/session'
ARTIFACT_DIR='/tmp/bad-artifact-dir'
KEEP_INSTANCE='1'
REMOTE_ROOT='bad/root'
EOF

SESSION_NAME='caller-session'
ARTIFACT_DIR='caller-artifacts'
KEEP_INSTANCE='0'
REMOTE_ROOT='caller-root'
lock_name="$(openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z')"

assert_name \
  'lock build name isolation' \
  'openwrt-ft-cudy_wr3000p-v1-25.12.2-patched-20260519T143000Z' \
  "$lock_name"
assert_name 'caller SESSION_NAME preserved' 'caller-session' "$SESSION_NAME"
assert_name 'caller ARTIFACT_DIR preserved' 'caller-artifacts' "$ARTIFACT_DIR"
assert_name 'caller KEEP_INSTANCE preserved' '0' "$KEEP_INSTANCE"
assert_name 'caller REMOTE_ROOT preserved' 'caller-root' "$REMOTE_ROOT"

cat >"$tmp_lock" <<'EOF'
OPENWRT_TAG='v25.12.2'
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
DEVICE_ID='cudy_wr3000p-v1'
EOF

ARTIFACT_VARIANT='caller-variant'
assert_fails \
  'lock build name does not inherit caller artifact variant' \
  openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z'

cat >"$tmp_lock" <<'EOF'
OPENWRT_TAG='v25.12.2'
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
DEVICE_ID='cudy_wr3000p-v1'
ARTIFACT_VARIANT='patched
EOF

assert_fails \
  'lock parser rejects unterminated artifact variant assignment' \
  openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z'

cat >"$tmp_lock" <<'EOF'
OPENWRT_TAG='v25.12.2' # stable
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
DEVICE_ID='cudy_wr3000p-v1'
ARTIFACT_VARIANT='patched'
EOF

assert_fails \
  'lock parser rejects inline comments on build-name fields' \
  openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z'

cat >"$tmp_lock" <<'EOF'
OPENWRT_TAG='v25.12.2'
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
DEVICE_ID='cudy_wr3000p-v1'
ARTIFACT_VARIANT='patched'
ARTIFACT_VARIANT='patched
EOF

assert_fails \
  'lock parser rejects malformed duplicate build-name assignment' \
  openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z'

cat >"$tmp_lock" <<'EOF'
OPENWRT_TAG='v25.12.2'
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
 DEVICE_ID='cudy_wr3000p-v1'
ARTIFACT_VARIANT='patched'
EOF

assert_fails \
  'lock parser rejects indented build-name assignment' \
  openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z'

cat >"$tmp_lock" <<'EOF'
OPENWRT_TAG='v25.12.2'
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
DEVICE_ID='cudy_wr3000p-v1'
 DEVICE_ID='cudy_wr3000e-v1'
ARTIFACT_VARIANT='patched'
EOF

assert_fails \
  'lock parser rejects indented duplicate build-name assignment' \
  openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z'

cat >"$tmp_lock" <<'EOF'
OPENWRT_TAG='v25.12.2'
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
DEVICE_ID='cudy_wr3000p-v1'
 ARTIFACT_VARIANT='patched
EOF

assert_fails \
  'lock parser rejects indented malformed build-name assignment' \
  openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z'

side_effect_file="$(mktemp "${TMPDIR:-/tmp}/openwrt-build-name-side-effect.XXXXXXXX")"
rm -f "$side_effect_file"

cat >"$tmp_lock" <<EOF
OPENWRT_TAG='v25.12.2'
OPENWRT_REF='d266501ad6188cce279a487b1ce61f4f327cd496'
DEVICE_ID='cudy_wr3000p-v1'
ARTIFACT_VARIANT='patched'
touch '$side_effect_file'
EOF

side_effect_name="$(openwrt_default_build_name_from_lock "$tmp_lock" '20260519T143000Z')"
assert_name \
  'lock parser ignores side-effecting lines' \
  'openwrt-ft-cudy_wr3000p-v1-25.12.2-patched-20260519T143000Z' \
  "$side_effect_name"

[[ ! -e "$side_effect_file" ]] || {
  printf 'error: lock build name parser executed a side-effecting line\n' >&2
  exit 1
}
