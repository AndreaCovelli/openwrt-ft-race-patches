#!/usr/bin/env bash
set -euo pipefail

umask 022
export PATH="$HOME/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"

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
  --session NAME            Build/session name. Default: <lock-stem>-<utc>.
  --artifact-dir DIR        Local artifact output. Default:
                            ./openwrt-artifacts/<session>.
  --make-jobs N             Pass through to orchestrate-ec2-build.sh.
  --download-jobs N         Pass through to orchestrate-ec2-build.sh.
  --strict-manifest         Pass through. Default behavior.
  --no-strict-manifest      Pass through.
  --include-untracked       Pass through.
  --platform PLATFORM       Docker platform. Default: linux/amd64.
  --builder-base-image REF  Docker base image override.
  --ubuntu-snapshot TS      Ubuntu apt snapshot override.
  --remote-root PATH        Remote workspace root.
  --keep-instance           Do not terminate/delete EC2 resources on exit.
  --help                    Show this message.

The script creates a temporary SSH-only security group restricted to this
client's public IP, launches the builder, runs the existing orchestrator through
a temporary SSH config file, then terminates the instance and deletes the
security group unless --keep-instance is set.
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
MAKE_JOBS=''
DOWNLOAD_JOBS=''
STRICT_ARG=()
INCLUDE_UNTRACKED='0'
BUILDER_PLATFORM='linux/amd64'
BUILDER_BASE_IMAGE=''
UBUNTU_SNAPSHOT=''
REMOTE_ROOT=''
KEEP_INSTANCE='0'

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

LOCK_FILE_REL="${LOCK_FILE#"$REPO_ROOT"/}"
LOCK_STEM="$(basename "$LOCK_FILE_REL" .lock)"
if [[ -z "$SESSION_NAME" ]]; then
  SESSION_NAME="${LOCK_STEM}-$(date -u '+%Y%m%dT%H%M%SZ')"
fi
if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="$REPO_ROOT/openwrt-artifacts/$SESSION_NAME"
fi
if [[ -z "$KEY_FILE" ]]; then
  KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
fi
[[ -f "$KEY_FILE" ]] || die "private key file not found: $KEY_FILE"

require_cmd aws curl date mktemp ssh

AWS_CMD=(aws)
if [[ -n "$AWS_REGION" ]]; then
  AWS_CMD+=(--region "$AWS_REGION")
fi

SECURITY_GROUP_ID=''
INSTANCE_ID=''
SSH_CONFIG_FILE=''

cleanup() {
  local status=$?
  set +e

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
      aws_ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1
      aws_ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" >/dev/null 2>&1
    fi
    if [[ -n "$SECURITY_GROUP_ID" ]]; then
      log "Deleting EC2 security group: $SECURITY_GROUP_ID"
      aws_ec2 delete-security-group --group-id "$SECURITY_GROUP_ID" >/dev/null 2>&1
    fi
  fi

  if [[ -n "$SSH_CONFIG_FILE" ]]; then
    rm -f "$SSH_CONFIG_FILE"
  fi

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

CLIENT_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
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

INSTANCE_ID="$(aws_ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --block-device-mappings "DeviceName=${ROOT_DEVICE},Ebs={VolumeSize=${VOLUME_SIZE},VolumeType=gp3,DeleteOnTermination=true}" \
  --instance-initiated-shutdown-behavior terminate \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$RUN_NAME},{Key=Purpose,Value=openwrt-ft-build}]" "ResourceType=volume,Tags=[{Key=Name,Value=$RUN_NAME-root},{Key=Purpose,Value=openwrt-ft-build}]" \
  --query 'Instances[0].InstanceId' \
  --output text)"
log "Launched EC2 builder: $INSTANCE_ID"

aws_ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP="$(aws_ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)"
[[ "$PUBLIC_IP" != 'None' && -n "$PUBLIC_IP" ]] || die "builder has no public IP"

SSH_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/openwrt-ft-ssh.XXXXXXXX")"
cat >"$SSH_CONFIG_FILE" <<EOF
Host openwrt-ft-ec2-builder
    HostName $PUBLIC_IP
    User ubuntu
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ConnectTimeout 10
EOF

log "Waiting for EC2 status checks"
aws_ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

log "Waiting for SSH on $PUBLIC_IP"
ssh_ready='0'
for _ in $(seq 1 60); do
  if ssh -F "$SSH_CONFIG_FILE" -o BatchMode=yes openwrt-ft-ec2-builder 'true' >/dev/null 2>&1; then
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
SSH_CONFIG_FILE="$SSH_CONFIG_FILE" "$SCRIPT_DIR/orchestrate-ec2-build.sh" \
  "${orchestrator_args[@]}" \
  openwrt-ft-ec2-builder \
  "$LOCK_FILE_REL"
build_status=$?
set -e

exit "$build_status"
