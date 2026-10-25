#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Remove every AWS resource created by scripts/provision-aws.sh.
#
# SAFETY
#   * Only resources tagged Project=production-cicd-devops-project are touched.
#   * Requires --yes. A --dry-run mode lists exactly what would be deleted.
#   * Resources that predate this project (e.g. the existing MSE-Ubuntu
#     instance) are never listed and never deleted.
#
# USAGE
#   ./cleanup-aws.sh --dry-run
#   ./cleanup-aws.sh --yes
# ---------------------------------------------------------------------------
set -Eeuo pipefail

PROJECT_TAG="production-cicd-devops-project"
REGION="${AWS_REGION:-us-east-1}"
CONFIRM=0
DRY_RUN=0

log() { printf '[cleanup] %s\n' "$*"; }
die() { printf '[cleanup] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)  REGION="${2:-}"; shift 2 ;;
    --yes)     CONFIRM=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "Unknown argument: $1" ;;
  esac
done

STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.deploy"
if [[ -f "$STATE_DIR/aws-state.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/aws-state.env"
fi

INSTANCE_IDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"

SG_IDS="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
  --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)"

cat <<EOF

The following resources are tagged Project=${PROJECT_TAG} in ${REGION}:

  EC2 instances      : ${INSTANCE_IDS:-<none>}
  Security groups    : ${SG_IDS:-<none>}
  IAM role/profile   : ${PROJECT_TAG}-ec2-role / ${PROJECT_TAG}-ec2-profile

Nothing else in the account is touched.

EOF

if (( DRY_RUN )); then
  log "Dry run: nothing was deleted."
  exit 0
fi

if (( ! CONFIRM )); then
  die "Refusing to delete without --yes (use --dry-run to preview)"
fi

# --- 1. Terminate instances -------------------------------------------------
for id in $INSTANCE_IDS; do
  log "Terminating ${id}..."
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$id" >/dev/null
done
for id in $INSTANCE_IDS; do
  log "Waiting for ${id} to terminate..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$id" || true
done

# --- 2. Security groups -----------------------------------------------------
for sg in $SG_IDS; do
  log "Deleting security group ${sg}..."
  # Retry: a group can stay referenced for a short time after termination.
  for _ in 1 2 3 4 5; do
    if aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
done

# --- 3. IAM -----------------------------------------------------------------
ROLE_NAME="${PROJECT_TAG}-ec2-role"
PROFILE_NAME="${PROJECT_TAG}-ec2-profile"

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  log "Removing role from instance profile..."
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
  log "Deleting instance profile ${PROFILE_NAME}..."
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1 || true
fi

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "Detaching policies from ${ROLE_NAME}..."
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
  log "Deleting role ${ROLE_NAME}..."
  aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
fi

log "Cleanup complete. Verify in the AWS console that no project resources remain."
log "Note: EBS volumes tagged DeleteOnTermination=true are removed with the instance."
