#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  local file="$1"
  [[ -f "$file" ]] || die "expected file to exist: $file"
}

assert_file_not_exists() {
  local file="$1"
  [[ ! -e "$file" ]] || die "expected file not to exist: $file"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || die "$file does not contain: $needle"
}

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/upgrade-router-image-test.XXXXXXXX")"
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$tmp_root/bin" "$tmp_root/remote/tmp" "$tmp_root/backups"

cat >"$tmp_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

host="$1"
shift
cmd="$*"
printf '%s\n' "$cmd" >>"$TEST_SSH_LOG"

remote_path() {
  local path="$1"
  case "$path" in
    /tmp) printf '%s/tmp\n' "$TEST_REMOTE_ROOT" ;;
    /tmp/*) printf '%s/tmp/%s\n' "$TEST_REMOTE_ROOT" "${path#/tmp/}" ;;
    *) printf 'unsupported remote path: %s\n' "$path" >&2; exit 1 ;;
  esac
}

case "$cmd" in
  'cat /etc/openwrt_release; printf "\n"; ubus call system board')
    cat <<'ROUTER'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.2'
DISTRIB_TARGET='mediatek/filogic'

{"model":"Cudy WR3000P v1","board_name":"cudy,wr3000p-v1"}
ROUTER
    ;;
  *)
    eval "set -- $cmd"
    case "${1:-}" in
      sysupgrade)
        case "${2:-}" in
          -b)
            dest="$(remote_path "$3")"
            mkdir -p "$(dirname "$dest")"
            printf 'backup\n' >"$dest"
            ;;
          -T)
            [[ -f "$(remote_path "$3")" ]] || exit 1
            ;;
          /tmp/*)
            printf 'flash %s\n' "$2" >>"$TEST_FLASH_LOG"
            ;;
          *)
            printf 'unexpected sysupgrade command for %s: %s\n' "$host" "$cmd" >&2
            exit 1
            ;;
        esac
        ;;
      rm)
        [[ "${2:-}" == '-f' ]] || exit 1
        rm -f "$(remote_path "$3")"
        ;;
      mkdir)
        [[ "${2:-}" == '-p' ]] || exit 1
        mkdir -p "$(remote_path "$3")"
        ;;
      df)
        cat <<DF
Filesystem           1K-blocks      Used Available Use% Mounted on
tmpfs                   100000         0 ${TEST_REMOTE_AVAILABLE_KIB:-100000}   0% /tmp
DF
        ;;
      sha256sum)
        if [[ "${TEST_BAD_REMOTE_SHA:-0}" == '1' ]]; then
          printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' "$2"
        else
          sha256sum "$(remote_path "$2")" | sed "s|$(remote_path "$2")|$2|"
        fi
        ;;
      *)
        printf 'unexpected ssh command for %s: %s\n' "$host" "$cmd" >&2
        exit 1
        ;;
    esac
    ;;
esac
EOF
chmod +x "$tmp_root/bin/ssh"

cat >"$tmp_root/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == '-O' ]]; then
  shift
fi
[[ $# -eq 2 ]] || exit 1
src="$1"
dest="$2"
printf '%s -> %s\n' "$src" "$dest" >>"$TEST_SCP_LOG"

unquote_remote_path() {
  local spec="$1"
  local path="${spec#*:}"
  eval "set -- $path"
  printf '%s\n' "$1"
}

remote_path() {
  local path="$1"
  case "$path" in
    /tmp) printf '%s/tmp\n' "$TEST_REMOTE_ROOT" ;;
    /tmp/*) printf '%s/tmp/%s\n' "$TEST_REMOTE_ROOT" "${path#/tmp/}" ;;
    *) printf 'unsupported remote path: %s\n' "$path" >&2; exit 1 ;;
  esac
}

case "$src:$dest" in
  *:*)
    if [[ "$src" == *:* ]]; then
      if [[ "${TEST_FAIL_BACKUP_SCP:-0}" == '1' ]]; then
        exit 1
      fi
      cp "$(remote_path "$(unquote_remote_path "$src")")" "$dest"
    elif [[ "$dest" == *:* ]]; then
      cp "$src" "$(remote_path "$(unquote_remote_path "$dest")")"
    else
      exit 1
    fi
    ;;
esac
EOF
chmod +x "$tmp_root/bin/scp"

export PATH="$tmp_root/bin:$PATH"
export TEST_REMOTE_ROOT="$tmp_root/remote"
export TEST_SSH_LOG="$tmp_root/ssh.log"
export TEST_SCP_LOG="$tmp_root/scp.log"
export TEST_FLASH_LOG="$tmp_root/flash.log"

image="$tmp_root/test-sysupgrade.bin"
printf 'firmware-image\n' >"$image"

run_script() {
  scripts/upgrade-router-image.sh --backup-dir "$tmp_root/backups" "$@"
}

: >"$TEST_SSH_LOG"
: >"$TEST_SCP_LOG"
: >"$TEST_FLASH_LOG"
run_script --no-flash router "$image"
assert_file_exists "$tmp_root/backups/router-"*
assert_file_not_exists "$tmp_root/remote/tmp/test-sysupgrade.bin"
assert_file_contains "$TEST_SSH_LOG" 'sysupgrade -T'
[[ ! -s "$TEST_FLASH_LOG" ]] || die 'no-flash unexpectedly flashed'

: >"$TEST_SSH_LOG"
: >"$TEST_SCP_LOG"
run_script --no-flash --keep-remote-image router "$image"
assert_file_exists "$tmp_root/remote/tmp/test-sysupgrade.bin"
rm -f "$tmp_root/remote/tmp/test-sysupgrade.bin"

: >"$TEST_SSH_LOG"
if TEST_REMOTE_AVAILABLE_KIB=1 run_script --no-flash router "$image" >/dev/null 2>&1; then
  die 'low remote free space unexpectedly succeeded'
fi
assert_file_not_exists "$tmp_root/remote/tmp/test-sysupgrade.bin"

if run_script --no-flash router "$image" --remote-image /tmp/../etc/config/network >/dev/null 2>&1; then
  die 'remote path traversal unexpectedly succeeded'
fi

: >"$TEST_SSH_LOG"
if TEST_BAD_REMOTE_SHA=1 run_script --no-flash router "$image" >/dev/null 2>&1; then
  die 'checksum mismatch unexpectedly succeeded'
fi
assert_file_not_exists "$tmp_root/remote/tmp/test-sysupgrade.bin"

: >"$TEST_SSH_LOG"
if TEST_FAIL_BACKUP_SCP=1 run_script --no-flash router "$image" >/dev/null 2>&1; then
  die 'backup scp failure unexpectedly succeeded'
fi
if find "$tmp_root/remote/tmp" -name '*sysupgrade-backup.tar.gz' -print -quit | grep -q .; then
  die 'remote backup was not cleaned after backup scp failure'
fi

: >"$TEST_SSH_LOG"
: >"$TEST_FLASH_LOG"
if run_script router "$image" </dev/null >/dev/null 2>&1; then
  die 'missing confirmation unexpectedly succeeded'
fi
assert_file_not_exists "$tmp_root/remote/tmp/test-sysupgrade.bin"
[[ ! -s "$TEST_FLASH_LOG" ]] || die 'missing confirmation unexpectedly flashed'

: >"$TEST_SSH_LOG"
: >"$TEST_FLASH_LOG"
run_script --yes router "$image" >/dev/null 2>&1
assert_file_contains "$TEST_FLASH_LOG" 'flash /tmp/test-sysupgrade.bin'
