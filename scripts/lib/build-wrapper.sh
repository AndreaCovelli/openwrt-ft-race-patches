#!/usr/bin/env bash

# Options, input checks, and artifact publishing shared by the container build
# wrappers: run-local-docker-build.sh, orchestrate-ec2-build.sh, and
# run-ec2-build.sh. Functions return 1 after printing an error, so callers
# decide whether to exit.

BUILD_WRAPPER_DEFAULT_IMAGE_TAG='patch-fix-openwrt-builder'

build_wrapper_die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

# Reset the builder options every wrapper accepts. An empty BUILDER_IMAGE
# selects DEFAULT_BUILDER_IMAGE where the image is used.
# shellcheck disable=SC2034 # The wrappers read these after parsing.
build_wrapper_option_defaults() {
  SESSION_NAME=''
  BUILD_METHOD=''
  BUILDER_IMAGE=''
  REBUILD_BUILDER_IMAGE='0'
  IMAGE_TAG="$BUILD_WRAPPER_DEFAULT_IMAGE_TAG"
  BUILDER_PLATFORM='linux/amd64'
  BUILDER_BASE_IMAGE=''
  UBUNTU_SNAPSHOT=''
  MAKE_JOBS=''
  DOWNLOAD_JOBS=''
  STRICT_MANIFEST='1'
}

# Consume one shared builder option from the start of "$@". Sets
# BUILD_WRAPPER_SHIFT to the number of arguments used, or to 0 when $1 is not
# a shared option.
# shellcheck disable=SC2034 # The wrappers read these after parsing.
build_wrapper_take_option() {
  BUILD_WRAPPER_SHIFT=0

  case "$1" in
    --session|--build-method|--builder-image|--image-tag|--platform|\
    --builder-base-image|--ubuntu-snapshot|--make-jobs|--download-jobs)
      [[ $# -ge 2 ]] || build_wrapper_die "$1 requires a value" || return 1
      BUILD_WRAPPER_SHIFT=2
      ;;
    --rebuild-builder-image|--strict-manifest|--no-strict-manifest)
      BUILD_WRAPPER_SHIFT=1
      ;;
    *)
      return 0
      ;;
  esac

  case "$1" in
    --session) SESSION_NAME="$2" ;;
    --build-method)
      case "$2" in
        source|imagebuilder) BUILD_METHOD="$2" ;;
        *) build_wrapper_die '--build-method must be source or imagebuilder' || return 1 ;;
      esac
      ;;
    --builder-image)
      [[ -n "$2" ]] || build_wrapper_die '--builder-image must not be empty' || return 1
      BUILDER_IMAGE="$2"
      ;;
    --image-tag) IMAGE_TAG="$2" ;;
    --platform)
      [[ -n "$2" ]] || build_wrapper_die '--platform must not be empty' || return 1
      BUILDER_PLATFORM="$2"
      ;;
    --builder-base-image) BUILDER_BASE_IMAGE="$2" ;;
    --ubuntu-snapshot) UBUNTU_SNAPSHOT="$2" ;;
    --make-jobs) MAKE_JOBS="$2" ;;
    --download-jobs) DOWNLOAD_JOBS="$2" ;;
    --rebuild-builder-image) REBUILD_BUILDER_IMAGE='1' ;;
    --strict-manifest) STRICT_MANIFEST='1' ;;
    --no-strict-manifest) STRICT_MANIFEST='0' ;;
  esac
}

# Append the shared builder options to the array named by $1, for passing on
# to another wrapper. The platform and manifest mode are always explicit;
# other options only when set. SESSION_NAME is left to the caller.
build_wrapper_option_args() {
  local -n out_args="$1"

  out_args+=(--platform "$BUILDER_PLATFORM")
  if [[ "$STRICT_MANIFEST" == '1' ]]; then
    out_args+=(--strict-manifest)
  else
    out_args+=(--no-strict-manifest)
  fi
  if [[ -n "$BUILD_METHOD" ]]; then
    out_args+=(--build-method "$BUILD_METHOD")
  fi
  if [[ -n "$BUILDER_IMAGE" ]]; then
    out_args+=(--builder-image "$BUILDER_IMAGE")
  fi
  if [[ "$REBUILD_BUILDER_IMAGE" == '1' ]]; then
    out_args+=(--rebuild-builder-image)
  fi
  if [[ "$IMAGE_TAG" != "$BUILD_WRAPPER_DEFAULT_IMAGE_TAG" ]]; then
    out_args+=(--image-tag "$IMAGE_TAG")
  fi
  if [[ -n "$BUILDER_BASE_IMAGE" ]]; then
    out_args+=(--builder-base-image "$BUILDER_BASE_IMAGE")
  fi
  if [[ -n "$UBUNTU_SNAPSHOT" ]]; then
    out_args+=(--ubuntu-snapshot "$UBUNTU_SNAPSHOT")
  fi
  if [[ -n "$MAKE_JOBS" ]]; then
    out_args+=(--make-jobs "$MAKE_JOBS")
  fi
  if [[ -n "$DOWNLOAD_JOBS" ]]; then
    out_args+=(--download-jobs "$DOWNLOAD_JOBS")
  fi
}

# Resolve lock path $2 against repo root $1 and require a file inside the
# repo. Sets the variables named by $3 and $4 to its absolute and
# repo-relative paths.
# shellcheck disable=SC2034 # The namerefs set the caller's variables.
build_wrapper_resolve_lock() {
  local repo_root="$1"
  local path="$2"
  local -n out_lock="$3"
  local -n out_lock_rel="$4"

  if [[ "$path" != /* ]]; then
    path="$repo_root/$path"
  fi
  [[ -f "$path" ]] || build_wrapper_die "lock file not found: $path" || return 1
  case "$path" in
    "$repo_root"/*) ;;
    *) build_wrapper_die "lock file must live inside the repo: $path" || return 1 ;;
  esac
  out_lock="$path"
  out_lock_rel="${path#"$repo_root"/}"
}

# Require name $2, described by $1, to be usable as one path component.
build_wrapper_check_name() {
  local kind="$1"
  local name="$2"

  case "$name" in
    *[!A-Za-z0-9._-]*)
      build_wrapper_die "$kind name contains unsupported characters: $name" || return 1
      ;;
    ''|.|..)
      build_wrapper_die "unsupported $kind name: '$name'" || return 1
      ;;
  esac
}

# Create an empty staging directory beside artifact destination $1, so
# publishing is a rename within one filesystem. Prints its path.
build_wrapper_create_staging() {
  local parent

  parent="$(dirname -- "$1")"
  mkdir -p -- "$parent" || return 1
  mktemp -d "$parent/.openwrt-ft-artifacts.XXXXXXXX"
}

# Check copied build output in directory $1 against its sha256sums.txt.
build_wrapper_verify_artifacts() {
  local dir="$1"

  [[ -f "$dir/sha256sums.txt" ]] ||
    build_wrapper_die "artifact checksum file not found in build output: $dir" ||
    return 1
  (
    cd "$dir" || exit 1
    sha256sum -c sha256sums.txt
  )
}

# Move staging directory $1 to the new artifact destination $2. -T prevents
# nesting into an existing directory, and --no-clobber also protects a
# destination created while the build was running. A skipped move exits
# zero, so the surviving staging directory is what reports it.
build_wrapper_publish_artifacts() {
  local staging="$1"
  local dest="$2"

  mv -T --no-clobber -- "$staging" "$dest" || return 1
  [[ ! -d "$staging" ]] ||
    build_wrapper_die "artifact destination appeared during the build: $dest" ||
    return 1
}
