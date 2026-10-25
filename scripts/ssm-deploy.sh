#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run a deployment on the EC2 instance through AWS Systems Manager.
#
# Why SSM instead of SSH: no inbound port 22 needs to be open, no SSH key has
# to be stored in CI, every command is logged in AWS, and the instance needs no
# public-facing administrative surface at all.
#
# The local scripts/deploy.sh is shipped to the host as base64 and executed
# there, so the exact same, version-controlled deployment logic runs whether a
# human or GitHub Actions triggers it.
#
# USAGE
#   ./ssm-deploy.sh --instance i-0123456789 --image repo:sha
#   ./ssm-deploy.sh --instance i-0123456789 --image repo:sha --rollback-on-failure
#   ./ssm-deploy.sh --instance i-0123456789 --rollback        # explicit rollback
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
INSTANCE=""
IMAGE=""
ROLLBACK_ON_FAILURE=0
DO_ROLLBACK=0
TIMEOUT_SECONDS=900

log()  { printf '[ssm-deploy] %s\n' "$*"; }
die()  { printf '[ssm-deploy] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)            INSTANCE="${2:-}"; shift 2 ;;
    --region)              REGION="${2:-}"; shift 2 ;;
    --image)               IMAGE="${2:-}"; shift 2 ;;
    --rollback-on-failure) ROLLBACK_ON_FAILURE=1; shift ;;
    --rollback)            DO_ROLLBACK=1; shift ;;
    -h|--help)             sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                     die "Unknown argument: $1" ;;
  esac
done

[[ -n "$INSTANCE" ]] || die "--instance is required"
command -v aws >/dev/null || die "aws CLI is required"
command -v jq  >/dev/null || die "jq is required"

# --- Preflight: is the instance reachable through SSM? ----------------------
log "Checking SSM registration for ${INSTANCE}..."
PING="$(aws ssm describe-instance-information --region "$REGION" \
  --filters "Key=InstanceIds,Values=${INSTANCE}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)"

if [[ "$PING" != "Online" ]]; then
  die "Instance is not SSM-managed (status: ${PING}). Ensure the SSM agent is running and the instance profile has AmazonSSMManagedInstanceCore."
fi
log "Instance is Online in SSM"

# --- Build the remote command ----------------------------------------------
run_remote_script() {
  local script_path="$1"; shift
  local description="$1"; shift
  local b64 params_file command_id status

  b64="$(base64 <"$script_path" | tr -d '\n')"

  params_file="$(mktemp)"
  jq -n \
    --arg b64 "$b64" \
    --arg target "/opt/notes-api/deploy.sh" \
    --arg args "$*" \
    '{
       commands: [
         "set -euo pipefail",
         ("echo " + $b64 + " | base64 -d > " + $target),
         ("chmod 0755 " + $target),
         ("cd /opt/notes-api && " + $target + " " + $args)
       ]
     }' >"$params_file"

  log "Sending command: ${description}"
  command_id="$(aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE" \
    --document-name "AWS-RunShellScript" \
    --comment "$description" \
    --timeout-seconds "$TIMEOUT_SECONDS" \
    --cli-input-json "file://${params_file}" \
    --query 'Command.CommandId' --output text)"
  rm -f "$params_file"

  log "Command ID: ${command_id}"
  log "Waiting for completion..."

  local deadline=$(( SECONDS + TIMEOUT_SECONDS ))
  while (( SECONDS < deadline )); do
    status="$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$command_id" --instance-id "$INSTANCE" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success|Failed|Cancelled|TimedOut) break ;;
      *) sleep 5 ;;
    esac
  done

  echo "----- remote stdout -----"
  aws ssm get-command-invocation --region "$REGION" \
    --command-id "$command_id" --instance-id "$INSTANCE" \
    --query 'StandardOutputContent' --output text 2>/dev/null || true
  echo "----- remote stderr -----"
  aws ssm get-command-invocation --region "$REGION" \
    --command-id "$command_id" --instance-id "$INSTANCE" \
    --query 'StandardErrorContent' --output text 2>/dev/null || true
  echo "-------------------------"

  log "Remote status: ${status}"
  [[ "$status" == "Success" ]]
}

do_rollback() {
  log "Starting rollback to the previously deployed image..."
  local params_file command_id status
  params_file="$(mktemp)"
  jq -n '{
    commands: [
      "set -euo pipefail",
      "PREV=$(cat /opt/notes-api/state/previous_image 2>/dev/null || true)",
      "if [ -z \"$PREV\" ]; then echo \"No previous image recorded\" >&2; exit 1; fi",
      "echo \"Rolling back to $PREV\"",
      "cd /opt/notes-api && ./deploy.sh --image \"$PREV\" --no-pull"
    ]
  }' >"$params_file"

  command_id="$(aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE" --document-name "AWS-RunShellScript" \
    --comment "Rollback Notes API" --timeout-seconds "$TIMEOUT_SECONDS" \
    --cli-input-json "file://${params_file}" \
    --query 'Command.CommandId' --output text)"
  rm -f "$params_file"

  local deadline=$(( SECONDS + TIMEOUT_SECONDS ))
  while (( SECONDS < deadline )); do
    status="$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$command_id" --instance-id "$INSTANCE" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; *) sleep 5 ;; esac
  done

  echo "----- rollback stdout -----"
  aws ssm get-command-invocation --region "$REGION" --command-id "$command_id" \
    --instance-id "$INSTANCE" --query 'StandardOutputContent' --output text 2>/dev/null || true
  echo "----- rollback stderr -----"
  aws ssm get-command-invocation --region "$REGION" --command-id "$command_id" \
    --instance-id "$INSTANCE" --query 'StandardErrorContent' --output text 2>/dev/null || true
  echo "---------------------------"

  log "Rollback status: ${status}"
  [[ "$status" == "Success" ]]
}

if (( DO_ROLLBACK )); then
  do_rollback || die "Rollback failed"
  log "Rollback completed"
  exit 0
fi

[[ -n "$IMAGE" ]] || die "--image is required (or use --rollback)"
[[ "$IMAGE" == *:* ]] || die "--image must include an explicit tag"

# --- Deploy -----------------------------------------------------------------
if run_remote_script "${SCRIPT_DIR}/deploy.sh" "Deploy ${IMAGE}" "--image ${IMAGE}"; then
  log "Deployment succeeded"
  exit 0
fi

if (( ROLLBACK_ON_FAILURE )); then
  log "Deployment failed - attempting automatic rollback"
  do_rollback || die "Deployment AND rollback failed - manual intervention required"
  die "Deployment failed and was rolled back to the previous version"
fi

die "Deployment failed (no rollback requested)"
