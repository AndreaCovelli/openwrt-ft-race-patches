#!/usr/bin/env bash
set -euo pipefail

umask 022
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
  ./scripts/orchestrate-ec2-build.sh [options] <ssh-target> <lock-file>

Options:
  --remote-root PATH        Remote workspace root. Default: ~/openwrt-ft-builds
  --session NAME            tmux session and build id. Default:
                            openwrt-ft-<device-id>-<openwrt-version>-<variant>-<utc>
  --builder-image REF       Prebuilt Docker builder image. Default:
                            ghcr.io/andreacovelli/patch-fix-repo/openwrt-builder:ubuntu-noble-20260410-snapshot-20260410t000000z@sha256:dd52704e37949d9e815ddc762c422258e13d6783371b7eabcde759b02e85650f
                            Private GHCR images need GHCR_TOKEN set locally so
                            the remote host can authenticate before pulling.
                            GHCR_USERNAME is optional when GITHUB_ACTOR or an
                            authenticated gh CLI account is available locally.
  --rebuild-builder-image   Build docker/Dockerfile.ec2 on the remote host
                            instead of pulling the prebuilt builder image.
  --image-tag TAG           Remote Docker image tag used with
                            --rebuild-builder-image. Default:
                            patch-fix-openwrt-builder
  --platform PLATFORM       Docker build/run platform. Default: linux/amd64
  --builder-base-image REF  Docker base image override for Dockerfile.ec2.
  --ubuntu-snapshot TS      Ubuntu apt snapshot timestamp. Default comes from Dockerfile.ec2.
  --make-jobs N             Export MAKE_JOBS into the container build.
  --download-jobs N         Export DOWNLOAD_JOBS into the container build.
  --strict-manifest         Fail if built package manifest drifts. Default behavior.
  --no-strict-manifest      Report package drift without failing the build.
  --include-untracked       Also upload untracked, non-ignored repo files.
  --fetch-artifacts DIR     Wait for completion and copy output files and logs
                            to DIR. If the build creates output and then fails,
                            copy output, logs, and reports before returning the
                            failure.
  --install-prereqs         Install tmux and docker.io if missing. Default behavior.
  --no-install-prereqs      Fail instead of installing missing tmux/docker on the EC2 host.
  --help                    Show this message.

Notes:
  - <lock-file> must be inside this repo so it can be uploaded together with the rest
    of the build inputs.
  - The build runs remotely inside tmux and inside the Docker image defined by
    docker/Dockerfile.ec2.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

abs_repo_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$path"
  fi
}

# Expanded on the remote host after SSH connects.
# shellcheck disable=SC2088
REMOTE_ROOT='~/openwrt-ft-builds'
SESSION_NAME=''
BUILDER_IMAGE='ghcr.io/andreacovelli/patch-fix-repo/openwrt-builder:ubuntu-noble-20260410-snapshot-20260410t000000z@sha256:dd52704e37949d9e815ddc762c422258e13d6783371b7eabcde759b02e85650f'
REBUILD_BUILDER_IMAGE='0'
IMAGE_TAG='patch-fix-openwrt-builder'
BUILDER_PLATFORM='linux/amd64'
BUILDER_BASE_IMAGE=''
UBUNTU_SNAPSHOT=''
MAKE_JOBS=''
DOWNLOAD_JOBS=''
STRICT_MANIFEST='1'
INCLUDE_UNTRACKED='0'
FETCH_ARTIFACTS_DIR=''
INSTALL_PREREQS='auto'

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-root)
      [[ $# -ge 2 ]] || die "--remote-root requires a value"
      REMOTE_ROOT="$2"
      shift 2
      ;;
    --session)
      [[ $# -ge 2 ]] || die "--session requires a value"
      SESSION_NAME="$2"
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
    --include-untracked)
      INCLUDE_UNTRACKED='1'
      shift
      ;;
    --fetch-artifacts)
      [[ $# -ge 2 ]] || die "--fetch-artifacts requires a value"
      FETCH_ARTIFACTS_DIR="$2"
      shift 2
      ;;
    --install-prereqs)
      INSTALL_PREREQS='auto'
      shift
      ;;
    --no-install-prereqs)
      INSTALL_PREREQS='never'
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

SSH_TARGET="${POSITIONAL[0]}"
LOCK_FILE="$(abs_repo_path "${POSITIONAL[1]}")"

require_cmd awk bash curl date git mkdir mktemp mv scp sed sha256sum ssh tar

SSH_CMD=(ssh)
SCP_CMD=(scp)
if [[ -n "${SSH_CONFIG_FILE:-}" ]]; then
  [[ -f "$SSH_CONFIG_FILE" ]] || die "SSH_CONFIG_FILE does not exist: $SSH_CONFIG_FILE"
  SSH_CMD+=(-F "$SSH_CONFIG_FILE")
  SCP_CMD+=(-F "$SSH_CONFIG_FILE")
fi

[[ -f "$LOCK_FILE" ]] || die "lock file not found: $LOCK_FILE"
case "$LOCK_FILE" in
  "$REPO_ROOT"/*) ;;
  *)
    die "lock file must live inside the repo: $LOCK_FILE"
    ;;
esac

LOCK_FILE_REL="${LOCK_FILE#"$REPO_ROOT"/}"

if [[ -z "$SESSION_NAME" ]]; then
  SESSION_NAME="$(openwrt_default_build_name_from_lock "$LOCK_FILE")"
fi
TMUX_SESSION_NAME="${SESSION_NAME//./_}"

case "$SESSION_NAME" in
  *[!A-Za-z0-9._-]*)
    die "session name contains unsupported characters: $SESSION_NAME"
    ;;
esac

case "$STRICT_MANIFEST" in
  0|1) ;;
  *)
    die "strict manifest value must be 0 or 1"
    ;;
esac

[[ -n "$BUILDER_PLATFORM" ]] || die "--platform must not be empty"
[[ -n "$BUILDER_IMAGE" ]] || die "--builder-image must not be empty"
case "$REBUILD_BUILDER_IMAGE" in
  0|1) ;;
  *) die "rebuild builder image value must be 0 or 1" ;;
esac

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

remote_shell_quote() {
  printf '%q' "$1"
}

remote_tmux_has_session() {
  "${SSH_CMD[@]}" "$SSH_TARGET" 'bash -s' -- "$(remote_shell_quote "$1")" <<'REMOTE'
set -euo pipefail
tmux has-session -t "$1"
REMOTE
}

remote_cat_file() {
  "${SSH_CMD[@]}" "$SSH_TARGET" 'bash -s' -- "$(remote_shell_quote "$1")" <<'REMOTE'
set -euo pipefail
cat "$1"
REMOTE
}

remote_dir_exists() {
  "${SSH_CMD[@]}" "$SSH_TARGET" 'bash -s' -- "$(remote_shell_quote "$1")" <<'REMOTE'
set -euo pipefail
[[ -d "$1" ]]
REMOTE
}

detect_ghcr_username() {
  if [[ -n "${GHCR_USERNAME:-}" ]]; then
    printf '%s\n' "$GHCR_USERNAME"
    return 0
  fi

  if [[ -n "${GITHUB_ACTOR:-}" ]]; then
    printf '%s\n' "$GITHUB_ACTOR"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    gh api user --jq .login 2>/dev/null || true
  fi
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

copy_remote_dir_contents() {
  local remote_dir="$1"
  local local_dir="$2"

  mkdir -p "$local_dir"
  "${SCP_CMD[@]}" -r "$SSH_TARGET:$(remote_shell_quote "$remote_dir")/." "$local_dir/"
}

copy_remote_build_log() {
  local remote_log_file="$1"
  local local_dir="$2"

  [[ -n "$remote_log_file" ]] || return 0
  mkdir -p "$local_dir/logs"
  if ! "${SCP_CMD[@]}" "$SSH_TARGET:$(remote_shell_quote "$remote_log_file")" "$local_dir/logs/ec2-build.log"; then
    log "Warning: failed to copy remote build log: $remote_log_file"
  fi
}

log "Preparing remote workspace metadata"
REMOTE_SETUP_INFO="$(
  "${SSH_CMD[@]}" "$SSH_TARGET" 'bash -s' -- \
    "$(remote_shell_quote "$REMOTE_ROOT")" \
    "$(remote_shell_quote "$SESSION_NAME")" \
    "$(remote_shell_quote "$TMUX_SESSION_NAME")" \
    "$(remote_shell_quote "$INSTALL_PREREQS")" <<'REMOTE'
set -euo pipefail

remote_root="$1"
session_name="$2"
tmux_session_name="$3"
install_prereqs="$4"

case "$remote_root" in
  "~") remote_root="$HOME" ;;
  "~/"*) remote_root="$HOME/${remote_root#~/}" ;;
esac

run_root="$remote_root/runs/$session_name"
repo_dir="$run_root/repo"
cache_dir="$remote_root/cache"
log_dir="$remote_root/logs"

need_install=0
command -v tmux >/dev/null 2>&1 || need_install=1
command -v docker >/dev/null 2>&1 || need_install=1

start_docker() {
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  if ! docker info >/dev/null 2>&1; then
    sudo service docker start >/dev/null 2>&1 || true
  fi
}

install_buildx() {
  if command -v apt-get >/dev/null 2>&1; then
    if apt-cache show docker-buildx >/dev/null 2>&1; then
      sudo apt-get install -y docker-buildx
    fi
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y docker-buildx-plugin >/dev/null 2>&1 ||
      sudo dnf install -y docker-buildx >/dev/null 2>&1 ||
      true
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y docker-buildx-plugin >/dev/null 2>&1 ||
      sudo yum install -y docker-buildx >/dev/null 2>&1 ||
      true
  fi
}

install_prereqs() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y tmux docker.io
    install_buildx
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y tmux docker
    install_buildx
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y tmux docker
    install_buildx
  else
    printf 'error: no supported package manager found; install tmux and docker manually\n' >&2
    exit 1
  fi

  start_docker
}

case "$install_prereqs" in
  auto)
    if (( need_install )); then
      command -v sudo >/dev/null 2>&1 || {
        printf 'error: tmux/docker missing and sudo is unavailable on the remote host\n' >&2
        exit 1
      }
      install_prereqs
    fi
    ;;
  never)
    if (( need_install )); then
      printf 'error: tmux/docker missing on remote host and auto-install is disabled\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'error: unsupported install mode: %s\n' "$install_prereqs" >&2
    exit 1
    ;;
esac

if docker info >/dev/null 2>&1; then
  docker_mode='docker'
else
  command -v sudo >/dev/null 2>&1 || {
    printf 'error: docker requires sudo on the remote host, but sudo is unavailable\n' >&2
    exit 1
  }
  start_docker
  sudo docker info >/dev/null 2>&1 || {
    printf 'error: docker is not usable on the remote host\n' >&2
    exit 1
  }
  docker_mode='sudo docker'
fi

if [[ "$install_prereqs" == 'auto' ]]; then
  case "$docker_mode" in
    "docker") docker_cmd=(docker) ;;
    "sudo docker") docker_cmd=(sudo docker) ;;
  esac
  if ! "${docker_cmd[@]}" buildx version >/dev/null 2>&1; then
    command -v sudo >/dev/null 2>&1 && install_buildx
  fi
fi

tmux has-session -t "$tmux_session_name" 2>/dev/null && {
  printf 'error: tmux session already exists: %s\n' "$tmux_session_name" >&2
  exit 1
}

mkdir -p "$repo_dir" "$cache_dir" "$log_dir"
printf '%s\n%s\n%s\n%s\n' "$remote_root" "$run_root" "$repo_dir" "$docker_mode" >"$run_root/.orchestrator-state"
printf 'remote_root=%s\n' "$remote_root"
printf 'cache_dir=%s\n' "$cache_dir"
REMOTE
)"

REMOTE_ROOT_EXPANDED="$(printf '%s\n' "$REMOTE_SETUP_INFO" | sed -n 's/^remote_root=//p')"
REMOTE_CACHE_DIR="$(printf '%s\n' "$REMOTE_SETUP_INFO" | sed -n 's/^cache_dir=//p')"
[[ -n "$REMOTE_ROOT_EXPANDED" ]] || die "remote setup did not report expanded remote root"
[[ -n "$REMOTE_CACHE_DIR" ]] || die "remote setup did not report cache directory"

if [[ "$REBUILD_BUILDER_IMAGE" == '0' && "$BUILDER_IMAGE" == ghcr.io/* ]]; then
  ghcr_token="${GHCR_TOKEN:-}"
  if [[ -n "$ghcr_token" ]]; then
    ghcr_username="$(detect_ghcr_username)"
    [[ -n "$ghcr_username" ]] ||
      die "could not determine GHCR username; set GHCR_USERNAME or authenticate gh locally"
    log "Authenticating remote Docker to ghcr.io as $ghcr_username"
    printf '%s' "$ghcr_token" |
      "${SSH_CMD[@]}" "$SSH_TARGET" 'bash -c '"'"'
        set -euo pipefail
        ghcr_username="$1"
        if docker info >/dev/null 2>&1; then
          docker login ghcr.io -u "$ghcr_username" --password-stdin
        else
          sudo docker login ghcr.io -u "$ghcr_username" --password-stdin
        fi >/dev/null
      '"'"' bash' "$(remote_shell_quote "$ghcr_username")"
  else
    log "Warning: no GHCR_TOKEN set; private GHCR pull may fail"
  fi
fi

LOCAL_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/openwrt-ft-build.XXXXXXXX.tar.gz")"
SNAPSHOT_FILE_LIST="$(mktemp "${TMPDIR:-/tmp}/openwrt-ft-files.XXXXXXXX")"
PREBUILT_APK_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-ft-prebuilt-apks.XXXXXXXX")"
REMOTE_ARCHIVE="/tmp/openwrt-ft-build-${SESSION_NAME}.tar.gz"
cleanup() {
  rm -rf "$PREBUILT_APK_CACHE"
  rm -f "$LOCAL_ARCHIVE" "$SNAPSHOT_FILE_LIST"
}
trap cleanup EXIT

mapfile -d '' -t LOCK_PREBUILT_APKS < <(lock_prebuilt_apks)
if ((${#LOCK_PREBUILT_APKS[@]} > 0)); then
  log "Downloading pinned prebuilt APKs before remote build"
  prebuilt_apk_download_all "$PREBUILT_APK_CACHE" "${LOCK_PREBUILT_APKS[@]}"
fi

if [[ "$INCLUDE_UNTRACKED" == '1' ]]; then
  log "Uploading tracked and untracked non-ignored repo files to $SSH_TARGET"
else
  log "Uploading tracked repo snapshot to $SSH_TARGET"
fi

(
  cd "$REPO_ROOT"
  git ls-files -z >"$SNAPSHOT_FILE_LIST"
  if [[ "$INCLUDE_UNTRACKED" == '1' ]]; then
    git ls-files -z --others --exclude-standard >>"$SNAPSHOT_FILE_LIST"
  fi
  tar --null -czf "$LOCAL_ARCHIVE" --files-from "$SNAPSHOT_FILE_LIST"
)

"${SCP_CMD[@]}" "$LOCAL_ARCHIVE" "$SSH_TARGET:$REMOTE_ARCHIVE"

if ((${#LOCK_PREBUILT_APKS[@]} > 0)); then
  "${SSH_CMD[@]}" "$SSH_TARGET" 'bash -s' -- "$(remote_shell_quote "$REMOTE_CACHE_DIR")" <<'REMOTE'
set -euo pipefail

cache_dir="$1"
mkdir -p "$cache_dir/dl"
REMOTE
  "${SCP_CMD[@]}" "$PREBUILT_APK_CACHE"/*.apk "$SSH_TARGET:$(remote_shell_quote "$REMOTE_CACHE_DIR")/dl/"
fi

"${SSH_CMD[@]}" "$SSH_TARGET" 'bash -s' -- \
  "$(remote_shell_quote "$REMOTE_ROOT")" \
  "$(remote_shell_quote "$SESSION_NAME")" \
  "$(remote_shell_quote "$REMOTE_ARCHIVE")" <<'REMOTE'
set -euo pipefail

remote_root="$1"
session_name="$2"
remote_archive="$3"

case "$remote_root" in
  "~") remote_root="$HOME" ;;
  "~/"*) remote_root="$HOME/${remote_root#~/}" ;;
esac

repo_dir="$remote_root/runs/$session_name/repo"
mkdir -p "$repo_dir"
tar -xzf "$remote_archive" -C "$repo_dir"
rm -f "$remote_archive"
REMOTE

log "Creating remote tmux build launcher"
REMOTE_EMPTY_ARG='__openwrt_ft_empty_arg__'
remote_arg() {
  if [[ -n "$1" ]]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$REMOTE_EMPTY_ARG"
  fi
}

REMOTE_INFO="$(
  "${SSH_CMD[@]}" "$SSH_TARGET" 'bash -s' -- \
    "$(remote_shell_quote "$REMOTE_ROOT")" \
    "$(remote_shell_quote "$SESSION_NAME")" \
    "$(remote_shell_quote "$TMUX_SESSION_NAME")" \
    "$(remote_shell_quote "$BUILDER_IMAGE")" \
    "$(remote_shell_quote "$REBUILD_BUILDER_IMAGE")" \
    "$(remote_shell_quote "$IMAGE_TAG")" \
    "$(remote_shell_quote "$LOCK_FILE_REL")" \
    "$(remote_shell_quote "$(remote_arg "$MAKE_JOBS")")" \
    "$(remote_shell_quote "$(remote_arg "$DOWNLOAD_JOBS")")" \
    "$(remote_shell_quote "$STRICT_MANIFEST")" \
    "$(remote_shell_quote "$(remote_arg "$BUILDER_BASE_IMAGE")")" \
    "$(remote_shell_quote "$(remote_arg "$UBUNTU_SNAPSHOT")")" \
    "$(remote_shell_quote "$BUILDER_PLATFORM")" <<'REMOTE'
set -euo pipefail

empty_arg='__openwrt_ft_empty_arg__'
decode_arg() {
  if [[ "${1-}" == "$empty_arg" ]]; then
    printf ''
  else
    printf '%s' "${1-}"
  fi
}

remote_root="$1"
session_name="$2"
tmux_session_name="$3"
builder_image="$4"
rebuild_builder_image="$5"
image_tag="$6"
lock_file_rel="$7"
make_jobs="$(decode_arg "$8")"
download_jobs="$(decode_arg "$9")"
strict_manifest="${10}"
builder_base_image="$(decode_arg "${11}")"
ubuntu_snapshot="$(decode_arg "${12}")"
builder_platform="${13}"

case "$remote_root" in
  "~") remote_root="$HOME" ;;
  "~/"*) remote_root="$HOME/${remote_root#~/}" ;;
esac

run_root="$remote_root/runs/$session_name"
repo_dir="$run_root/repo"
cache_dir="$remote_root/cache"
log_dir="$remote_root/logs"
log_file="$log_dir/$session_name.log"
launcher="$run_root/run-build.sh"
status_file="$run_root/build.exit"
docker_mode="$(sed -n '4p' "$run_root/.orchestrator-state")"

repo_dir_q="$(printf '%q' "$repo_dir")"
cache_dir_q="$(printf '%q' "$cache_dir")"
log_file_q="$(printf '%q' "$log_file")"
status_file_q="$(printf '%q' "$status_file")"
builder_image_q="$(printf '%q' "$builder_image")"
rebuild_builder_image_q="$(printf '%q' "$rebuild_builder_image")"
image_tag_q="$(printf '%q' "$image_tag")"
lock_file_q="$(printf '%q' "$lock_file_rel")"
session_q="$(printf '%q' "$session_name")"
make_jobs_q="$(printf '%q' "$make_jobs")"
download_jobs_q="$(printf '%q' "$download_jobs")"
strict_manifest_q="$(printf '%q' "$strict_manifest")"
builder_base_image_q="$(printf '%q' "$builder_base_image")"
ubuntu_snapshot_q="$(printf '%q' "$ubuntu_snapshot")"
builder_platform_q="$(printf '%q' "$builder_platform")"
docker_mode_q="$(printf '%q' "$docker_mode")"

cat >"$launcher" <<EOF
#!/usr/bin/env bash
set -euo pipefail

repo_dir=$repo_dir_q
cache_dir=$cache_dir_q
log_file=$log_file_q
status_file=$status_file_q
builder_image=$builder_image_q
rebuild_builder_image=$rebuild_builder_image_q
image_tag=$image_tag_q
lock_file=$lock_file_q
build_id=$session_q
make_jobs=$make_jobs_q
download_jobs=$download_jobs_q
strict_manifest=$strict_manifest_q
builder_base_image=$builder_base_image_q
ubuntu_snapshot=$ubuntu_snapshot_q
builder_platform=$builder_platform_q
docker_mode=$docker_mode_q

case "\$docker_mode" in
  "docker")
    docker_cmd=(docker)
    ;;
  "sudo docker")
    docker_cmd=(sudo docker)
    ;;
  *)
    printf 'error: unsupported docker mode: %s\n' "\$docker_mode" >&2
    exit 1
    ;;
esac

if "\${docker_cmd[@]}" buildx version >/dev/null 2>&1; then
  docker_build_cmd=("\${docker_cmd[@]}" buildx build --load)
else
  docker_build_cmd=("\${docker_cmd[@]}" build)
fi

docker_env=(-e CACHE_ROOT=/cache -e BUILD_ID="\$build_id" -e BUILDER_PLATFORM="\$builder_platform")
if [[ -n "\$make_jobs" ]]; then
  docker_env+=(-e MAKE_JOBS="\$make_jobs")
fi
if [[ -n "\$download_jobs" ]]; then
  docker_env+=(-e DOWNLOAD_JOBS="\$download_jobs")
fi
docker_env+=(-e STRICT_MANIFEST="\$strict_manifest")

docker_build_args=()
docker_platform_args=()
if [[ -n "\$builder_platform" ]]; then
  docker_platform_args+=(--platform "\$builder_platform")
fi
if [[ -n "\$builder_base_image" ]]; then
  docker_build_args+=(--build-arg "BUILDER_BASE_IMAGE=\$builder_base_image")
fi
if [[ -n "\$ubuntu_snapshot" ]]; then
  docker_build_args+=(--build-arg "UBUNTU_SNAPSHOT=\$ubuntu_snapshot")
fi

set +e
(
  set -euo pipefail
  cd "\$repo_dir"
  case "\$rebuild_builder_image" in
    0)
      image_tag="\$builder_image"
      printf '[%s] pulling docker image %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$image_tag"
      "\${docker_cmd[@]}" pull "\$image_tag"
      ;;
    1)
      printf '[%s] building docker image %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$image_tag"
      "\${docker_build_cmd[@]}" "\${docker_platform_args[@]}" "\${docker_build_args[@]}" -f docker/Dockerfile.ec2 -t "\$image_tag" .
      ;;
    *)
      printf 'error: unsupported rebuild_builder_image value: %s\n' "\$rebuild_builder_image" >&2
      exit 1
      ;;
  esac
  printf '[%s] starting container build for %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$lock_file"
  "\${docker_cmd[@]}" run --rm \\
    "\${docker_platform_args[@]}" \\
    "\${docker_env[@]}" \\
    -v "\$repo_dir:/workspace" \\
    -v "\$cache_dir:/cache" \\
    -w /workspace \\
    "\$image_tag" \\
    ./scripts/build-image.sh "\$lock_file"
) 2>&1 | tee "\$log_file"
status=\${PIPESTATUS[0]}
printf '%s\n' "\$status" >"\$status_file"
exit "\$status"
EOF

chmod +x "$launcher"
tmux new-session -d -s "$tmux_session_name" "bash '$launcher'"

printf 'run_root=%s\n' "$run_root"
printf 'repo_dir=%s\n' "$repo_dir"
printf 'log_file=%s\n' "$log_file"
printf 'artifact_dir=%s\n' "$repo_dir/build/$session_name/output"
printf 'status_file=%s\n' "$status_file"
printf 'session=%s\n' "$session_name"
printf 'tmux_session=%s\n' "$tmux_session_name"
REMOTE
)"

printf '%s\n' "$REMOTE_INFO"
printf '\n'
printf 'Attach: ssh %s "tmux attach -t %s"\n' "$SSH_TARGET" "$TMUX_SESSION_NAME"
printf 'Tail log: ssh %s "tail -f %s"\n' "$SSH_TARGET" "$(
  printf '%s\n' "$REMOTE_INFO" | sed -n 's/^log_file=//p'
)"

if [[ -n "$FETCH_ARTIFACTS_DIR" ]]; then
  remote_artifact_dir="$(printf '%s\n' "$REMOTE_INFO" | sed -n 's/^artifact_dir=//p')"
  remote_status_file="$(printf '%s\n' "$REMOTE_INFO" | sed -n 's/^status_file=//p')"
  remote_log_file="$(printf '%s\n' "$REMOTE_INFO" | sed -n 's/^log_file=//p')"
  remote_tmux_session="$(printf '%s\n' "$REMOTE_INFO" | sed -n 's/^tmux_session=//p')"
  remote_report_dir="${remote_artifact_dir%/output}/reports"

  [[ -n "$remote_artifact_dir" ]] || die "remote artifact directory was not reported"
  [[ -n "$remote_status_file" ]] || die "remote status file was not reported"
  [[ -n "$remote_tmux_session" ]] || die "remote tmux session was not reported"

  log "Waiting for remote build session to finish: $SESSION_NAME"
  while remote_tmux_has_session "$remote_tmux_session" >/dev/null 2>&1; do
    sleep 30
  done

  build_status="$(remote_cat_file "$remote_status_file" 2>/dev/null || true)"
  case "$build_status" in
    0)
      ;;
    '')
      if remote_dir_exists "$remote_artifact_dir" >/dev/null 2>&1; then
        log "Remote build wrote artifacts but no status file was found; copying artifacts before failing"
        copy_remote_dir_contents "$remote_artifact_dir" "$FETCH_ARTIFACTS_DIR"
        if remote_dir_exists "$remote_report_dir" >/dev/null 2>&1; then
          copy_remote_dir_contents "$remote_report_dir" "$FETCH_ARTIFACTS_DIR/reports"
        fi
      fi
      copy_remote_build_log "$remote_log_file" "$FETCH_ARTIFACTS_DIR"
      die "remote build finished but no status file was found; inspect log: ssh $SSH_TARGET \"tail -f $(remote_shell_quote "$remote_log_file")\""
      ;;
    *[!0-9]*)
      copy_remote_build_log "$remote_log_file" "$FETCH_ARTIFACTS_DIR"
      die "remote build wrote an invalid status: $build_status"
      ;;
    *)
      if remote_dir_exists "$remote_artifact_dir" >/dev/null 2>&1; then
        log "Remote build failed with exit status $build_status; copying available artifacts to $FETCH_ARTIFACTS_DIR"
        copy_remote_dir_contents "$remote_artifact_dir" "$FETCH_ARTIFACTS_DIR"
        if remote_dir_exists "$remote_report_dir" >/dev/null 2>&1; then
          copy_remote_dir_contents "$remote_report_dir" "$FETCH_ARTIFACTS_DIR/reports"
        fi
      fi
      copy_remote_build_log "$remote_log_file" "$FETCH_ARTIFACTS_DIR"
      log "Artifacts and logs copied to $FETCH_ARTIFACTS_DIR"
      printf 'error: remote build failed with exit status %s; inspect log: ssh %s "tail -f %s"\n' \
        "$build_status" "$SSH_TARGET" "$(remote_shell_quote "$remote_log_file")" >&2
      exit "$build_status"
      ;;
  esac

  log "Copying remote artifacts to $FETCH_ARTIFACTS_DIR"
  copy_remote_dir_contents "$remote_artifact_dir" "$FETCH_ARTIFACTS_DIR"
  if remote_dir_exists "$remote_report_dir" >/dev/null 2>&1; then
    copy_remote_dir_contents "$remote_report_dir" "$FETCH_ARTIFACTS_DIR/reports"
  fi
  copy_remote_build_log "$remote_log_file" "$FETCH_ARTIFACTS_DIR"
  log "Artifacts and logs copied to $FETCH_ARTIFACTS_DIR"
fi
