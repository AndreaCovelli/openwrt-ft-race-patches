#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/upgrade-router-image.sh [options] <ssh-target> <sysupgrade-image>

Options:
  --backup-dir DIR       Local directory for router config backups.
                         Default: ./backups
  --remote-image PATH    Remote image path. Default:
                         /tmp/<local-image-basename>
  --keep-remote-image    Do not remove the copied image after --no-flash,
                         cancellation, or pre-upgrade errors.
  --yes                  Run the actual sysupgrade after preflight passes.
                         Without this flag, prompt before flashing.
  --no-flash             Stop after backup, copy, checksum, and sysupgrade -T.
  --help                 Show this message.

The script backs up the router's sysupgrade config set before copying or
flashing the image. OpenWrt Dropbear commonly lacks SFTP, so image and backup
copies use legacy scp mode.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$REPO_ROOT" "$1" ;;
  esac
}

safe_name() {
  printf '%s\n' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

remote_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

backup_dir='backups'
remote_image=''
keep_remote_image='0'
assume_yes='0'
no_flash='0'
remote_backup_created='0'
remote_image_copied='0'
flash_started='0'

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir)
      [[ $# -ge 2 ]] || die "--backup-dir requires a value"
      backup_dir="$2"
      shift 2
      ;;
    --remote-image)
      [[ $# -ge 2 ]] || die "--remote-image requires a value"
      remote_image="$2"
      shift 2
      ;;
    --keep-remote-image)
      keep_remote_image='1'
      shift
      ;;
    --yes|-y)
      assume_yes='1'
      shift
      ;;
    --no-flash)
      no_flash='1'
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        POSITIONAL+=("$1")
        shift
      done
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

[[ ${#POSITIONAL[@]} -eq 2 ]] || {
  usage >&2
  exit 1
}

ssh_target="${POSITIONAL[0]}"
image_path="$(abs_path "${POSITIONAL[1]}")"
backup_dir="$(abs_path "$backup_dir")"

[[ -f "$image_path" ]] || die "sysupgrade image not found: $image_path"
[[ "$image_path" == *sysupgrade*.bin ]] ||
  die "image path does not look like a sysupgrade image: $image_path"

case "$assume_yes:$no_flash" in
  1:1) die "--yes and --no-flash cannot be used together" ;;
esac

require_cmd awk basename date dirname grep mkdir scp sed sha256sum ssh stat

image_base="$(basename "$image_path")"
if [[ -z "$remote_image" ]]; then
  remote_image="/tmp/$image_base"
fi
case "$remote_image" in
  /tmp/*) ;;
  *) die "--remote-image must be under /tmp: $remote_image" ;;
esac
remote_image_base="$(basename "$remote_image")"
[[ "$remote_image" == "/tmp/$remote_image_base" &&
  "$remote_image_base" != '.' &&
  "$remote_image_base" != '..' ]] ||
  die "--remote-image must be a direct /tmp filename: $remote_image"

remote_image_dir="$(dirname "$remote_image")"

cleanup_remote_files() {
  local status=$?
  set +e

  if [[ "$remote_backup_created" == '1' ]]; then
    ssh "$ssh_target" "rm -f $(remote_quote "$remote_backup")" >/dev/null 2>&1 || true
  fi

  if [[ "$remote_image_copied" == '1' &&
        "$flash_started" != '1' &&
        "$keep_remote_image" != '1' ]]; then
    ssh "$ssh_target" "rm -f $(remote_quote "$remote_image")" >/dev/null 2>&1 || true
  fi

  exit "$status"
}
trap cleanup_remote_files EXIT INT TERM

mkdir -p "$backup_dir"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
target_name="$(safe_name "$ssh_target")"
local_backup="$backup_dir/${target_name}-${timestamp}-sysupgrade-backup.tar.gz"
remote_backup="/tmp/${target_name}-${timestamp}-sysupgrade-backup.tar.gz"

local_sha="$(sha256sum "$image_path" | awk '{ print $1 }')"
image_size_bytes="$(stat -c '%s' "$image_path")"
image_size_kib="$(((image_size_bytes + 1023) / 1024))"
required_remote_kib="$((image_size_kib + 4096))"

log "Reading router identity from $ssh_target"
ssh "$ssh_target" 'cat /etc/openwrt_release; printf "\n"; ubus call system board'

log "Creating router config backup: $remote_backup"
ssh "$ssh_target" "sysupgrade -b $(remote_quote "$remote_backup")"
remote_backup_created='1'

log "Copying router config backup to $local_backup"
scp -O "$ssh_target:$(remote_quote "$remote_backup")" "$local_backup"
ssh "$ssh_target" "rm -f $(remote_quote "$remote_backup")"
remote_backup_created='0'

log "Checking remote free space in $remote_image_dir"
ssh "$ssh_target" "mkdir -p $(remote_quote "$remote_image_dir")"
remote_available_kib="$(
  ssh "$ssh_target" "df -k $(remote_quote "$remote_image_dir")" |
    awk 'END { print $(NF - 2) }'
)"
case "$remote_available_kib" in
  ''|*[!0-9]*) die "could not determine free space for $remote_image_dir on $ssh_target" ;;
esac
((remote_available_kib >= required_remote_kib)) ||
  die "not enough free space in $remote_image_dir on $ssh_target: need ${required_remote_kib} KiB, have ${remote_available_kib} KiB"

log "Copying image to $ssh_target:$remote_image"
scp -O "$image_path" "$ssh_target:$(remote_quote "$remote_image")"
remote_image_copied='1'

log "Verifying remote image checksum"
remote_sha="$(
  ssh "$ssh_target" "sha256sum $(remote_quote "$remote_image")" |
    awk '{ print $1 }'
)"
[[ "$remote_sha" == "$local_sha" ]] ||
  die "remote checksum mismatch for $remote_image: expected $local_sha got $remote_sha"

log "Running sysupgrade test"
ssh "$ssh_target" "sysupgrade -T $(remote_quote "$remote_image")"

if [[ "$no_flash" == '1' ]]; then
  log "Preflight complete; --no-flash requested"
  printf 'backup=%s\n' "$local_backup"
  printf 'image=%s\n' "$remote_image"
  printf 'sha256=%s\n' "$local_sha"
  exit 0
fi

if [[ "$assume_yes" != '1' ]]; then
  printf 'Flash %s on %s now? Type "yes" to continue: ' "$remote_image" "$ssh_target" >&2
  if ! read -r answer; then
    die "confirmation required; rerun with --yes only after verifying the target and image"
  fi
  [[ "$answer" == 'yes' ]] || die "upgrade cancelled"
fi

log "Starting sysupgrade on $ssh_target; SSH will disconnect during reboot"
sysupgrade_start_marker='__OPENWRT_FT_SYSUPGRADE_START__'
set +e
sysupgrade_output="$(
  ssh "$ssh_target" "printf '%s\n' $(remote_quote "$sysupgrade_start_marker"); exec sysupgrade $(remote_quote "$remote_image")" 2>&1
)"
sysupgrade_status=$?
set -e
if printf '%s\n' "$sysupgrade_output" | grep -Fxq -- "$sysupgrade_start_marker"; then
  if [[ "$sysupgrade_status" == '0' || "$sysupgrade_status" == '255' ]]; then
    flash_started='1'
    printf '%s\n' "$sysupgrade_output" | sed "/^$sysupgrade_start_marker$/d"
  else
    printf '%s\n' "$sysupgrade_output" | sed "/^$sysupgrade_start_marker$/d" >&2
    die "sysupgrade command failed after start marker with exit status $sysupgrade_status"
  fi
else
  printf '%s\n' "$sysupgrade_output" >&2
  die "ssh disconnected before sysupgrade start marker with exit status $sysupgrade_status"
fi
