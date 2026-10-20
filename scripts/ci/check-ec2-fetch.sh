#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-ec2-fetch.XXXXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
fixture="$tmp_root/repo"
mkdir -p "$fixture/scripts/lib" "$fixture/locks"
cp "$repo_root/scripts/orchestrate-ec2-build.sh" "$fixture/scripts/"
cp "$repo_root/scripts/lib/"{build-name,build-wrapper,builder-image,prebuilt-apks}.sh "$fixture/scripts/lib/"
: >"$fixture/locks/test.lock"
git -C "$fixture" init -q
git -C "$fixture" add scripts locks

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Exported Bash functions survive the orchestrator's PATH handling. They model
# the remote host under $FAKE_REMOTE_ROOT; nothing here contacts a real host.
ssh() {
  local input path code
  input="$(cat)"
  case "$input" in
    *'install_prereqs='*)
      printf 'remote_root=/fake/remote\ncache_dir=/fake/remote/cache\n'
      ;;
    *'tmux new-session'*)
      printf 'run_root=/fake/remote/runs/s\n'
      printf 'repo_dir=/fake/remote/runs/s/repo\n'
      printf 'log_file=/fake/remote/logs/build.log\n'
      printf 'artifact_dir=/fake/remote/out/output\n'
      printf 'status_file=/fake/remote/status\n'
      printf 'session=s\ntmux_session=s\n'
      ;;
    *'tar -xzf'*)
      ;;
    *'tmux has-session'*)
      read -r code <"$FAKE_STATE/polls" || code=1
      sed -i '1d' "$FAKE_STATE/polls"
      printf 'poll %s\n' "$code" >>"$FAKE_STATE/calls"
      return "$code"
      ;;
    *'cat "$1"'*)
      cat "$FAKE_REMOTE_ROOT/status"
      ;;
    *'[[ -d "$1" ]]'*)
      path="${*: -1}"
      [[ -d "$FAKE_REMOTE_ROOT/${path#/fake/remote/}" ]]
      ;;
    *)
      printf 'unexpected fake ssh script\n' >&2
      return 81
      ;;
  esac
}
scp() {
  local src="${*: -2:1}" dest="${*: -1}" path
  case "$src" in
    fake-host:*)
      path="${src#fake-host:/fake/remote/}"
      if [[ "$path" == */. ]]; then
        cp -a "$FAKE_REMOTE_ROOT/${path%/.}/." "$dest"
      else
        cp "$FAKE_REMOTE_ROOT/$path" "$dest"
      fi
      ;;
    *)
      [[ "$dest" == fake-host:* ]] || return 81
      ;;
  esac
}
sleep() { printf 'sleep\n' >>"$FAKE_STATE/calls"; }
export -f ssh scp sleep

run_case() {
  local name="$1" expected_status="$2" polls="$3" build_status="$4" actual_status=0
  shift 4
  export FAKE_STATE="$tmp_root/$name"
  export FAKE_REMOTE_ROOT="$FAKE_STATE/remote"
  mkdir -p "$FAKE_REMOTE_ROOT/out/output" "$FAKE_REMOTE_ROOT/out/reports" "$FAKE_REMOTE_ROOT/logs"
  printf 'firmware\n' >"$FAKE_REMOTE_ROOT/out/output/firmware.bin"
  (cd "$FAKE_REMOTE_ROOT/out/output" && sha256sum firmware.bin >sha256sums.txt)
  printf 'summary\n' >"$FAKE_REMOTE_ROOT/out/reports/build-summary.txt"
  printf 'log\n' >"$FAKE_REMOTE_ROOT/logs/build.log"
  printf '%s\n' "$build_status" >"$FAKE_REMOTE_ROOT/status"
  tr ' ' '\n' <<<"$polls" >"$FAKE_STATE/polls"
  : >"$FAKE_STATE/calls"
  artifacts="$FAKE_STATE/artifacts"
  if [[ -n "${FAKE_PRECREATE:-}" ]]; then
    mkdir -p "$artifacts"
  fi
  if [[ -n "${FAKE_CORRUPT:-}" ]]; then
    printf 'corrupt\n' >"$FAKE_REMOTE_ROOT/out/output/firmware.bin"
  fi
  GHCR_TOKEN='' "$fixture/scripts/orchestrate-ec2-build.sh" --session s \
    --fetch-artifacts "$artifacts" "$@" fake-host locks/test.lock \
    >"$FAKE_STATE/output" 2>&1 || actual_status=$?
  [[ "$actual_status" == "$expected_status" ]] ||
    die "$name: expected exit $expected_status, got $actual_status; see output below
$(cat "$FAKE_STATE/output")"
}

run_case success 0 '0 255 255 0 1' 0
[[ -f "$artifacts/firmware.bin" && -f "$artifacts/reports/build-summary.txt" &&
  -f "$artifacts/logs/ec2-build.log" ]] || die 'successful fetch did not publish output, reports, and log'
grep -Fq 'SSH poll failed (2/20)' "$FAKE_STATE/output" || die 'transient poll failures were not reported'
if compgen -G "$FAKE_STATE/.openwrt-ft-artifacts.*" >/dev/null; then
  die 'successful fetch left a staging directory'
fi

FAKE_CORRUPT=1 run_case corrupt 1 '1' 0
[[ ! -e "$artifacts" ]] || die 'corrupt artifacts were published'
grep -Fq 'unpublished artifact copy kept at' "$FAKE_STATE/output" ||
  die 'checksum failure did not report the staged copy'

run_case lost-ssh 1 "$(printf '255 %.0s' {1..20})" 0
grep -Fq 'lost SSH to fake-host' "$FAKE_STATE/output" || die 'persistent SSH loss was not reported'
[[ "$(grep -c '^poll 255$' "$FAKE_STATE/calls")" == 20 ]] || die 'SSH loss polling was not bounded'

run_case failed-build 2 '1' 2
[[ -f "$artifacts/logs/ec2-build.log" && -f "$artifacts/firmware.bin" ]] ||
  die 'failed build did not publish available output and log'

FAKE_PRECREATE=1 run_case existing-destination 1 '1' 0
grep -Fq 'artifact directory already exists' "$FAKE_STATE/output" ||
  die 'existing artifact destination was not rejected'
if grep -q . "$FAKE_STATE/calls"; then
  die 'existing artifact destination was detected after contacting the host'
fi
