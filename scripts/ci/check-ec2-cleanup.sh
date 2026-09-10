#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-ec2-cleanup.XXXXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
fixture="$tmp_root/repo"
mkdir -p "$fixture/scripts/lib" "$fixture/locks"
cp "$repo_root/scripts/run-ec2-build.sh" "$fixture/scripts/"
cp "$repo_root/scripts/lib/build-name.sh" "$fixture/scripts/lib/"
: >"$fixture/locks/test.lock"
: >"$tmp_root/fake-key"
cat >"$fixture/scripts/orchestrate-ec2-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$PATH" == "$FAKE_HOST_PATH" ]] || exit 82
printf 'build\n' >>"$FAKE_EC2_STATE/calls"
exit "$FAKE_BUILD_STATUS"
EOF
chmod +x "$fixture/scripts/orchestrate-ec2-build.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Exported Bash functions survive the wrapper's PATH sanitization. None of
# these fixtures invoke AWS, curl, SSH, the real orchestrator, or a real sleep.
aws() {
  local operation count=0
  [[ "${1:-}" == '--region' && "${2:-}" == 'test-region' ]] || return 81
  shift 2
  [[ "${1:-}" == 'ec2' ]] || return 81
  shift
  operation="$1"
  if [[ "$1" == wait ]]; then operation="$2"; fi
  printf '%s\n' "$operation" >>"$FAKE_EC2_STATE/calls"
  case "$operation" in
    terminate-instances|instance-terminated|delete-security-group)
      if [[ -f "$FAKE_EC2_STATE/$operation.count" ]]; then
        read -r count <"$FAKE_EC2_STATE/$operation.count"
      fi
      count=$((count + 1))
      printf '%s\n' "$count" >"$FAKE_EC2_STATE/$operation.count"
      if [[ "$FAKE_FAIL_OPERATION" == "$operation" || "$FAKE_FAIL_OPERATION" == all ]] &&
        ((count <= FAKE_FAIL_COUNT)); then
        printf 'simulated AWS failure: %s\n' "$operation" >&2
        return 42
      fi
      ;;
    describe-images) printf '/dev/sda1\n' ;;
    create-security-group) printf 'sg-test\n' ;;
    run-instances) printf 'i-test\n' ;;
    describe-instances) printf '198.51.100.10\n' ;;
    authorize-security-group-ingress)
      if [[ "$FAKE_FAIL_OPERATION" == provisioning ]]; then return 43; fi
      ;;
    instance-running|instance-status-ok) ;;
    *) return 81 ;;
  esac
}
curl() {
  [[ "${*: -1}" == 'https://checkip.amazonaws.com' ]] || return 81
  printf '198.51.100.20\n'
}
ssh() { return 0; }
sleep() { printf 'retry-delay\n' >>"$FAKE_EC2_STATE/calls"; }
export -f aws curl ssh sleep
export FAKE_HOST_PATH="$tmp_root/host-bin:$PATH"

run_case() {
  local name="$1" expected_status="$2" actual_status=0
  export FAKE_FAIL_OPERATION="$3" FAKE_FAIL_COUNT="$4" FAKE_BUILD_STATUS="$5"
  shift 5
  export FAKE_EC2_STATE="$tmp_root/$name"
  mkdir -p "$FAKE_EC2_STATE"
  PATH="$FAKE_HOST_PATH" "$fixture/scripts/run-ec2-build.sh" --region test-region \
    --key-file "$tmp_root/fake-key" --session test-cleanup \
    --ami-id ami-test --vpc-id vpc-test --subnet-id subnet-test \
    "$@" locks/test.lock >"$FAKE_EC2_STATE/output" 2>&1 || actual_status=$?
  [[ "$actual_status" == "$expected_status" ]] ||
    die "$name: expected exit $expected_status, got $actual_status"
}

run_case success 0 none 0 0
for operation in terminate-instances instance-terminated delete-security-group; do
  [[ "$(cat "$FAKE_EC2_STATE/$operation.count")" == 1 ]] || die 'successful cleanup repeated a command'
done

run_case transient 0 all 2 0
for operation in terminate-instances instance-terminated delete-security-group; do
  [[ "$(cat "$FAKE_EC2_STATE/$operation.count")" == 3 ]] || die 'transient cleanup failure was not retried'
done
if grep -Fq 'cleanup incomplete' "$FAKE_EC2_STATE/output"; then die 'successful retry reported incomplete cleanup'; fi

for operation in terminate-instances instance-terminated delete-security-group; do
  run_case "$operation" 1 "$operation" 99 0
  [[ "$(cat "$FAKE_EC2_STATE/$operation.count")" == 3 ]] || die 'cleanup retries were not bounded'
  grep -Fq 'simulated AWS failure' "$FAKE_EC2_STATE/output" || die 'AWS cleanup diagnostics were hidden'
  grep -Fq 'instance=i-test security-group=sg-test region=test-region' "$FAKE_EC2_STATE/output" ||
    die 'failed cleanup did not identify resources for manual recovery'
  [[ -f "$FAKE_EC2_STATE/delete-security-group.count" ]] || die 'instance cleanup failure skipped security group cleanup'
done

run_case failed-build 17 none 0 17
run_case failed-build-and-cleanup 17 all 99 17
grep -Fq 'cleanup incomplete' "$FAKE_EC2_STATE/output" || die 'build failure hid cleanup failure'

run_case provisioning-failure 43 provisioning 0 0
[[ -f "$FAKE_EC2_STATE/delete-security-group.count" && ! -f "$FAKE_EC2_STATE/terminate-instances.count" ]] ||
  die 'partial provisioning did not clean up only the created resources'

run_case keep-instance 0 all 99 0 --keep-instance
if grep -Eq '^(terminate-instances|instance-terminated|delete-security-group)$' "$FAKE_EC2_STATE/calls"; then
  die '--keep-instance cleaned up retained resources'
fi
