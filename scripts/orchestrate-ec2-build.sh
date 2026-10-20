#!/usr/bin/env bash
set -euo pipefail

umask 022
HOST_PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/build-name.sh
source "$SCRIPT_DIR/lib/build-name.sh"
# shellcheck source=scripts/lib/build-wrapper.sh
source "$SCRIPT_DIR/lib/build-wrapper.sh"
# shellcheck source=scripts/lib/prebuilt-apks.sh
source "$SCRIPT_DIR/lib/prebuilt-apks.sh"
# shellcheck source=scripts/lib/builder-image.sh
source "$SCRIPT_DIR/lib/builder-image.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/orchestrate-ec2-build.sh [options] <ssh-target> <lock-file>

Options:
  --remote-root PATH        Remote workspace root. Default: ~/openwrt-ft-builds
  --session NAME            tmux session and build id. Default:
                            openwrt-ft-<device-id>-<openwrt-version>-<variant>-<utc>
  --builder-image REF       Prebuilt Docker builder image. Default:
                            DEFAULT_BUILDER_IMAGE in
                            scripts/lib/builder-image.sh.
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
  --build-method METHOD     source or imagebuilder. Default: the lock's
                            DEFAULT_BUILD_METHOD, or source.
  --include-untracked       Also upload untracked, non-ignored repo files.
  --fetch-artifacts DIR     Wait for completion and copy output files and logs
                            to DIR, which must not exist yet. Output is staged
                            and published only after sha256sums.txt verifies.
                            If the build creates output and then fails, copy
                            output, logs, and reports before returning the
                            failure. Polling tolerates SSH outages of up to
                            about 10 minutes.
  --install-prereqs         Install tmux and docker.io if missing. Default behavior.
  --no-install-prereqs      Fail instead of installing missing tmux/docker on the EC2 host.
  --help                    Show this message.

Notes:
  - <lock-file> must be inside this repo so it can be uploaded together with the rest
    of the build inputs.
  - The remote host runs scripts/run-local-docker-build.sh from the uploaded
    snapshot inside tmux, as a fresh build without ccache in a workspace
    named after the session.
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

# Expanded on the remote host after SSH connects.
# shellcheck disable=SC2088
REMOTE_ROOT='~/openwrt-ft-builds'
build_wrapper_option_defaults
INCLUDE_UNTRACKED='0'
FETCH_ARTIFACTS_DIR=''
INSTALL_PREREQS='auto'

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  build_wrapper_take_option "$@" || exit 1
  if ((BUILD_WRAPPER_SHIFT > 0)); then
    shift "$BUILD_WRAPPER_SHIFT"
    continue
  fi
  case "$1" in
    --remote-root)
      [[ $# -ge 2 ]] || die "--remote-root requires a value"
      REMOTE_ROOT="$2"
      shift 2
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

require_cmd awk bash curl date dirname git mkdir mktemp mv scp sed sha256sum ssh tar

SSH_CMD=(ssh)
SCP_CMD=(scp)
if [[ -n "${SSH_CONFIG_FILE:-}" ]]; then
  [[ -f "$SSH_CONFIG_FILE" ]] || die "SSH_CONFIG_FILE does not exist: $SSH_CONFIG_FILE"
  SSH_CMD+=(-F "$SSH_CONFIG_FILE")
  SCP_CMD+=(-F "$SSH_CONFIG_FILE")
fi

build_wrapper_resolve_lock "$REPO_ROOT" "${POSITIONAL[1]}" LOCK_FILE LOCK_FILE_REL || exit 1
BUILDER_IMAGE="${BUILDER_IMAGE:-$DEFAULT_BUILDER_IMAGE}"

if [[ -z "$SESSION_NAME" ]]; then
  SESSION_NAME="$(openwrt_default_build_name_from_lock "$LOCK_FILE")"
fi
TMUX_SESSION_NAME="${SESSION_NAME//./_}"
build_wrapper_check_name session "$SESSION_NAME" || exit 1

if [[ -n "$FETCH_ARTIFACTS_DIR" ]]; then
  [[ ! -e "$FETCH_ARTIFACTS_DIR" && ! -L "$FETCH_ARTIFACTS_DIR" ]] ||
    die "artifact directory already exists: $FETCH_ARTIFACTS_DIR"
fi

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

detect_ghcr_username() (
  export PATH="$HOST_PATH"
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
)

# SSH and scp exit 255 for connection failures, unlike remote command
# failures. Retry only those, so a brief network outage cannot end a long build.
retry_on_ssh_failure() {
  local attempt status

  for attempt in 1 2 3 4 5; do
    status=0
    "$@" || status=$?
    if ((status != 255)); then
      return "$status"
    fi
    log "Warning: SSH connection failed (attempt $attempt/5)" >&2
    if ((attempt < 5)); then
      sleep 10
    fi
  done
  return 255
}

copy_remote_dir_contents() {
  local remote_dir="$1"
  local local_dir="$2"

  mkdir -p "$local_dir"
  retry_on_ssh_failure "${SCP_CMD[@]}" -r "$SSH_TARGET:$(remote_shell_quote "$remote_dir")/." "$local_dir/"
}

copy_remote_build_log() {
  local remote_log_file="$1"
  local local_dir="$2"

  [[ -n "$remote_log_file" ]] || return 0
  mkdir -p "$local_dir/logs"
  if ! retry_on_ssh_failure "${SCP_CMD[@]}" "$SSH_TARGET:$(remote_shell_quote "$remote_log_file")" "$local_dir/logs/ec2-build.log"; then
    log "Warning: failed to copy remote build log: $remote_log_file"
  fi
}

ARTIFACT_STAGING_DIR=''

create_artifact_staging() {
  ARTIFACT_STAGING_DIR="$(build_wrapper_create_staging "$FETCH_ARTIFACTS_DIR")" || exit 1
}

# On failure the cleanup trap reports the kept staging directory.
publish_artifact_staging() {
  build_wrapper_publish_artifacts "$ARTIFACT_STAGING_DIR" "$FETCH_ARTIFACTS_DIR" || exit 1
  ARTIFACT_STAGING_DIR=''
}

# Copy a remote output directory and, when present, its sibling reports
# directory into the artifact staging directory.
copy_remote_outputs() {
  local remote_artifact_dir="$1"
  local remote_report_dir="${remote_artifact_dir%/output}/reports"

  copy_remote_dir_contents "$remote_artifact_dir" "$ARTIFACT_STAGING_DIR"
  if retry_on_ssh_failure remote_dir_exists "$remote_report_dir" >/dev/null 2>&1; then
    copy_remote_dir_contents "$remote_report_dir" "$ARTIFACT_STAGING_DIR/reports"
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
# Fresh EC2 builders install tmux and Docker from user data at boot. Waiting
# also avoids racing cloud-init for the apt lock.
if command -v cloud-init >/dev/null 2>&1; then
  timeout 900 cloud-init status --wait >/dev/null 2>&1 || true
fi

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
  if [[ -n "$ARTIFACT_STAGING_DIR" && -d "$ARTIFACT_STAGING_DIR" ]]; then
    printf 'warning: unpublished artifact copy kept at %s\n' "$ARTIFACT_STAGING_DIR" >&2
  fi
}
trap cleanup EXIT

mapfile -d '' -t LOCK_PREBUILT_APKS < <(prebuilt_apk_lock_entries "$LOCK_FILE")
if ((${#LOCK_PREBUILT_APKS[@]} > 0)); then
  log "Downloading pinned prebuilt APKs before remote build"
  (
    export PATH="$HOST_PATH"
    prebuilt_apk_download_all "$PREBUILT_APK_CACHE" "${LOCK_PREBUILT_APKS[@]}"
  )
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
  "$(remote_shell_quote "$REMOTE_ROOT_EXPANDED")" \
  "$(remote_shell_quote "$SESSION_NAME")" \
  "$(remote_shell_quote "$REMOTE_ARCHIVE")" <<'REMOTE'
set -euo pipefail

remote_root="$1"
session_name="$2"
remote_archive="$3"

repo_dir="$remote_root/runs/$session_name/repo"
mkdir -p "$repo_dir"
tar -xzf "$remote_archive" -C "$repo_dir"
rm -f "$remote_archive"
REMOTE

log "Creating remote tmux build launcher"
# The remote host runs the local Docker wrapper on the uploaded snapshot. Each
# EC2 run is a disposable full build in its own workspace, without ccache.
remote_build_args=(
  --session "$SESSION_NAME"
  --workspace "$SESSION_NAME"
  --cache-dir "$REMOTE_CACHE_DIR"
  --fresh
  --no-ccache
)
build_wrapper_option_args remote_build_args
remote_build_args+=("$LOCK_FILE_REL")
remote_build_args_quoted=()
for arg in "${remote_build_args[@]}"; do
  remote_build_args_quoted+=("$(remote_shell_quote "$arg")")
done

REMOTE_INFO="$(
  "${SSH_CMD[@]}" "$SSH_TARGET" 'bash -s' -- \
    "$(remote_shell_quote "$REMOTE_ROOT_EXPANDED")" \
    "$(remote_shell_quote "$SESSION_NAME")" \
    "$(remote_shell_quote "$TMUX_SESSION_NAME")" \
    "${remote_build_args_quoted[@]}" <<'REMOTE'
set -euo pipefail

remote_root="$1"
session_name="$2"
tmux_session_name="$3"
shift 3

run_root="$remote_root/runs/$session_name"
repo_dir="$run_root/repo"
log_file="$remote_root/logs/$session_name.log"
launcher="$run_root/run-build.sh"
status_file="$run_root/build.exit"
docker_mode="$(sed -n '4p' "$run_root/.orchestrator-state")"

case "$docker_mode" in
  'docker')
    docker_bin='docker'
    ;;
  'sudo docker')
    # run-local-docker-build.sh takes one Docker command.
    docker_bin="$run_root/docker"
    printf '#!/usr/bin/env bash\nexec sudo docker "$@"\n' >"$docker_bin"
    chmod +x "$docker_bin"
    ;;
  *)
    printf 'error: unsupported docker mode: %s\n' "$docker_mode" >&2
    exit 1
    ;;
esac

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n\n'
  printf 'repo_dir=%q\n' "$repo_dir"
  printf 'log_file=%q\n' "$log_file"
  printf 'status_file=%q\n' "$status_file"
  printf 'docker_bin=%q\n' "$docker_bin"
  printf 'build_args=('
  printf ' %q' "$@"
  printf ' )\n'
  cat <<'LAUNCHER'

set +e
(
  cd "$repo_dir"
  OPENWRT_DOCKER_BIN="$docker_bin" ./scripts/run-local-docker-build.sh "${build_args[@]}"
) 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
printf '%s\n' "$status" >"$status_file"
exit "$status"
LAUNCHER
} >"$launcher"

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

  [[ -n "$remote_artifact_dir" ]] || die "remote artifact directory was not reported"
  [[ -n "$remote_status_file" ]] || die "remote status file was not reported"
  [[ -n "$remote_tmux_session" ]] || die "remote tmux session was not reported"

  log "Waiting for remote build session to finish: $SESSION_NAME"
  # tmux has-session exits 1 once the session ends; 255 means SSH failed.
  # Twenty consecutive failed 30-second polls is about 10 minutes offline.
  poll_failures=0
  while true; do
    poll_status=0
    remote_tmux_has_session "$remote_tmux_session" >/dev/null 2>&1 || poll_status=$?
    case "$poll_status" in
      0)
        poll_failures=0
        ;;
      255)
        poll_failures=$((poll_failures + 1))
        ((poll_failures < 20)) ||
          die "lost SSH to $SSH_TARGET while the build may still be running; reattach: ssh $SSH_TARGET \"tmux attach -t $remote_tmux_session\""
        log "Warning: SSH poll failed ($poll_failures/20); retrying"
        ;;
      *)
        break
        ;;
    esac
    sleep 30
  done

  build_status="$(retry_on_ssh_failure remote_cat_file "$remote_status_file" 2>/dev/null || true)"
  create_artifact_staging
  case "$build_status" in
    0)
      ;;
    '')
      if retry_on_ssh_failure remote_dir_exists "$remote_artifact_dir" >/dev/null 2>&1; then
        log "Remote build wrote artifacts but no status file was found; copying artifacts before failing"
        copy_remote_outputs "$remote_artifact_dir"
      fi
      copy_remote_build_log "$remote_log_file" "$ARTIFACT_STAGING_DIR"
      publish_artifact_staging
      die "remote build finished but no status file was found; inspect log: ssh $SSH_TARGET \"tail -f $(remote_shell_quote "$remote_log_file")\""
      ;;
    *[!0-9]*)
      copy_remote_build_log "$remote_log_file" "$ARTIFACT_STAGING_DIR"
      publish_artifact_staging
      die "remote build wrote an invalid status: $build_status"
      ;;
    *)
      if retry_on_ssh_failure remote_dir_exists "$remote_artifact_dir" >/dev/null 2>&1; then
        log "Remote build failed with exit status $build_status; copying available artifacts to $FETCH_ARTIFACTS_DIR"
        copy_remote_outputs "$remote_artifact_dir"
      fi
      copy_remote_build_log "$remote_log_file" "$ARTIFACT_STAGING_DIR"
      publish_artifact_staging
      log "Artifacts and logs copied to $FETCH_ARTIFACTS_DIR"
      printf 'error: remote build failed with exit status %s; inspect log: ssh %s "tail -f %s"\n' \
        "$build_status" "$SSH_TARGET" "$(remote_shell_quote "$remote_log_file")" >&2
      exit "$build_status"
      ;;
  esac

  log "Copying remote artifacts for $FETCH_ARTIFACTS_DIR"
  copy_remote_outputs "$remote_artifact_dir"
  copy_remote_build_log "$remote_log_file" "$ARTIFACT_STAGING_DIR"

  log "Verifying copied artifact checksums"
  build_wrapper_verify_artifacts "$ARTIFACT_STAGING_DIR" || exit 1
  publish_artifact_staging
  log "Artifacts and logs copied to $FETCH_ARTIFACTS_DIR"
fi
