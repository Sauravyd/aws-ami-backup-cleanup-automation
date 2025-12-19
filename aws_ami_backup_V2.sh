#!/usr/bin/env bash
# ==============================================================================
# aws_ami_backup_V2.sh – Cross-Account AMI Backup Automation
# ==============================================================================
# Config format:
# AccountId , Region , EC2_InstanceId , RetentionDays , BackupReason
#
# Modes:
#   dry-run
#   run
# ==============================================================================

set -euo pipefail

CONFIG_FILE="${1:-serverlist.txt}"
MODE="${2:-dry-run}"

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H%M)"

# ---------------- ROLE MAP ----------------
declare -A ROLE_MAP

# ONLY cross-account roles here
ROLE_MAP["782511039777"]="arn:aws:iam::782511039777:role/CrossAccount-AMICleanupRole"

# ---------------- AMI WAIT CONFIG ----------------
AMI_POLL_INTERVAL=30
AMI_MAX_WAIT_TIME=3600

LOGDIR="./ami_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-ami-${DATE_TAG}-${TIME_TAG}.log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "====================================================="
echo "Starting AMI creation @ $(date)"
echo "Mode       : $MODE"
echo "Config     : $CONFIG_FILE"
echo "Log file   : $LOGFILE"
echo "====================================================="

trim() { echo "$1" | xargs; }

# ---------------- ASSUME ROLE FUNCTION ----------------
assume_role() {
  local TARGET_ACCOUNT="$1"

  CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

  # SAME ACCOUNT → use Jenkins credentials (DO NOT assume role)
  if [[ "$TARGET_ACCOUNT" == "$CURRENT_ACCOUNT" ]]; then
    echo "ℹ️ Using existing Jenkins credentials for account $TARGET_ACCOUNT"
    return 0
  fi

  # CROSS ACCOUNT ONLY
  local ROLE_ARN="${ROLE_MAP[$TARGET_ACCOUNT]:-}"

  [[ -z "$ROLE_ARN" ]] && {
    echo "❌ No IAM role mapped for cross-account $TARGET_ACCOUNT"
    exit 1
  }

  echo "🔐 Assuming role for cross-account $TARGET_ACCOUNT"

  CREDS=$(aws sts assume-role \
    --role-arn "$ROLE_ARN" \
    --role-session-name "ami-backup-$(date +%s)" \
    --query 'Credentials' \
    --output json)

  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.SessionToken')

  echo "✅ Switched to AWS Account: $(aws sts get-caller-identity --query Account --output text)"
}

# ---------------- AMI WAIT FUNCTION ----------------
wait_for_ami() {
  local ami_id="$1"
  local region="$2"
  local waited=0

  echo "⏳ Waiting for AMI to become AVAILABLE: $ami_id"

  while true; do
    state="$(aws ec2 describe-images \
      --image-ids "$ami_id" \
      --region "$region" \
      --query 'Images[0].State' \
      --output text 2>/dev/null || echo unknown)"

    case "$state" in
      available)
        echo "✅ AMI is AVAILABLE: $ami_id"
        return 0
        ;;
      failed)
        echo "❌ AMI creation FAILED: $ami_id"
        return 1
        ;;
      pending)
        echo "⏳ AMI still pending... (${waited}s elapsed)"
        ;;
      *)
        echo "⚠️ Unknown AMI state '$state'"
        ;;
    esac

    if (( waited >= AMI_MAX_WAIT_TIME )); then
      echo "❌ Timeout waiting for AMI $ami_id"
      return 1
    fi

    sleep "$AMI_POLL_INTERVAL"
    waited=$((waited + AMI_POLL_INTERVAL))
  done
}

# ---------------- VALIDATIONS ----------------
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config file not found"; exit 1; }

LINE_NO=0

while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE_NO=$((LINE_NO+1))
  LINE="$(trim "$RAWLINE")"

  [[ -z "$LINE" || "$LINE" == \#* ]] && continue

  IFS=',' read -r f1 f2 f3 f4 f5 <<< "$LINE"

  ACCOUNT_ID="$(trim "$f1")"
  REGION="$(trim "$f2")"
  INSTANCE_ID="$(trim "$f3")"
  RETENTION="$(trim "$f4")"
  REASON="$(trim "$f5")"

  echo "-----------------------------------------------------"
  echo "Line $LINE_NO → Account $ACCOUNT_ID | Instance $INSTANCE_ID"

  [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "❌ Invalid AccountId"; exit 1; }
  [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]] || { echo "❌ Invalid InstanceId"; exit 1; }
  [[ "$RETENTION" =~ ^[0-9]+$ ]] || { echo "❌ RetentionDays must be numeric"; exit 1; }

  # 🔐 Switch credentials if required
  assume_role "$ACCOUNT_ID"

  # Validate instance
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text >/dev/null

  INSTANCE_NAME="$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]" \
    --output text)"

  [[ -z "$INSTANCE_NAME" || "$INSTANCE_NAME" == "None" ]] && INSTANCE_NAME="$INSTANCE_ID"

  SAFE_INSTANCE="$(echo "$INSTANCE_NAME" | tr ' /' '--')"
  SAFE_REASON="$(echo "$REASON" | tr ' /' '--')"

  AMI_NAME="${SAFE_INSTANCE}-${SAFE_REASON}-${DATE_TAG}-${TIME_TAG}-automated-ami"

  echo "AMI Name      : $AMI_NAME"
  echo "RetentionDays : $RETENTION"

  if [[ "$MODE" == "dry-run" ]]; then
    echo "🟡 DRY-RUN: AMI would be created"
    continue
  fi

  # ---------------- CREATE AMI ----------------
  AMI_ID="$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "$REASON" \
    --no-reboot \
    --query ImageId \
    --output text)"

  echo "🆕 AMI creation started: $AMI_ID"

  # ---------------- TAG AMI ----------------
  aws ec2 create-tags \
    --region "$REGION" \
    --resources "$AMI_ID" \
    --tags \
      Key=Name,Value="$AMI_NAME" \
      Key=AutomatedBackup,Value=true \
      Key=RetentionDays,Value="$RETENTION" \
      Key=BackupReason,Value="$REASON" \
      Key=CreatedBy,Value=AMI-Automation \
      Key=CreatedOn,Value="$(date +"%d-%m-%Y %H:%M")"

  # ---------------- WAIT & VALIDATE ----------------
  wait_for_ami "$AMI_ID" "$REGION"

done < "$CONFIG_FILE"

echo "====================================================="
echo "AMI creation completed successfully @ $(date)"
echo "====================================================="
