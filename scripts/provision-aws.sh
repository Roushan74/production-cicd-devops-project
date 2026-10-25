#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Provision the AWS resources for this project (idempotent).
#
# Creates, if they do not already exist:
#   * a security group  : inbound 80 from anywhere, inbound 22 from YOUR IP only
#   * an IAM role + instance profile with AmazonSSMManagedInstanceCore, so the
#     instance can be administered and deployed to via Systems Manager without
#     any inbound SSH at all
#   * one EC2 instance  : t3.micro (x86_64, matches the linux/amd64 image)
#
# NOTHING is deleted by this script. It never touches resources it did not
# create (everything is tagged Project=production-cicd-devops-project).
#
# USAGE
#   ./provision-aws.sh --dry-run          # show the plan and the cost estimate
#   ./provision-aws.sh                    # create the resources
#   ./provision-aws.sh --instance-type t3.small
#
# State is written to .deploy/aws-state.env (git-ignored).
# ---------------------------------------------------------------------------
set -Eeuo pipefail

PROJECT_TAG="production-cicd-devops-project"
NAME_TAG="${PROJECT_TAG}"
REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="t3.micro"
DRY_RUN=0
WITH_SSH=1
STATE_FILE=""

log()  { printf '[provision] %s\n' "$*"; }
warn() { printf '[provision] WARNING: %s\n' "$*" >&2; }
die()  { printf '[provision] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)        REGION="${2:-}"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="${2:-}"; shift 2 ;;
    --no-ssh)        WITH_SSH=0; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --state-file)    STATE_FILE="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "Unknown argument: $1" ;;
  esac
done

command -v aws >/dev/null || die "aws CLI is required"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are not configured (run 'aws configure' or set a profile)"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
MY_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n' || true)"

log "Account    : ${ACCOUNT_ID}"
log "Identity   : ${CALLER_ARN}"
log "Region     : ${REGION}"
log "Type       : ${INSTANCE_TYPE}"
log "Operator IP: ${MY_IP:-<unknown>}"

# --- Cost estimate ----------------------------------------------------------
cat <<EOF

  ------------------------------------------------------------------
  COST ESTIMATE (${REGION}, on-demand, 730 h/month)
    EC2 ${INSTANCE_TYPE}         ~\$0.0104/h  ->  ~\$7.59/month
    EBS gp3 8 GiB (root)         ~\$0.08/GB  ->  ~\$0.64/month
    Public IPv4 address          ~\$0.005/h  ->  ~\$3.65/month
    Data transfer out            first 100 GB/month free
    ------------------------------------------------------------
    Indicative total                            ~\$11.9/month
  ------------------------------------------------------------------
  Free-tier eligibility is NOT assumed: this account already has
  resources and may be outside any free-tier window.
  Stopping the instance keeps EBS and the public IPv4 charge.
  Run scripts/cleanup-aws.sh to remove everything.
EOF

if (( DRY_RUN )); then
  log "Dry run: no resources were created."
  exit 0
fi

[[ -n "$MY_IP" ]] || die "could not determine your public IP (needed to restrict SSH); rerun with --no-ssh to skip SSH entirely"

STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.deploy"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_FILE:-$STATE_DIR/aws-state.env}"

# --- 1. Default VPC ---------------------------------------------------------
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" != "None" && -n "$VPC_ID" ]] || die "no default VPC in ${REGION}"

SUBNET_ID="$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)"
log "VPC        : ${VPC_ID}"
log "Subnet     : ${SUBNET_ID}"

# --- 2. Security group ------------------------------------------------------
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${PROJECT_TAG}-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  log "Creating security group ${PROJECT_TAG}-sg..."
  SG_ID="$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${PROJECT_TAG}-sg" \
    --description "Notes API: HTTP 80 public, SSH restricted to operator IP" \
    --vpc-id "$VPC_ID" --query GroupId --output text)"

  aws ec2 create-tags --region "$REGION" --resources "$SG_ID" \
    --tags "Key=Project,Value=${PROJECT_TAG}" "Key=Name,Value=${PROJECT_TAG}-sg"

  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"Public HTTP"}]}]' >/dev/null

  if (( WITH_SSH )); then
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"IpRanges\":[{\"CidrIp\":\"${MY_IP}/32\",\"Description\":\"Operator SSH only\"}]}]" >/dev/null
    log "SSH allowed from ${MY_IP}/32 only"
  else
    log "SSH disabled - administration via SSM only"
  fi
else
  log "Security group already exists: ${SG_ID}"
fi

# --- 3. IAM role for SSM ----------------------------------------------------
ROLE_NAME="${PROJECT_TAG}-ec2-role"
PROFILE_NAME="${PROJECT_TAG}-ec2-profile"

if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "Creating IAM role ${ROLE_NAME}..."
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "Allows the Notes API instance to be managed by Systems Manager" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags "Key=Project,Value=${PROJECT_TAG}" >/dev/null

  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
else
  log "IAM role already exists: ${ROLE_NAME}"
fi

if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  log "Creating instance profile ${PROFILE_NAME}..."
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --tags "Key=Project,Value=${PROJECT_TAG}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME"
  # IAM is eventually consistent; give it a moment before launching.
  sleep 10
else
  log "Instance profile already exists: ${PROFILE_NAME}"
fi

# --- 4. AMI -----------------------------------------------------------------
AMI_ID="$(aws ssm get-parameters --region "$REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)"
log "AMI        : ${AMI_ID} (Amazon Linux 2023)"

# --- 5. Instance ------------------------------------------------------------
EXISTING="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=${PROJECT_TAG}" "Name=tag:Role,Values=app" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo None)"

if [[ "$EXISTING" != "None" && -n "$EXISTING" ]]; then
  INSTANCE_ID="$EXISTING"
  log "Reusing existing instance: ${INSTANCE_ID}"
else
  log "Launching ${INSTANCE_TYPE}..."
  INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=${PROFILE_NAME}" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true,"Encrypted":true}}]' \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_TAG}},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=app}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${NAME_TAG}-root},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' --output text)"

  log "Waiting for ${INSTANCE_ID} to be running..."
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
fi

PUBLIC_IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

# --- 6. Save state ----------------------------------------------------------
cat >"$STATE_FILE" <<EOF
# Generated by scripts/provision-aws.sh - do not commit (git-ignored).
AWS_REGION=${REGION}
AWS_ACCOUNT_ID=${ACCOUNT_ID}
INSTANCE_ID=${INSTANCE_ID}
INSTANCE_TYPE=${INSTANCE_TYPE}
PUBLIC_IP=${PUBLIC_IP}
SECURITY_GROUP_ID=${SG_ID}
VPC_ID=${VPC_ID}
SUBNET_ID=${SUBNET_ID}
IAM_ROLE_NAME=${ROLE_NAME}
IAM_PROFILE_NAME=${PROFILE_NAME}
OPERATOR_IP=${MY_IP}
EOF

log "State written to ${STATE_FILE}"
log "Instance   : ${INSTANCE_ID}"
log "Public IP  : ${PUBLIC_IP}"
log "Next       : scripts/bootstrap-server.sh on the instance, then scripts/deploy.sh"
