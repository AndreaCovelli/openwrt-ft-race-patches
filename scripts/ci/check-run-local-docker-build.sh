#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
wrapper="$repo_root/scripts/run-local-docker-build.sh"
lock_file="$repo_root/locks/build-wr3000.lock"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-local-build.XXXXXXXX")"
fake_docker="$tmp_root/docker"
test_prefix="ci-local-build-${tmp_root##*.}"
sessions=(
  "$test_prefix-clean"
  "$test_prefix-keep"
  "$test_prefix-fail"
  "$test_prefix-checksum"
)

cleanup() {
  local session

  rm -rf "$tmp_root"
  for session in "${sessions[@]}"; do
    rm -rf "$repo_root/build/$session"
  done
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
  local output_dir

  case "${1:-}" in
    buildx)
      return 1
      ;;
    image)
      [[ "${2:-}" == 'inspect' ]] || die "unexpected fake docker image command: $*"
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

  output_dir="$repo/build/$session/output"
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
    "$wrapper" \
      --no-pull \
      --session "$session" \
      --artifact-dir "$artifact_dir" \
      --cache-dir "$tmp_root/cache" \
      "$@" \
      "$lock_file"
}

clean_session="${sessions[0]}"
clean_artifacts="$tmp_root/artifacts-clean"
run_wrapper "$clean_session" "$clean_artifacts"
[[ -f "$clean_artifacts/firmware.bin" ]] ||
  die 'default cleanup test did not copy the artifact'
[[ ! -e "$repo_root/build/$clean_session" ]] ||
  die 'successful build workspace was not removed by default'

keep_session="${sessions[1]}"
keep_artifacts="$tmp_root/artifacts-keep"
run_wrapper "$keep_session" "$keep_artifacts" --keep-build-dir
[[ -f "$keep_artifacts/firmware.bin" ]] ||
  die '--keep-build-dir test did not copy the artifact'
[[ -d "$repo_root/build/$keep_session" ]] ||
  die '--keep-build-dir did not retain the successful workspace'

fail_session="${sessions[2]}"
fail_artifacts="$tmp_root/artifacts-fail"
if FAKE_DOCKER_FAIL_RUN=1 run_wrapper "$fail_session" "$fail_artifacts"; then
  die 'failed fake build unexpectedly succeeded'
fi
[[ -d "$repo_root/build/$fail_session" ]] ||
  die 'failed build workspace was not retained'
[[ ! -e "$fail_artifacts" ]] ||
  die 'failed build unexpectedly copied artifacts'

checksum_session="${sessions[3]}"
checksum_artifacts="$tmp_root/artifacts-checksum"
if FAKE_DOCKER_BAD_CHECKSUM=1 \
  run_wrapper "$checksum_session" "$checksum_artifacts"; then
  die 'bad artifact checksum unexpectedly succeeded'
fi
[[ -d "$repo_root/build/$checksum_session" ]] ||
  die 'workspace with bad copied artifact checksum was not retained'
