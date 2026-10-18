#!/usr/bin/env bash
set -euo pipefail

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
  local build_method=''
  local workspace_path=''
  local workspace_mount=''
  local user=''
  local output_dir

  case "${1:-}" in
    buildx)
      return 1
      ;;
    pull)
      printf '%s\n' "${2:-}" >>"$FAKE_DOCKER_PULLS"
      return 0
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
              BUILD_METHOD=*) build_method="${2#BUILD_METHOD=}" ;;
              WORKSPACE_PATH=*) workspace_path="${2#WORKSPACE_PATH=}" ;;
            esac
            shift 2
            ;;
          --user)
            [[ $# -ge 2 ]] || die 'fake docker received an incomplete --user option'
            user="$2"
            shift 2
            ;;
          -v)
            [[ $# -ge 2 ]] || die 'fake docker received an incomplete -v option'
            case "$2" in
              *:/workspace) repo="${2%:/workspace}" ;;
              *:/build) workspace_mount="${2%:/build}" ;;
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
  [[ "$user" == "$(id -u):$(id -g)" ]] ||
    die "fake docker did not run as the invoking user: $user"
  [[ "$workspace_path" == '/build' ]] ||
    die "fake docker did not receive WORKSPACE_PATH=/build: $workspace_path"
  [[ "$workspace_mount" == "$repo/build/$workspace_id" && -d "$workspace_mount" ]] ||
    die "fake docker did not receive the created workspace at /build: $workspace_mount"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session" "$workspace_id" "$use_ccache" "$fresh" "$rebuild_packages" "$build_method" \
    >>"$FAKE_DOCKER_RECORD"

  output_dir="$workspace_mount/output"
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
  if [[ -n "${FAKE_DOCKER_COLLISION_DIR:-}" ]]; then
    mkdir -p "$FAKE_DOCKER_COLLISION_DIR"
    printf 'preserve me\n' >"$FAKE_DOCKER_COLLISION_DIR/sentinel"
  fi
}

if [[ "$(basename -- "$0")" == 'docker' ]]; then
  fake_docker_main "$@"
  exit
fi

source_repo="$(git rev-parse --show-toplevel)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-local-build.XXXXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
# Unsafe destination tests must never point the wrapper at the real checkout.
repo_root="$tmp_root/repo"
mkdir -p "$repo_root/scripts/lib" "$repo_root/locks"
cp "$source_repo/scripts/run-local-docker-build.sh" "$repo_root/scripts/"
cp "$source_repo/scripts/lib/"{build-name,builder-image,prebuilt-apks}.sh "$repo_root/scripts/lib/"
cp "$source_repo/locks/build-wr3000.lock" "$repo_root/locks/"
wrapper="$repo_root/scripts/run-local-docker-build.sh"
lock_file="$repo_root/locks/build-wr3000.lock"
fake_docker="$tmp_root/docker"
test_prefix='ci-local-build'
sessions=("$test_prefix-first" "$test_prefix-second" "$test_prefix-fail" "$test_prefix-checksum")
workspace="$test_prefix-workspace"
record_file="$tmp_root/docker-record.tsv"
pull_record="$tmp_root/docker-pulls.txt"
ln -s "$source_repo/scripts/ci/check-run-local-docker-build.sh" "$fake_docker"

run_wrapper() {
  local session="$1"
  local artifact_dir="$2"
  shift 2

  OPENWRT_DOCKER_BIN="$fake_docker" \
    FAKE_DOCKER_RECORD="$record_file" \
    FAKE_DOCKER_PULLS="$pull_record" \
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
grep -Fqx "$first_session"$'\t'"$workspace"$'\t''1'$'\t''0'$'\t'$'\t''imagebuilder' "$record_file" ||
  die 'default build did not propagate stable workspace, default ccache, lock build method, and builder ID'

second_session="${sessions[1]}"
second_artifacts="$tmp_root/artifacts-second"
run_wrapper "$second_session" "$second_artifacts" \
  --build-method source \
  --fresh \
  --no-ccache \
  --rebuild-package mac80211 \
  --rebuild-package local-feeds
[[ -f "$second_artifacts/firmware.bin" ]] ||
  die 'second build did not copy its timestamped artifact bundle'
[[ -f "$first_artifacts/firmware.bin" ]] ||
  die 'second build replaced the first session artifact bundle'
grep -Fqx "$second_session"$'\t'"$workspace"$'\t''0'$'\t''1'$'\t''mac80211,local-feeds'$'\t''source' "$record_file" ||
  die 'build method, fresh, no-ccache, or repeated rebuild package selection was not propagated'

record_before="$(sha256sum "$record_file")"
if run_wrapper "$test_prefix-ib-local-feeds" "$tmp_root/artifacts-ib-local-feeds" \
  --rebuild-package local-feeds >"$tmp_root/ib-local-feeds.log" 2>&1; then
  die 'ImageBuilder build accepted a local-feeds rebuild'
fi
[[ "$(sha256sum "$record_file")" == "$record_before" ]] ||
  die 'rejected ImageBuilder local-feeds rebuild started a container build'

# Default workspaces are per build method.
OPENWRT_DOCKER_BIN="$fake_docker" FAKE_DOCKER_RECORD="$record_file" \
  FAKE_DOCKER_PULLS="$pull_record" \
  "$wrapper" --no-pull --session "$test_prefix-default-source" \
    --build-method source \
    --artifact-dir "$tmp_root/artifacts-default-source" --cache-dir "$tmp_root/cache" \
    "$lock_file"
grep -Fq "$test_prefix-default-source"$'\t''openwrt-ft-cudy_wr3000-v1-dev'$'\t' "$record_file" ||
  die 'source build did not use the -dev default workspace'
OPENWRT_DOCKER_BIN="$fake_docker" FAKE_DOCKER_RECORD="$record_file" \
  FAKE_DOCKER_PULLS="$pull_record" \
  "$wrapper" --no-pull --session "$test_prefix-default-ib" \
    --artifact-dir "$tmp_root/artifacts-default-ib" --cache-dir "$tmp_root/cache" \
    "$lock_file"
grep -Fq "$test_prefix-default-ib"$'\t''openwrt-ft-cudy_wr3000-v1-ib'$'\t' "$record_file" ||
  die 'ImageBuilder build did not use the -ib default workspace'

# The wrapper always appends --no-pull; call it directly to exercise pulls.
OPENWRT_DOCKER_BIN="$fake_docker" FAKE_DOCKER_RECORD="$record_file" \
  FAKE_DOCKER_PULLS="$pull_record" \
  "$wrapper" --session "$test_prefix-pinned" --workspace "$workspace" \
    --artifact-dir "$tmp_root/artifacts-pinned" --cache-dir "$tmp_root/cache" \
    "$lock_file"
[[ ! -e "$pull_record" ]] ||
  die 'locally present digest-pinned builder image was pulled again'
OPENWRT_DOCKER_BIN="$fake_docker" FAKE_DOCKER_RECORD="$record_file" \
  FAKE_DOCKER_PULLS="$pull_record" \
  "$wrapper" --session "$test_prefix-tagged" --workspace "$workspace" \
    --artifact-dir "$tmp_root/artifacts-tagged" --cache-dir "$tmp_root/cache" \
    --builder-image example.invalid/builder:latest \
    "$lock_file"
grep -Fqx 'example.invalid/builder:latest' "$pull_record" ||
  die 'tag-only builder image was not pulled'

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
[[ ! -e "$checksum_artifacts" ]] || die 'bad checksums published an artifact bundle'
if compgen -G "$tmp_root/.openwrt-ft-artifacts.*" >/dev/null; then
  die 'failed checksum verification leaked artifact staging directories'
fi

mkdir -p "$tmp_root/empty-destination"
printf 'preserve me\n' >"$repo_root/sentinel"
ln -s "$tmp_root/nonexistent-target" "$tmp_root/dangling-link"
ln -s "$repo_root" "$tmp_root/repo-link"
record_before="$(sha256sum "$record_file")"
for destination in . "$repo_root/.." "$tmp_root/empty-destination" \
  "$first_artifacts" "$repo_root/sentinel" "$tmp_root/dangling-link" \
  "$tmp_root/repo-link" "$tmp_root/repo-link/new/../.." \
  "$repo_root/build/$workspace/nested-output" "$tmp_root/cache/nested-output"; do
  if run_wrapper "$test_prefix-unsafe" "$destination" >"$tmp_root/unsafe.log" 2>&1; then
    die "unsafe or existing artifact destination was accepted: $destination"
  fi
  [[ "$(sha256sum "$record_file")" == "$record_before" ]] ||
    die 'rejected artifact destination started a container build'
done
[[ -f "$repo_root/sentinel" && -d "$tmp_root/empty-destination" && -L "$tmp_root/dangling-link" ]] ||
  die 'destination checks removed existing files, directories, or symlinks'
[[ -f "$first_artifacts/firmware.bin" ]] || die 'destination checks removed an earlier bundle'

late_artifacts="$tmp_root/artifacts-collision"
if FAKE_DOCKER_COLLISION_DIR="$late_artifacts" \
  run_wrapper "$test_prefix-collision" "$late_artifacts" >"$tmp_root/collision.log" 2>&1; then
  die 'destination created during the build was overwritten'
fi
[[ "$(cat "$late_artifacts/sentinel")" == 'preserve me' && ! -e "$late_artifacts/firmware.bin" ]] ||
  die 'late destination collision damaged existing output'
if compgen -G "$tmp_root/.openwrt-ft-artifacts.*" >/dev/null; then
  die 'late destination collision leaked artifact staging directories'
fi

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
