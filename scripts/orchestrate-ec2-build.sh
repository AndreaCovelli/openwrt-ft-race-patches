#!/usr/bin/env bash
set -euo pipefail

umask 022
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/orchestrate-ec2-build.sh [options] <ssh-target> <lock-file>

Options:
  --remote-root PATH        Remote workspace root. Default: ~/openwrt-ft-builds
  --session NAME            tmux session and build id. Default: <lock-stem>-<utc-timestamp>
  --image-tag TAG           Remote Docker image tag. Default: patch-fix-openwrt-builder
  --builder-base-image REF  Docker base image override for Dockerfile.ec2.
  --ubuntu-snapshot TS      Ubuntu apt snapshot timestamp. Default comes from Dockerfile.ec2.
  --make-jobs N             Export MAKE_JOBS into the container build.
  --download-jobs N         Export DOWNLOAD_JOBS into the container build.
  --strict-manifest         Fail if built package manifest drifts. Default behavior.
  --no-strict-manifest      Report package drift without failing the build.
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
IMAGE_TAG='patch-fix-openwrt-builder'
BUILDER_BASE_IMAGE=''
UBUNTU_SNAPSHOT=''
MAKE_JOBS=''
DOWNLOAD_JOBS=''
STRICT_MANIFEST='1'
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
    --image-tag)
      [[ $# -ge 2 ]] || die "--image-tag requires a value"
      IMAGE_TAG="$2"
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

require_cmd bash date mktemp scp sed ssh tar

[[ -f "$LOCK_FILE" ]] || die "lock file not found: $LOCK_FILE"
case "$LOCK_FILE" in
  "$REPO_ROOT"/*) ;;
  *)
    die "lock file must live inside the repo: $LOCK_FILE"
    ;;
esac

LOCK_FILE_REL="${LOCK_FILE#"$REPO_ROOT"/}"
LOCK_STEM="$(basename "$LOCK_FILE_REL" .lock)"

if [[ -z "$SESSION_NAME" ]]; then
  SESSION_NAME="${LOCK_STEM}-$(date -u '+%Y%m%dT%H%M%SZ')"
fi

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

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log "Preparing remote workspace metadata"
ssh "$SSH_TARGET" 'bash -s' -- "$REMOTE_ROOT" "$SESSION_NAME" "$INSTALL_PREREQS" <<'REMOTE'
set -euo pipefail

remote_root="$1"
session_name="$2"
install_prereqs="$3"

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

install_prereqs() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y tmux docker.io
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y tmux docker
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y tmux docker
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

tmux has-session -t "$session_name" 2>/dev/null && {
  printf 'error: tmux session already exists: %s\n' "$session_name" >&2
  exit 1
}

mkdir -p "$repo_dir" "$cache_dir" "$log_dir"
printf '%s\n%s\n%s\n%s\n' "$remote_root" "$run_root" "$repo_dir" "$docker_mode" >"$run_root/.orchestrator-state"
REMOTE

log "Uploading repo snapshot to $SSH_TARGET"
LOCAL_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/openwrt-ft-build.XXXXXXXX.tar.gz")"
REMOTE_ARCHIVE="/tmp/openwrt-ft-build-${SESSION_NAME}.tar.gz"
cleanup() {
  rm -f "$LOCAL_ARCHIVE"
}
trap cleanup EXIT

(
  cd "$REPO_ROOT"
  tar \
    --exclude='.git' \
    --exclude='.codex' \
    --exclude='build' \
    --exclude='cache' \
    --exclude='.DS_Store' \
    -czf "$LOCAL_ARCHIVE" .
)

scp "$LOCAL_ARCHIVE" "$SSH_TARGET:$REMOTE_ARCHIVE"

ssh "$SSH_TARGET" 'bash -s' -- "$REMOTE_ROOT" "$SESSION_NAME" "$REMOTE_ARCHIVE" <<'REMOTE'
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
REMOTE_INFO="$(
  ssh "$SSH_TARGET" 'bash -s' -- \
    "$REMOTE_ROOT" \
    "$SESSION_NAME" \
    "$IMAGE_TAG" \
    "$LOCK_FILE_REL" \
    "$MAKE_JOBS" \
    "$DOWNLOAD_JOBS" \
    "$STRICT_MANIFEST" \
    "$BUILDER_BASE_IMAGE" \
    "$UBUNTU_SNAPSHOT" <<'REMOTE'
set -euo pipefail

remote_root="$1"
session_name="$2"
image_tag="$3"
lock_file_rel="$4"
make_jobs="$5"
download_jobs="$6"
strict_manifest="$7"
builder_base_image="$8"
ubuntu_snapshot="$9"

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
docker_mode="$(sed -n '4p' "$run_root/.orchestrator-state")"

repo_dir_q="$(printf '%q' "$repo_dir")"
cache_dir_q="$(printf '%q' "$cache_dir")"
log_file_q="$(printf '%q' "$log_file")"
image_tag_q="$(printf '%q' "$image_tag")"
lock_file_q="$(printf '%q' "$lock_file_rel")"
session_q="$(printf '%q' "$session_name")"
make_jobs_q="$(printf '%q' "$make_jobs")"
download_jobs_q="$(printf '%q' "$download_jobs")"
strict_manifest_q="$(printf '%q' "$strict_manifest")"
builder_base_image_q="$(printf '%q' "$builder_base_image")"
ubuntu_snapshot_q="$(printf '%q' "$ubuntu_snapshot")"
docker_mode_q="$(printf '%q' "$docker_mode")"

cat >"$launcher" <<EOF
#!/usr/bin/env bash
set -euo pipefail

repo_dir=$repo_dir_q
cache_dir=$cache_dir_q
log_file=$log_file_q
image_tag=$image_tag_q
lock_file=$lock_file_q
build_id=$session_q
make_jobs=$make_jobs_q
download_jobs=$download_jobs_q
strict_manifest=$strict_manifest_q
builder_base_image=$builder_base_image_q
ubuntu_snapshot=$ubuntu_snapshot_q
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

docker_env=(-e CACHE_ROOT=/cache -e BUILD_ID="\$build_id")
if [[ -n "\$make_jobs" ]]; then
  docker_env+=(-e MAKE_JOBS="\$make_jobs")
fi
if [[ -n "\$download_jobs" ]]; then
  docker_env+=(-e DOWNLOAD_JOBS="\$download_jobs")
fi
docker_env+=(-e STRICT_MANIFEST="\$strict_manifest")

docker_build_args=()
if [[ -n "\$builder_base_image" ]]; then
  docker_build_args+=(--build-arg "BUILDER_BASE_IMAGE=\$builder_base_image")
fi
if [[ -n "\$ubuntu_snapshot" ]]; then
  docker_build_args+=(--build-arg "UBUNTU_SNAPSHOT=\$ubuntu_snapshot")
fi

{
  cd "\$repo_dir"
  printf '[%s] building docker image %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$image_tag"
  "\${docker_cmd[@]}" build "\${docker_build_args[@]}" -f docker/Dockerfile.ec2 -t "\$image_tag" .
  printf '[%s] starting container build for %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$lock_file"
  "\${docker_cmd[@]}" run --rm \\
    "\${docker_env[@]}" \\
    -v "\$repo_dir:/workspace" \\
    -v "\$cache_dir:/cache" \\
    -w /workspace \\
    "\$image_tag" \\
    ./scripts/build-image.sh "\$lock_file"
} 2>&1 | tee "\$log_file"
EOF

chmod +x "$launcher"
tmux new-session -d -s "$session_name" "bash '$launcher'"

printf 'run_root=%s\n' "$run_root"
printf 'repo_dir=%s\n' "$repo_dir"
printf 'log_file=%s\n' "$log_file"
printf 'artifact_dir=%s\n' "$repo_dir/build/$session_name/output"
printf 'session=%s\n' "$session_name"
REMOTE
)"

printf '%s\n' "$REMOTE_INFO"
printf '\n'
printf 'Attach: ssh %s "tmux attach -t %s"\n' "$SSH_TARGET" "$SESSION_NAME"
printf 'Tail log: ssh %s "tail -f %s"\n' "$SSH_TARGET" "$(
  printf '%s\n' "$REMOTE_INFO" | sed -n 's/^log_file=//p'
)"
