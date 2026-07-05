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
  --artifact-dir DIR        Local artifact output. Default:
                            ./openwrt-artifacts/<session>.
  --builder-image REF       Prebuilt Docker builder image. Default matches
                            scripts/orchestrate-ec2-build.sh.
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
ARTIFACT_DIR=''
BUILDER_IMAGE='ghcr.io/andreacovelli/patch-fix-repo/openwrt-builder:ubuntu-noble-20260410-snapshot-20260410t000000z@sha256:dd52704e37949d9e815ddc762c422258e13d6783371b7eabcde759b02e85650f'
REBUILD_BUILDER_IMAGE='0'
IMAGE_TAG='patch-fix-openwrt-builder'
BUILDER_PLATFORM='linux/amd64'
BUILDER_BASE_IMAGE=''
UBUNTU_SNAPSHOT=''
MAKE_JOBS=''
DOWNLOAD_JOBS=''
STRICT_MANIFEST='1'
HOST_CACHE_DIR='cache'

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      [[ $# -ge 2 ]] || die "--session requires a value"
      SESSION_NAME="$2"
      shift 2
      ;;
    --artifact-dir)
      [[ $# -ge 2 ]] || die "--artifact-dir requires a value"
      ARTIFACT_DIR="$2"
      shift 2
      ;;
    --builder-image)
      [[ $# -ge 2 ]] || die "--builder-image requires a value"
      BUILDER_IMAGE="$2"
      shift 2
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
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a value"
      HOST_CACHE_DIR="$2"
      shift 2
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
case "$SESSION_NAME" in
  *[!A-Za-z0-9._-]*)
    die "session name contains unsupported characters: $SESSION_NAME"
    ;;
esac

case "$STRICT_MANIFEST" in
  0|1) ;;
  *) die "strict manifest value must be 0 or 1" ;;
esac

[[ -n "$BUILDER_PLATFORM" ]] || die "--platform must not be empty"
[[ -n "$BUILDER_IMAGE" ]] || die "--builder-image must not be empty"
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

require_cmd cp date docker mkdir rm

docker_build_cmd=(docker build)
if docker buildx version >/dev/null 2>&1; then
  docker_build_cmd=(docker buildx build --load)
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
    log "Pulling Docker builder image: $IMAGE_TAG"
    docker pull "$IMAGE_TAG"
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

docker_env=(-e CACHE_ROOT=/cache -e BUILD_ID="$SESSION_NAME" -e BUILDER_PLATFORM="$BUILDER_PLATFORM" -e STRICT_MANIFEST="$STRICT_MANIFEST")
if [[ -n "$MAKE_JOBS" ]]; then
  docker_env+=(-e MAKE_JOBS="$MAKE_JOBS")
fi
if [[ -n "$DOWNLOAD_JOBS" ]]; then
  docker_env+=(-e DOWNLOAD_JOBS="$DOWNLOAD_JOBS")
fi

log "Starting local container build for $LOCK_FILE_REL"
mkdir -p "$HOST_CACHE_DIR"
mapfile -d '' -t LOCK_PREBUILT_APKS < <(lock_prebuilt_apks)
if ((${#LOCK_PREBUILT_APKS[@]} > 0)); then
  log "Downloading pinned prebuilt APKs into local cache"
  (
    export PATH="$HOST_PATH"
    prebuilt_apk_download_all "$HOST_CACHE_DIR/dl" "${LOCK_PREBUILT_APKS[@]}"
  )
fi
docker run --rm \
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
cp -a "$REPO_ROOT/build/$SESSION_NAME/output/." "$ARTIFACT_DIR/"

log "Artifact directory: $ARTIFACT_DIR"
