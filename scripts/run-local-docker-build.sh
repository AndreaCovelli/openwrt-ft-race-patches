#!/usr/bin/env bash
set -euo pipefail

umask 022
HOST_PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/build-name.sh
source "$SCRIPT_DIR/lib/build-name.sh"
# shellcheck source=scripts/lib/prebuilt-apks.sh
source "$SCRIPT_DIR/lib/prebuilt-apks.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-local-docker-build.sh [options] <lock-file>

Options:
  --session NAME            Build/session name. Default:
                            openwrt-ft-<device-id>-<openwrt-version>-<variant>-<utc>.
  --workspace NAME          Reusable build workspace. Default:
                            build/openwrt-ft-<device-id>-dev.
  --artifact-dir DIR        Local artifact output. Default:
                            ./openwrt-artifacts/<session>.
  --fresh                   Replace the exact workspace and run a full build.
  --rebuild-package NAME    Force an incremental package rebuild. Repeatable;
                            NAME is mac80211, hostapd, or all.
  --builder-image REF       Prebuilt Docker builder image. Default matches
                            scripts/orchestrate-ec2-build.sh.
  --no-pull                 Use --builder-image as a local image without
                            pulling. Useful for locally rebuilt tags.
  --rebuild-builder-image   Build docker/Dockerfile.ec2 locally instead of
                            pulling the prebuilt builder image.
  --image-tag TAG           Local Docker image tag used with
                            --rebuild-builder-image. Default:
                            patch-fix-openwrt-builder
  --platform PLATFORM       Docker build/run platform. Default: linux/amd64.
  --builder-base-image REF  Docker base image override for Dockerfile.ec2.
  --ubuntu-snapshot TS      Ubuntu apt snapshot timestamp.
  --make-jobs N             Export MAKE_JOBS into the container build.
  --download-jobs N         Export DOWNLOAD_JOBS into the container build.
  --strict-manifest         Fail if built package manifest drifts. Default.
  --no-strict-manifest      Report package drift without failing the build.
  --ccache                  Enable OpenWrt ccache using /cache/ccache. Default.
  --no-ccache               Disable OpenWrt ccache.
  --ccache-maxsize SIZE     Max ccache size when enabled. Default: 20G.
  --cache-dir DIR           Host cache directory mounted at /cache. Default:
                            ./cache.
  --help                    Show this message.
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

lock_prebuilt_apks() {
  (
    unset PREBUILT_APKS
    # shellcheck source=/dev/null
    source "$LOCK_FILE"
    if declare -p PREBUILT_APKS >/dev/null 2>&1; then
      local -n prebuilt_apks=PREBUILT_APKS
      printf '%s\0' "${prebuilt_apks[@]}"
    fi
  )
}

abs_repo_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$path"
  fi
}

SESSION_NAME=''
WORKSPACE_NAME=''
ARTIFACT_DIR=''
BUILDER_IMAGE='ghcr.io/andreacovelli/openwrt-ft-race-patches/openwrt-builder:ubuntu-noble-20260410-snapshot-20260410t000000z@sha256:dd52704e37949d9e815ddc762c422258e13d6783371b7eabcde759b02e85650f'
REBUILD_BUILDER_IMAGE='0'
PULL_BUILDER_IMAGE='1'
IMAGE_TAG='patch-fix-openwrt-builder'
BUILDER_PLATFORM='linux/amd64'
BUILDER_BASE_IMAGE=''
UBUNTU_SNAPSHOT=''
MAKE_JOBS=''
DOWNLOAD_JOBS=''
STRICT_MANIFEST='1'
HOST_CACHE_DIR='cache'
USE_CCACHE='1'
CCACHE_MAXSIZE='20G'
FRESH='0'
REBUILD_PACKAGES=()
OPENWRT_DOCKER_BIN="${OPENWRT_DOCKER_BIN:-docker}"

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      [[ $# -ge 2 ]] || die "--session requires a value"
      SESSION_NAME="$2"
      shift 2
      ;;
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace requires a value"
      WORKSPACE_NAME="$2"
      shift 2
      ;;
    --artifact-dir)
      [[ $# -ge 2 ]] || die "--artifact-dir requires a value"
      ARTIFACT_DIR="$2"
      shift 2
      ;;
    --fresh)
      FRESH='1'
      shift
      ;;
    --rebuild-package)
      [[ $# -ge 2 ]] || die "--rebuild-package requires a value"
      case "$2" in
        mac80211|hostapd|all) ;;
        *) die "--rebuild-package must be mac80211, hostapd, or all" ;;
      esac
      REBUILD_PACKAGES+=("$2")
      shift 2
      ;;
    --builder-image)
      [[ $# -ge 2 ]] || die "--builder-image requires a value"
      BUILDER_IMAGE="$2"
      shift 2
      ;;
    --no-pull)
      PULL_BUILDER_IMAGE='0'
      shift
      ;;
    --rebuild-builder-image)
      REBUILD_BUILDER_IMAGE='1'
      shift
      ;;
    --image-tag)
      [[ $# -ge 2 ]] || die "--image-tag requires a value"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --platform)
      [[ $# -ge 2 ]] || die "--platform requires a value"
      BUILDER_PLATFORM="$2"
      shift 2
      ;;
    --builder-base-image)
      [[ $# -ge 2 ]] || die "--builder-base-image requires a value"
      BUILDER_BASE_IMAGE="$2"
      shift 2
      ;;
    --ubuntu-snapshot)
      [[ $# -ge 2 ]] || die "--ubuntu-snapshot requires a value"
      UBUNTU_SNAPSHOT="$2"
      shift 2
      ;;
    --make-jobs)
      [[ $# -ge 2 ]] || die "--make-jobs requires a value"
      MAKE_JOBS="$2"
      shift 2
      ;;
    --download-jobs)
      [[ $# -ge 2 ]] || die "--download-jobs requires a value"
      DOWNLOAD_JOBS="$2"
      shift 2
      ;;
    --strict-manifest)
      STRICT_MANIFEST='1'
      shift
      ;;
    --no-strict-manifest)
      STRICT_MANIFEST='0'
      shift
      ;;
    --ccache)
      USE_CCACHE='1'
      shift
      ;;
    --no-ccache)
      USE_CCACHE='0'
      shift
      ;;
    --ccache-maxsize)
      [[ $# -ge 2 ]] || die "--ccache-maxsize requires a value"
      CCACHE_MAXSIZE="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a value"
      HOST_CACHE_DIR="$2"
      shift 2
      ;;
    --keep-build-dir)
      die '--keep-build-dir was removed; reusable workspaces are retained by default'
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

[[ ${#POSITIONAL[@]} -eq 1 ]] || {
  usage >&2
  exit 1
}

LOCK_FILE="$(abs_repo_path "${POSITIONAL[0]}")"
[[ -f "$LOCK_FILE" ]] || die "lock file not found: $LOCK_FILE"
case "$LOCK_FILE" in
  "$REPO_ROOT"/*) ;;
  *) die "lock file must live inside the repo: $LOCK_FILE" ;;
esac
LOCK_FILE_REL="${LOCK_FILE#"$REPO_ROOT"/}"

if [[ -z "$SESSION_NAME" ]]; then
  SESSION_NAME="$(openwrt_default_build_name_from_lock "$LOCK_FILE")"
fi
if [[ -z "$WORKSPACE_NAME" ]]; then
  WORKSPACE_NAME="$(openwrt_default_workspace_name_from_lock "$LOCK_FILE")"
fi
case "$SESSION_NAME" in
  *[!A-Za-z0-9._-]*)
    die "session name contains unsupported characters: $SESSION_NAME"
    ;;
  .|..)
    die "unsupported session name: $SESSION_NAME"
    ;;
esac
case "$WORKSPACE_NAME" in
  *[!A-Za-z0-9._-]*|.|..)
    die "workspace name contains unsupported characters: $WORKSPACE_NAME"
    ;;
esac
[[ -n "$WORKSPACE_NAME" ]] || die 'workspace name must not be empty'

case "$STRICT_MANIFEST" in
  0|1) ;;
  *) die "strict manifest value must be 0 or 1" ;;
esac
case "$USE_CCACHE" in
  0|1) ;;
  *) die "ccache value must be 0 or 1" ;;
esac
case "$FRESH" in
  0|1) ;;
  *) die "fresh value must be 0 or 1" ;;
esac

[[ -n "$BUILDER_PLATFORM" ]] || die "--platform must not be empty"
[[ -n "$BUILDER_IMAGE" ]] || die "--builder-image must not be empty"
[[ -n "$OPENWRT_DOCKER_BIN" ]] || die "OPENWRT_DOCKER_BIN must not be empty"
case "$REBUILD_BUILDER_IMAGE" in
  0|1) ;;
  *) die "rebuild builder image value must be 0 or 1" ;;
esac

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="$REPO_ROOT/openwrt-artifacts/$SESSION_NAME"
elif [[ "$ARTIFACT_DIR" != /* ]]; then
  ARTIFACT_DIR="$REPO_ROOT/$ARTIFACT_DIR"
fi
if [[ "$HOST_CACHE_DIR" != /* ]]; then
  HOST_CACHE_DIR="$REPO_ROOT/$HOST_CACHE_DIR"
fi
WORKSPACE_DIR="$REPO_ROOT/build/$WORKSPACE_NAME"

require_cmd cp date flock "$OPENWRT_DOCKER_BIN" mkdir realpath rm sha256sum

[[ ! -L "$WORKSPACE_DIR" ]] ||
  die "workspace must not be a symbolic link: $WORKSPACE_DIR"
ARTIFACT_DIR="$(realpath -m -- "$ARTIFACT_DIR")"
HOST_CACHE_DIR="$(realpath -m -- "$HOST_CACHE_DIR")"
WORKSPACE_DIR="$(realpath -m -- "$WORKSPACE_DIR")"

case "$ARTIFACT_DIR" in
  "$WORKSPACE_DIR"|"$WORKSPACE_DIR"/*)
    die "artifact directory must be outside the build workspace: $ARTIFACT_DIR"
    ;;
esac
case "$HOST_CACHE_DIR" in
  "$WORKSPACE_DIR"|"$WORKSPACE_DIR"/*)
    die "cache directory must be outside the build workspace: $HOST_CACHE_DIR"
    ;;
esac

WORKSPACE_LOCK_DIR="$REPO_ROOT/build/.openwrt-ft-locks"
[[ ! -L "$WORKSPACE_LOCK_DIR" ]] ||
  die "workspace lock directory must not be a symbolic link: $WORKSPACE_LOCK_DIR"
mkdir -p "$WORKSPACE_LOCK_DIR"
WORKSPACE_LOCK_FILE="$WORKSPACE_LOCK_DIR/$WORKSPACE_NAME.lock"
[[ ! -L "$WORKSPACE_LOCK_FILE" ]] ||
  die "workspace lock file must not be a symbolic link: $WORKSPACE_LOCK_FILE"
exec {WORKSPACE_LOCK_FD}>>"$WORKSPACE_LOCK_FILE"
flock -n "$WORKSPACE_LOCK_FD" ||
  die "workspace is already locked by another build: $WORKSPACE_NAME"

docker_build_cmd=("$OPENWRT_DOCKER_BIN" build)
if "$OPENWRT_DOCKER_BIN" buildx version >/dev/null 2>&1; then
  docker_build_cmd=("$OPENWRT_DOCKER_BIN" buildx build --load)
fi

docker_platform_args=()
if [[ -n "$BUILDER_PLATFORM" ]]; then
  docker_platform_args+=(--platform "$BUILDER_PLATFORM")
fi

docker_build_args=()
if [[ -n "$BUILDER_BASE_IMAGE" ]]; then
  docker_build_args+=(--build-arg "BUILDER_BASE_IMAGE=$BUILDER_BASE_IMAGE")
fi
if [[ -n "$UBUNTU_SNAPSHOT" ]]; then
  docker_build_args+=(--build-arg "UBUNTU_SNAPSHOT=$UBUNTU_SNAPSHOT")
fi

case "$REBUILD_BUILDER_IMAGE" in
  0)
    IMAGE_TAG="$BUILDER_IMAGE"
    if [[ "$PULL_BUILDER_IMAGE" == '1' ]]; then
      log "Pulling Docker builder image: $IMAGE_TAG"
      "$OPENWRT_DOCKER_BIN" pull "$IMAGE_TAG"
    else
      log "Using local Docker builder image without pull: $IMAGE_TAG"
      "$OPENWRT_DOCKER_BIN" image inspect "$IMAGE_TAG" >/dev/null
    fi
    ;;
  1)
    log "Building Docker builder image: $IMAGE_TAG"
    (
      cd "$REPO_ROOT"
      "${docker_build_cmd[@]}" \
        "${docker_platform_args[@]}" \
        "${docker_build_args[@]}" \
        -f docker/Dockerfile.ec2 \
        -t "$IMAGE_TAG" \
        .
    )
    ;;
esac

BUILDER_ID="$("$OPENWRT_DOCKER_BIN" image inspect --format '{{.Id}}' "$IMAGE_TAG")"
[[ -n "$BUILDER_ID" ]] || die "failed to inspect builder image ID: $IMAGE_TAG"

if ((${#REBUILD_PACKAGES[@]} == 0)); then
  rebuild_packages_value=''
else
  rebuild_packages_value="$(IFS=,; printf '%s' "${REBUILD_PACKAGES[*]}")"
fi
docker_env=(
  -e CACHE_ROOT=/cache
  -e BUILD_ID="$SESSION_NAME"
  -e WORKSPACE_ID="$WORKSPACE_NAME"
  -e BUILDER_ID="$BUILDER_ID"
  -e BUILDER_PLATFORM="$BUILDER_PLATFORM"
  -e STRICT_MANIFEST="$STRICT_MANIFEST"
  -e USE_CCACHE="$USE_CCACHE"
  -e FRESH="$FRESH"
  -e REBUILD_PACKAGES="$rebuild_packages_value"
  -e OPENWRT_WORKSPACE_LOCK_HELD=1
)
if [[ -n "$MAKE_JOBS" ]]; then
  docker_env+=(-e MAKE_JOBS="$MAKE_JOBS")
fi
if [[ -n "$DOWNLOAD_JOBS" ]]; then
  docker_env+=(-e DOWNLOAD_JOBS="$DOWNLOAD_JOBS")
fi
if [[ "$USE_CCACHE" == '1' ]]; then
  docker_env+=(-e CCACHE_DIR=/cache/ccache -e CCACHE_MAXSIZE="$CCACHE_MAXSIZE")
fi

log "Starting local container build for $LOCK_FILE_REL"
log "Workspace: build/$WORKSPACE_NAME"
mkdir -p "$HOST_CACHE_DIR"
if [[ "$USE_CCACHE" == '1' ]]; then
  mkdir -p "$HOST_CACHE_DIR/ccache"
fi
mapfile -d '' -t LOCK_PREBUILT_APKS < <(lock_prebuilt_apks)
if ((${#LOCK_PREBUILT_APKS[@]} > 0)); then
  log "Downloading pinned prebuilt APKs into local cache"
  (
    export PATH="$HOST_PATH"
    prebuilt_apk_download_all "$HOST_CACHE_DIR/dl" "${LOCK_PREBUILT_APKS[@]}"
  )
fi
"$OPENWRT_DOCKER_BIN" run --rm \
  "${docker_platform_args[@]}" \
  "${docker_env[@]}" \
  -v "$REPO_ROOT:/workspace" \
  -v "$HOST_CACHE_DIR:/cache" \
  -w /workspace \
  "$IMAGE_TAG" \
  ./scripts/build-image.sh "$LOCK_FILE_REL"

log "Copying build output to $ARTIFACT_DIR"
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
cp -a "$WORKSPACE_DIR/output/." "$ARTIFACT_DIR/"

[[ -f "$ARTIFACT_DIR/sha256sums.txt" ]] ||
  die "artifact checksum file not found: $ARTIFACT_DIR/sha256sums.txt"
log "Verifying copied artifact checksums"
(
  cd "$ARTIFACT_DIR"
  sha256sum -c sha256sums.txt
)
log "Artifact directory: $ARTIFACT_DIR"
log "Build workspace retained: $WORKSPACE_DIR"
