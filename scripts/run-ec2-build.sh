#!/usr/bin/env bash
set -euo pipefail

umask 022
HOST_PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH="$HOME/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/build-name.sh
source "$SCRIPT_DIR/lib/build-name.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-ec2-build.sh [options] <lock-file>

Options:
  --region REGION           AWS region. Default: AWS CLI configured region.
  --key-name NAME           EC2 key pair name. Default: EC2-wslDesktop.
  --key-file PATH           Private key path. Default: ~/.ssh/<key-name>.pem.
  --instance-type TYPE      Builder instance type. Default: c8a.xlarge.
  --volume-size GIB         Root EBS gp3 volume size. Default: 30.
  --ami-id AMI              Ubuntu AMI override. Default: latest Noble amd64.
  --vpc-id VPC              VPC override. Default: default VPC.
  --subnet-id SUBNET        Subnet override. Default: public default subnet
                            in an AZ offering the selected instance type.
  --session NAME            Build/session name. Default:
                            openwrt-ft-<device-id>-<openwrt-version>-<variant>-<utc>.
  --artifact-dir DIR        New local artifact output (must not exist).
                            Default: ./openwrt-artifacts/<session>.
  --builder-image REF       Prebuilt Docker builder image passed through.
  --rebuild-builder-image   Build docker/Dockerfile.ec2 on the remote host
                            instead of pulling the prebuilt builder image.
  --make-jobs N             Pass through to orchestrate-ec2-build.sh.
  --download-jobs N         Pass through to orchestrate-ec2-build.sh.
  --strict-manifest         Pass through. Default behavior.
  --no-strict-manifest      Pass through.
  --include-untracked       Pass through.
  --platform PLATFORM       Docker platform. Default: linux/amd64.
  --builder-base-image REF  Docker base image override.
  --ubuntu-snapshot TS      Ubuntu apt snapshot override.
  --remote-root PATH        Remote workspace root.
  --on-demand               Launch an on-demand instance. Default: request a
                            one-time spot instance and fall back to on-demand
                            when spot capacity is unavailable.
  --max-runtime-minutes N   Shut down, and so terminate, the instance N
                            minutes after boot even if this client disappears.
                            Applies with --keep-instance too. 0 disables.
                            Default: 360.
  --keep-instance           Do not terminate/delete EC2 resources on exit.
  --help                    Show this message.

The script creates a temporary SSH-only security group restricted to this
client's public IP, launches the builder, runs the existing orchestrator through
a temporary SSH config file, then terminates the instance and deletes the
security group unless --keep-instance is set. Boot-time user data installs tmux
and Docker while SSH comes up and arms the maximum-runtime shutdown.
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

aws_ec2() {
  "${AWS_CMD[@]}" ec2 "$@"
}

abs_repo_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$path"
  fi
}

KEY_NAME="${EC2_KEY_NAME:-EC2-wslDesktop}"
KEY_FILE=''
INSTANCE_TYPE='c8a.xlarge'
VOLUME_SIZE='30'
AMI_ID=''
VPC_ID=''
SUBNET_ID=''
AWS_REGION="${AWS_REGION:-}"
SESSION_NAME=''
ARTIFACT_DIR=''
BUILDER_IMAGE=''
REBUILD_BUILDER_IMAGE='0'
MAKE_JOBS=''
DOWNLOAD_JOBS=''
STRICT_ARG=()
INCLUDE_UNTRACKED='0'
BUILDER_PLATFORM='linux/amd64'
BUILDER_BASE_IMAGE=''
UBUNTU_SNAPSHOT=''
REMOTE_ROOT=''
KEEP_INSTANCE='0'
MARKET_TYPE='spot'
MAX_RUNTIME_MINUTES='360'

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 ]] || die "--region requires a value"
      AWS_REGION="$2"
      shift 2
      ;;
    --key-name)
      [[ $# -ge 2 ]] || die "--key-name requires a value"
      KEY_NAME="$2"
      shift 2
      ;;
    --key-file)
      [[ $# -ge 2 ]] || die "--key-file requires a value"
      KEY_FILE="$2"
      shift 2
      ;;
    --instance-type)
      [[ $# -ge 2 ]] || die "--instance-type requires a value"
      INSTANCE_TYPE="$2"
      shift 2
      ;;
    --volume-size)
      [[ $# -ge 2 ]] || die "--volume-size requires a value"
      VOLUME_SIZE="$2"
      shift 2
      ;;
    --ami-id)
      [[ $# -ge 2 ]] || die "--ami-id requires a value"
      AMI_ID="$2"
      shift 2
      ;;
    --vpc-id)
      [[ $# -ge 2 ]] || die "--vpc-id requires a value"
      VPC_ID="$2"
      shift 2
      ;;
    --subnet-id)
      [[ $# -ge 2 ]] || die "--subnet-id requires a value"
      SUBNET_ID="$2"
      shift 2
      ;;
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
      STRICT_ARG=(--strict-manifest)
      shift
      ;;
    --no-strict-manifest)
      STRICT_ARG=(--no-strict-manifest)
      shift
      ;;
    --include-untracked)
      INCLUDE_UNTRACKED='1'
      shift
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
    --remote-root)
      [[ $# -ge 2 ]] || die "--remote-root requires a value"
      REMOTE_ROOT="$2"
      shift 2
      ;;
    --keep-instance)
      KEEP_INSTANCE='1'
      shift
      ;;
    --on-demand)
      MARKET_TYPE='on-demand'
      shift
      ;;
    --max-runtime-minutes)
      [[ $# -ge 2 ]] || die "--max-runtime-minutes requires a value"
      MAX_RUNTIME_MINUTES="$2"
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

case "$SESSION_NAME" in
  *[!A-Za-z0-9._-]*)
    die "session name contains unsupported characters: $SESSION_NAME"
    ;;
esac

case "$VOLUME_SIZE" in
  ''|*[!0-9]*) die "--volume-size must be an integer GiB value" ;;
esac

case "$MAX_RUNTIME_MINUTES" in
  ''|*[!0-9]*) die "--max-runtime-minutes must be a non-negative integer" ;;
esac

LOCK_FILE_REL="${LOCK_FILE#"$REPO_ROOT"/}"

if [[ -z "$SESSION_NAME" ]]; then
  SESSION_NAME="$(openwrt_default_build_name_from_lock "$LOCK_FILE")"
fi
if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="$REPO_ROOT/openwrt-artifacts/$SESSION_NAME"
fi
ARTIFACT_DIR="$(abs_repo_path "$ARTIFACT_DIR")"
# Fail before paying for an instance whose artifacts could not be published.
[[ ! -e "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] ||
  die "artifact directory already exists: $ARTIFACT_DIR"
if [[ -z "$KEY_FILE" ]]; then
  KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
fi
[[ -f "$KEY_FILE" ]] || die "private key file not found: $KEY_FILE"

require_cmd aws curl date mktemp seq ssh

AWS_CMD=(aws)
if [[ -n "$AWS_REGION" ]]; then
  AWS_CMD+=(--region "$AWS_REGION")
fi

SECURITY_GROUP_ID=''
INSTANCE_ID=''
INSTANCE_MARKET=''
SSH_HOST_ALIAS='openwrt-ft-ec2-builder'
# Holds the SSH config, per-run known_hosts, control socket, and user data.
RUN_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-ft-ec2.XXXXXXXX")"
SSH_CONFIG_FILE="$RUN_TMP_DIR/ssh_config"
USER_DATA_FILE="$RUN_TMP_DIR/user-data.sh"

retry_ec2_cleanup() {
  local attempt
  for attempt in 1 2 3; do
    if aws_ec2 "$@" >/dev/null; then
      return 0
    fi
    printf 'warning: EC2 cleanup attempt %s/3 failed: %s\n' "$attempt" "$*" >&2
    if ((attempt < 3)); then
      sleep 2
    fi
  done
  return 1
}

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  set +e

  if [[ -f "$SSH_CONFIG_FILE" ]]; then
    ssh -F "$SSH_CONFIG_FILE" -O exit "$SSH_HOST_ALIAS" >/dev/null 2>&1
  fi

  if [[ "$KEEP_INSTANCE" == '1' ]]; then
    if [[ -n "$INSTANCE_ID" ]]; then
      log "Keeping EC2 instance: $INSTANCE_ID"
    fi
    if [[ -n "$SECURITY_GROUP_ID" ]]; then
      log "Keeping EC2 security group: $SECURITY_GROUP_ID"
    fi
  else
    if [[ -n "$INSTANCE_ID" ]]; then
      log "Terminating EC2 builder: $INSTANCE_ID"
      if retry_ec2_cleanup terminate-instances --instance-ids "$INSTANCE_ID"; then
        retry_ec2_cleanup wait instance-terminated --instance-ids "$INSTANCE_ID" || cleanup_failed=1
      else
        cleanup_failed=1
      fi
    fi
    if [[ -n "$SECURITY_GROUP_ID" ]]; then
      log "Deleting EC2 security group: $SECURITY_GROUP_ID"
      retry_ec2_cleanup delete-security-group --group-id "$SECURITY_GROUP_ID" || cleanup_failed=1
    fi
    if ((cleanup_failed)); then
      printf 'error: EC2 cleanup incomplete; check instance=%s security-group=%s region=%s manually\n' \
        "${INSTANCE_ID:-none}" "${SECURITY_GROUP_ID:-none}" "${AWS_REGION:-AWS CLI default}" >&2
      if ((status == 0)); then
        status=1
      fi
    fi
  fi

  rm -rf -- "$RUN_TMP_DIR"

  exit "$status"
}
trap cleanup EXIT

if [[ -z "$VPC_ID" ]]; then
  VPC_ID="$(aws_ec2 describe-vpcs \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text)"
  [[ "$VPC_ID" != 'None' && -n "$VPC_ID" ]] || die "no default VPC found; pass --vpc-id"
fi

if [[ -z "$AMI_ID" ]]; then
  log "Discovering latest Ubuntu Noble amd64 AMI"
  AMI_ID="$(aws_ec2 describe-images \
    --owners 099720109477 \
    --filters \
      Name=name,Values='ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
      Name=architecture,Values=x86_64 \
      Name=virtualization-type,Values=hvm \
      Name=root-device-type,Values=ebs \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
    --output text)"
  [[ "$AMI_ID" != 'None' && -n "$AMI_ID" ]] || die "failed to discover Ubuntu Noble AMI"
fi

ROOT_DEVICE="$(aws_ec2 describe-images \
  --image-ids "$AMI_ID" \
  --query 'Images[0].RootDeviceName' \
  --output text)"
[[ "$ROOT_DEVICE" != 'None' && -n "$ROOT_DEVICE" ]] || die "failed to discover AMI root device"

if [[ -z "$SUBNET_ID" ]]; then
  log "Selecting public subnet offering $INSTANCE_TYPE"
  offerings="$(aws_ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters Name=instance-type,Values="$INSTANCE_TYPE" \
    --query 'InstanceTypeOfferings[].Location' \
    --output text | tr '\t' ' ')"

  while read -r subnet_az subnet_id; do
    [[ -n "$subnet_az" && -n "$subnet_id" ]] || continue
    case " $offerings " in
      *" $subnet_az "*)
        SUBNET_ID="$subnet_id"
        break
        ;;
    esac
  done < <(aws_ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'Subnets[?MapPublicIpOnLaunch==`true`].[AvailabilityZone,SubnetId]' \
    --output text)

  [[ -n "$SUBNET_ID" ]] || die "no public subnet in $VPC_ID offers $INSTANCE_TYPE; pass --subnet-id"
fi

CLIENT_IP="$(curl --connect-timeout 10 --max-time 30 -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ "$CLIENT_IP" == *.* ]] || die "failed to determine client public IPv4 address"

RUN_NAME="openwrt-ft-build-$SESSION_NAME"
SECURITY_GROUP_ID="$(aws_ec2 create-security-group \
  --group-name "$RUN_NAME" \
  --description "Temporary SSH access for $RUN_NAME" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$RUN_NAME},{Key=Purpose,Value=openwrt-ft-build}]" \
  --query GroupId \
  --output text)"
log "Created security group: $SECURITY_GROUP_ID"

aws_ec2 authorize-security-group-ingress \
  --group-id "$SECURITY_GROUP_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${CLIENT_IP}/32,Description=builder-ssh}]" \
  >/dev/null

{
  printf '#!/bin/bash\n'
  printf '# Generated by run-ec2-build.sh for %s.\n' "$RUN_NAME"
  if ((MAX_RUNTIME_MINUTES > 0)); then
    # The instance shuts down into termination, so this bounds cost even if
    # the client loses its connection before cleanup runs.
    printf "shutdown -h +%s 'openwrt-ft builder maximum runtime reached'\n" "$MAX_RUNTIME_MINUTES"
  fi
  cat <<'USERDATA'
export DEBIAN_FRONTEND=noninteractive
if apt-get update; then
  apt-get install -y tmux docker.io || true
  apt-get install -y docker-buildx || true
fi
systemctl enable --now docker || true
USERDATA
} >"$USER_DATA_FILE"

# AWS shorthand values contain commas inside single arguments.
# shellcheck disable=SC2054
run_instance_args=(
  --image-id "$AMI_ID"
  --instance-type "$INSTANCE_TYPE"
  --key-name "$KEY_NAME"
  --subnet-id "$SUBNET_ID"
  --security-group-ids "$SECURITY_GROUP_ID"
  --block-device-mappings "DeviceName=${ROOT_DEVICE},Ebs={VolumeSize=${VOLUME_SIZE},VolumeType=gp3,DeleteOnTermination=true}"
  --instance-initiated-shutdown-behavior terminate
  --metadata-options HttpTokens=required,HttpEndpoint=enabled
  --user-data "file://$USER_DATA_FILE"
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$RUN_NAME},{Key=Purpose,Value=openwrt-ft-build}]" "ResourceType=volume,Tags=[{Key=Name,Value=$RUN_NAME-root},{Key=Purpose,Value=openwrt-ft-build}]"
  --query 'Instances[0].InstanceId'
  --output text
)

if [[ "$MARKET_TYPE" == 'spot' ]]; then
  log "Requesting spot EC2 builder: $INSTANCE_TYPE"
  spot_error_file="$RUN_TMP_DIR/spot-error"
  if INSTANCE_ID="$(aws_ec2 run-instances "${run_instance_args[@]}" \
    --instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}' \
    2>"$spot_error_file")"; then
    INSTANCE_MARKET='spot'
  else
    INSTANCE_ID=''
    log "Spot request failed; falling back to on-demand: $(tr '\n' ' ' <"$spot_error_file")"
  fi
fi
if [[ -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID="$(aws_ec2 run-instances "${run_instance_args[@]}")"
  INSTANCE_MARKET='on-demand'
fi
log "Launched $INSTANCE_MARKET EC2 builder: $INSTANCE_ID"
if ((MAX_RUNTIME_MINUTES > 0)); then
  log "Builder terminates itself after $MAX_RUNTIME_MINUTES minutes"
fi

aws_ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP="$(aws_ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)"
[[ "$PUBLIC_IP" != 'None' && -n "$PUBLIC_IP" ]] || die "builder has no public IP"

# A per-run known_hosts keeps recycled EC2 addresses from colliding with old
# host keys. Keepalives detect dead links; one shared connection avoids a new
# handshake for every orchestrator poll and copy.
cat >"$SSH_CONFIG_FILE" <<EOF
Host $SSH_HOST_ALIAS
    HostName $PUBLIC_IP
    User ubuntu
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile $RUN_TMP_DIR/known_hosts
    ConnectTimeout 10
    ServerAliveInterval 30
    ServerAliveCountMax 6
    ControlMaster auto
    ControlPath $RUN_TMP_DIR/%C
    ControlPersist 10m
EOF

# SSH answers before the slower EC2 status checks pass, so poll SSH directly.
log "Waiting for SSH on $PUBLIC_IP"
ssh_ready='0'
for _ in $(seq 1 90); do
  if ssh -F "$SSH_CONFIG_FILE" -o BatchMode=yes "$SSH_HOST_ALIAS" 'true' >/dev/null 2>&1; then
    ssh_ready='1'
    break
  fi
  sleep 5
done
[[ "$ssh_ready" == '1' ]] || die "builder SSH did not become ready"

orchestrator_args=(
  --session "$SESSION_NAME"
  --platform "$BUILDER_PLATFORM"
  --fetch-artifacts "$ARTIFACT_DIR"
)
if [[ -n "$REMOTE_ROOT" ]]; then
  orchestrator_args+=(--remote-root "$REMOTE_ROOT")
fi
if [[ -n "$BUILDER_IMAGE" ]]; then
  orchestrator_args+=(--builder-image "$BUILDER_IMAGE")
fi
if [[ "$REBUILD_BUILDER_IMAGE" == '1' ]]; then
  orchestrator_args+=(--rebuild-builder-image)
fi
if [[ -n "$MAKE_JOBS" ]]; then
  orchestrator_args+=(--make-jobs "$MAKE_JOBS")
fi
if [[ -n "$DOWNLOAD_JOBS" ]]; then
  orchestrator_args+=(--download-jobs "$DOWNLOAD_JOBS")
fi
if [[ -n "$BUILDER_BASE_IMAGE" ]]; then
  orchestrator_args+=(--builder-base-image "$BUILDER_BASE_IMAGE")
fi
if [[ -n "$UBUNTU_SNAPSHOT" ]]; then
  orchestrator_args+=(--ubuntu-snapshot "$UBUNTU_SNAPSHOT")
fi
if [[ ${#STRICT_ARG[@]} -gt 0 ]]; then
  orchestrator_args+=("${STRICT_ARG[@]}")
fi
if [[ "$INCLUDE_UNTRACKED" == '1' ]]; then
  orchestrator_args+=(--include-untracked)
fi

log "Starting EC2 OpenWrt build"
set +e
PATH="$HOST_PATH" SSH_CONFIG_FILE="$SSH_CONFIG_FILE" "$SCRIPT_DIR/orchestrate-ec2-build.sh" \
  "${orchestrator_args[@]}" \
  "$SSH_HOST_ALIAS" \
  "$LOCK_FILE_REL"
build_status=$?
set -e

if ((build_status != 0)); then
  state_reason="$(aws_ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].StateReason.Code' \
    --output text 2>/dev/null || true)"
  case "$state_reason" in
    *Spot*)
      log "EC2 reclaimed the spot builder ($state_reason); rerun, or pass --on-demand"
      ;;
    *InstanceInitiatedShutdown*)
      log "Builder shut itself down ($state_reason); raise --max-runtime-minutes if the build needs longer"
      ;;
  esac
fi

exit "$build_status"
