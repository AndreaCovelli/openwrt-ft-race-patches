#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
wrapper="$repo_root/scripts/run-local-docker-build.sh"
lock_file="$repo_root/locks/build-wr3000.lock"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-local-build.XXXXXXXX")"
fake_docker="$tmp_root/docker"
test_prefix="ci-local-build-${tmp_root##*.}"
sessions=(
  "$test_prefix-first"
  "$test_prefix-second"
  "$test_prefix-fail"
  "$test_prefix-checksum"
)
workspace="$test_prefix-workspace"
record_file="$tmp_root/docker-record.tsv"

cleanup() {
  rm -rf "$tmp_root"
  rm -rf "$repo_root/build/$workspace"
  rm -f "$repo_root/build/.openwrt-ft-locks/$workspace.lock"
  rmdir "$repo_root/build/.openwrt-ft-locks" 2>/dev/null || true
  rmdir "$repo_root/build" 2>/dev/null || true
}
trap cleanup EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

fake_docker_main() {
  local repo=''
  local session=''
  local workspace_id=''
  local builder_id=''
  local use_ccache=''
  local fresh=''
  local rebuild_packages=''
  local output_dir

  case "${1:-}" in
    buildx)
      return 1
      ;;
    image)
      [[ "${2:-}" == 'inspect' ]] || die "unexpected fake docker image command: $*"
      if [[ "${3:-}" == '--format' ]]; then
        printf 'sha256:fake-builder-image-id\n'
      fi
      return 0
      ;;
    run)
      shift
      while (($# > 0)); do
        case "$1" in
          -e)
            [[ $# -ge 2 ]] || die 'fake docker received an incomplete -e option'
            case "$2" in
              BUILD_ID=*) session="${2#BUILD_ID=}" ;;
              WORKSPACE_ID=*) workspace_id="${2#WORKSPACE_ID=}" ;;
              BUILDER_ID=*) builder_id="${2#BUILDER_ID=}" ;;
              USE_CCACHE=*) use_ccache="${2#USE_CCACHE=}" ;;
              FRESH=*) fresh="${2#FRESH=}" ;;
              REBUILD_PACKAGES=*) rebuild_packages="${2#REBUILD_PACKAGES=}" ;;
            esac
            shift 2
            ;;
          -v)
            [[ $# -ge 2 ]] || die 'fake docker received an incomplete -v option'
            case "$2" in
              *:/workspace) repo="${2%:/workspace}" ;;
            esac
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      ;;
    *)
      die "unexpected fake docker command: $*"
      ;;
  esac

  [[ -n "$repo" ]] || die 'fake docker did not receive the workspace mount'
  [[ -n "$session" ]] || die 'fake docker did not receive BUILD_ID'
  [[ -n "$workspace_id" ]] || die 'fake docker did not receive WORKSPACE_ID'
  [[ "$builder_id" == 'sha256:fake-builder-image-id' ]] ||
    die 'fake docker did not receive the inspected BUILDER_ID'

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$session" "$workspace_id" "$use_ccache" "$fresh" "$rebuild_packages" \
    >>"$FAKE_DOCKER_RECORD"

  output_dir="$repo/build/$workspace_id/output"
  mkdir -p "$output_dir"
  printf 'test firmware for %s\n' "$session" >"$output_dir/firmware.bin"

  if [[ "${FAKE_DOCKER_FAIL_RUN:-0}" == '1' ]]; then
    return 42
  fi

  (
    cd "$output_dir"
    if [[ "${FAKE_DOCKER_BAD_CHECKSUM:-0}" == '1' ]]; then
      printf '%064d  firmware.bin\n' 0 >sha256sums.txt
    else
      sha256sum firmware.bin >sha256sums.txt
    fi
  )
}

if [[ "$(basename -- "$0")" == 'docker' ]]; then
  fake_docker_main "$@"
  exit
fi

ln -s "$repo_root/scripts/ci/check-run-local-docker-build.sh" "$fake_docker"

run_wrapper() {
  local session="$1"
  local artifact_dir="$2"
  shift 2

  OPENWRT_DOCKER_BIN="$fake_docker" \
    FAKE_DOCKER_RECORD="$record_file" \
    "$wrapper" \
      --no-pull \
      --session "$session" \
      --workspace "$workspace" \
      --artifact-dir "$artifact_dir" \
      --cache-dir "$tmp_root/cache" \
      "$@" \
      "$lock_file"
}

first_session="${sessions[0]}"
first_artifacts="$tmp_root/artifacts-first"
run_wrapper "$first_session" "$first_artifacts"
[[ -f "$first_artifacts/firmware.bin" ]] ||
  die 'first build did not copy the artifact'
[[ -d "$repo_root/build/$workspace" ]] ||
  die 'successful reusable workspace was not retained'
grep -Fqx "$first_session"$'\t'"$workspace"$'\t''1'$'\t''0'$'\t' "$record_file" ||
  die 'default build did not propagate stable workspace, default ccache, and builder ID'

second_session="${sessions[1]}"
second_artifacts="$tmp_root/artifacts-second"
run_wrapper "$second_session" "$second_artifacts" \
  --fresh \
  --no-ccache \
  --rebuild-package mac80211 \
  --rebuild-package hostapd
[[ -f "$second_artifacts/firmware.bin" ]] ||
  die 'second build did not copy its timestamped artifact bundle'
[[ -f "$first_artifacts/firmware.bin" ]] ||
  die 'second build replaced the first session artifact bundle'
grep -Fqx "$second_session"$'\t'"$workspace"$'\t''0'$'\t''1'$'\t''mac80211,hostapd' "$record_file" ||
  die 'fresh, no-ccache, or repeated rebuild package selection was not propagated'

fail_session="${sessions[2]}"
fail_artifacts="$tmp_root/artifacts-fail"
if FAKE_DOCKER_FAIL_RUN=1 run_wrapper "$fail_session" "$fail_artifacts"; then
  die 'failed fake build unexpectedly succeeded'
fi
[[ -d "$repo_root/build/$workspace" ]] ||
  die 'failed build workspace was not retained'
[[ ! -e "$fail_artifacts" ]] ||
  die 'failed build unexpectedly copied artifacts'

checksum_session="${sessions[3]}"
checksum_artifacts="$tmp_root/artifacts-checksum"
if FAKE_DOCKER_BAD_CHECKSUM=1 \
  run_wrapper "$checksum_session" "$checksum_artifacts"; then
  die 'bad artifact checksum unexpectedly succeeded'
fi
[[ -d "$repo_root/build/$workspace" ]] ||
  die 'workspace with bad copied artifact checksum was not retained'

exec 9>>"$repo_root/build/.openwrt-ft-locks/$workspace.lock"
flock -n 9
if run_wrapper "$test_prefix-locked" "$tmp_root/artifacts-locked"; then
  die 'local wrapper accepted a concurrently locked workspace'
fi
flock -u 9
exec 9>&-

if run_wrapper "$test_prefix-removed" "$tmp_root/artifacts-removed" --keep-build-dir; then
  die 'removed --keep-build-dir flag unexpectedly succeeded'
fi
