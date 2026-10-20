#!/usr/bin/env bash
set -euo pipefail

# Run orchestrate-ec2-build.sh end to end against a fake remote host that is a
# local directory, so the remote side runs the uploaded run-local-docker-build.sh.

repo_root="$(git rev-parse --show-toplevel)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-ec2-remote-build.XXXXXXXX")"
session_prefix="check-ec2-remote-build-$$"
cleanup() {
  rm -rf "$tmp_root"
  rm -f /tmp/openwrt-ft-build-"$session_prefix"-*.tar.gz
}
trap cleanup EXIT
fixture="$tmp_root/repo"
mkdir -p "$fixture/scripts/lib" "$fixture/locks"
cp "$repo_root/scripts/"{orchestrate-ec2-build,run-local-docker-build}.sh "$fixture/scripts/"
cp "$repo_root/scripts/lib/"*.sh "$fixture/scripts/lib/"
: >"$fixture/locks/test.lock"
git -C "$fixture" init -q
git -C "$fixture" add scripts locks

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Exported Bash functions survive both wrappers' PATH sanitization. The remote
# host shares this filesystem, and nothing here contacts a host, runs Docker,
# or reaches the real sudo, tmux, or package managers.
fake_remote_path() {
  # Undo the orchestrator's remote shell quoting.
  bash -c "printf '%s' $1"
}
ssh() {
  shift
  bash -c "$*"
}
scp() {
  local src="${*: -2:1}" dest="${*: -1}" path
  case "$src" in
    fake-host:*)
      path="$(fake_remote_path "${src#fake-host:}")"
      if [[ "$path" == */. ]]; then
        cp -a "${path%/.}/." "$dest"
      else
        cp "$path" "$dest"
      fi
      ;;
    *)
      [[ "$dest" == fake-host:* ]] || return 81
      cp "$src" "$(fake_remote_path "${dest#fake-host:}")"
      ;;
  esac
}
sleep() { :; }
tmux() {
  local command launcher wrapper
  case "$1" in
    has-session) return 1 ;;
    new-session)
      command="${*: -1}"
      launcher="${command#bash \'}"
      launcher="${launcher%\'}"
      wrapper="$(dirname -- "$launcher")/docker"
      if [[ -e "$wrapper" ]]; then
        # The real wrapper execs sudo, which bypasses these functions. Check
        # it exactly, then swap in a call that reaches the fake sudo.
        [[ "$(cat "$wrapper")" == $'#!/usr/bin/env bash\nexec sudo docker "$@"' ]] || return 83
        printf '#!/usr/bin/env bash\nsudo docker "$@"\n' >"$wrapper"
      fi
      bash -c "$command" >/dev/null 2>&1 || true
      ;;
    *) return 81 ;;
  esac
}
sudo() {
  # Only Docker may run through sudo; service and package commands fail.
  printf 'sudo %s\n' "$*" >>"$FAKE_STATE/calls"
  [[ "$1" == docker ]] || return 1
  shift
  FAKE_SUDO=1 docker "$@"
}
docker() {
  local arg last="${*: -1}" record="$FAKE_STATE/docker-run" workspace=''
  if [[ "$FAKE_DOCKER_NEEDS_SUDO" == 1 && "${FAKE_SUDO:-0}" != 1 ]]; then
    return 1
  fi
  case "$1 ${2:-}" in
    'info '*|'buildx version') return 0 ;;
    'image inspect')
      if [[ "$3" == --format ]]; then printf 'sha256:fake-builder\n'; fi
      return 0
      ;;
    'run '*) ;;
    *) return 81 ;;
  esac
  printf 'sudo=%s\nlast=%s\n' "${FAKE_SUDO:-0}" "$last" >"$record"
  while (($#)); do
    arg="$1"
    shift
    case "$arg" in
      -e) printf '%s\n' "$1" >>"$record"; shift ;;
      -v)
        printf 'mount=%s\n' "$1" >>"$record"
        if [[ "$1" == *:/build ]]; then workspace="${1%:/build}"; fi
        shift
        ;;
    esac
  done
  [[ -n "$workspace" ]] || return 82
  mkdir -p "$workspace/output" "$workspace/reports"
  printf 'firmware\n' >"$workspace/output/firmware.bin"
  (cd "$workspace/output" && sha256sum firmware.bin >sha256sums.txt)
  printf 'summary\n' >"$workspace/reports/build-summary.txt"
  return "$FAKE_DOCKER_RUN_STATUS"
}
export -f fake_remote_path ssh scp sleep tmux sudo docker

run_case() {
  local name="$1" expected_status="$2" actual_status=0
  export FAKE_DOCKER_NEEDS_SUDO="$3" FAKE_DOCKER_RUN_STATUS="$4"
  shift 4
  export FAKE_STATE="$tmp_root/$name"
  session="$session_prefix-$name"
  remote_root="$FAKE_STATE/remote"
  artifacts="$FAKE_STATE/artifacts"
  mkdir -p "$FAKE_STATE"
  : >"$FAKE_STATE/calls"
  GHCR_TOKEN='' SSH_CONFIG_FILE='' TMPDIR="$tmp_root" \
    "$fixture/scripts/orchestrate-ec2-build.sh" --session "$session" \
    --remote-root "$remote_root" --fetch-artifacts "$artifacts" \
    "$@" fake-host locks/test.lock >"$FAKE_STATE/output" 2>&1 || actual_status=$?
  [[ "$actual_status" == "$expected_status" ]] ||
    die "$name: expected exit $expected_status, got $actual_status; see output below
$(cat "$FAKE_STATE/output")"
}

expect_run() {
  grep -Fqx -- "$1" "$FAKE_STATE/docker-run" || die "$name: container run lacked $1"
}

for mode in docker sudo; do
  name="$mode"
  needs_sudo=0
  if [[ "$mode" == sudo ]]; then needs_sudo=1; fi
  run_case "$name" 0 "$needs_sudo" 0 --platform linux/arm64 --make-jobs 7 --no-strict-manifest
  [[ -f "$artifacts/firmware.bin" && -f "$artifacts/sha256sums.txt" &&
    -f "$artifacts/reports/build-summary.txt" && -f "$artifacts/logs/ec2-build.log" ]] ||
    die "$name: fetch did not publish output, reports, and log"
  grep -Fq 'Artifact directory:' "$artifacts/logs/ec2-build.log" ||
    die "$name: remote log does not show the local wrapper's build"
  expect_run "sudo=$needs_sudo"
  expect_run 'last=locks/test.lock'
  expect_run "BUILD_ID=$session"
  expect_run "WORKSPACE_ID=$session"
  expect_run 'FRESH=1'
  expect_run 'USE_CCACHE=0'
  expect_run 'STRICT_MANIFEST=0'
  expect_run 'BUILDER_PLATFORM=linux/arm64'
  expect_run 'MAKE_JOBS=7'
  expect_run "mount=$remote_root/runs/$session/repo/build/$session:/build"
  expect_run "mount=$remote_root/cache:/cache"
  [[ "$(cat "$remote_root/runs/$session/build.exit")" == 0 ]] ||
    die "$name: launcher did not record the build status"
done
if grep -q '^sudo ' "$tmp_root/docker/calls"; then
  die 'usable Docker still went through sudo'
fi
grep -Fqx 'sudo docker info' "$tmp_root/sudo/calls" ||
  die 'sudo Docker mode was not selected'

run_case failed-build 3 0 3
[[ -f "$artifacts/firmware.bin" && -f "$artifacts/logs/ec2-build.log" ]] ||
  die 'failed build did not publish available output and log'
[[ "$(cat "$remote_root/runs/$session/build.exit")" == 3 ]] ||
  die 'launcher did not record the failed build status'
