#!/usr/bin/env bash
# ==============================================================================
# aws_ami_cleanup_V2.sh – Cross-Account AMI Cleanup Automation
# ==============================================================================
# Input file format (same as backup):
# AccountId , Region , EC2_InstanceId , RetentionDays , BackupReason
#
# Modes:
#   dry-run (default)
#   run
# ==============================================================================

set -euo pipefail

CONFIG_FILE="${1:-serverlist.txt}"
MODE="${2:-dry-run}"

NOW_EPOCH=$(date +%s)

# ---------------- ROLE MAP ----------------
declare -A ROLE_MAP
# ONLY cross-account roles
ROLE_MAP["782511039777"]="arn:aws:iam::782511039777:role/CrossAccount-AMICleanupRole"

LOGDIR="./ami_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/cleanup-ami-$(date +%d-%m-%Y-%H%M).log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "====================================================="
echo "Starting AMI cleanup @ $(date)"
echo "Mode        : $MODE"
echo "Config file : $CONFIG_FILE"
echo "====================================================="

trim() { echo "$1" | xargs; }

# ---------------- ASSUME ROLE FUNCTION ----------------
assume_role() {
  local TARGET_ACCOUNT="$1"

  CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

  # SAME ACCOUNT → use Jenkins credentials
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
    --role-session-name "ami-cleanup-$(date +%s)" \
    --query 'Credentials' \
    --output json)

  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.SessionToken')

  echo "✅ Switched to AWS Account: $(aws sts get-caller-identity --query Account --output text)"
}

# ---------------- Counters ----------------
TOTAL_SCANNED=0
SKIP_NO_TAG=0
SKIP_BAD_RETENTION=0
SKIP_NOT_EXPIRED=0
ELIGIBLE_COUNT=0

# ---------------- MAIN LOOP ----------------
LINE_NO=0

while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE_NO=$((LINE_NO+1))
  LINE="$(trim "$RAWLINE")"

  [[ -z "$LINE" || "$LINE" == \#* ]] && continue

  IFS=',' read -r f1 f2 _ _ _ <<< "$LINE"

  ACCOUNT_ID="$(trim "$f1")"
  REGION="$(trim "$f2")"

  echo "-----------------------------------------------------"
  echo "Line $LINE_NO → Account $ACCOUNT_ID | Region $REGION"

  [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "❌ Invalid AccountId"; exit 1; }

  # 🔐 Switch credentials if required
  assume_role "$ACCOUNT_ID"

  echo "🔍 Scanning AMIs in region $REGION"

  AMI_IDS=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners self \
    --query "Images[].ImageId" \
    --output text)

  for AMI_ID in $AMI_IDS; do
    TOTAL_SCANNED=$((TOTAL_SCANNED+1))

    AUTO_TAG=$(aws ec2 describe-images \
      --region "$REGION" \
      --image-ids "$AMI_ID" \
      --query "Images[0].Tags[?Key=='AutomatedBackup'].Value | [0]" \
      --output text)

    RETENTION=$(aws ec2 describe-images \
      --region "$REGION" \
      --image-ids "$AMI_ID" \
      --query "Images[0].Tags[?Key=='RetentionDays'].Value | [0]" \
      --output text)

    [[ "$AUTO_TAG" != "true" ]] && { SKIP_NO_TAG=$((SKIP_NO_TAG+1)); continue; }

    ! [[ "$RETENTION" =~ ^[0-9]+$ ]] && { SKIP_BAD_RETENTION=$((SKIP_BAD_RETENTION+1)); continue; }

    CREATION_DATE=$(aws ec2 describe-images \
      --region "$REGION" \
      --image-ids "$AMI_ID" \
      --query "Images[0].CreationDate" \
      --output text)

    CREATED_EPOCH=$(python3 - <<EOF
from datetime import datetime
dt = datetime.fromisoformat("${CREATION_DATE}".replace("Z", "+00:00"))
print(int(dt.timestamp()))
EOF
)

    AGE_DAYS=$(( (NOW_EPOCH - CREATED_EPOCH) / 86400 ))

    if (( AGE_DAYS < RETENTION )); then
      SKIP_NOT_EXPIRED=$((SKIP_NOT_EXPIRED+1))
      continue
    fi

    ELIGIBLE_COUNT=$((ELIGIBLE_COUNT+1))

    echo "-----------------------------------------------------"
    echo "ELIGIBLE AMI  : $AMI_ID"
    echo "Age (days)    : $AGE_DAYS"
    echo "RetentionDays : $RETENTION"

    SNAPSHOTS=$(aws ec2 describe-images \
      --region "$REGION" \
      --image-ids "$AMI_ID" \
      --query "Images[0].BlockDeviceMappings[].Ebs.SnapshotId" \
      --output text)

    if [[ "$MODE" == "dry-run" ]]; then
      echo "🟡 DRY-RUN: Would deregister AMI and delete snapshots"
      echo "Snapshots: $SNAPSHOTS"
      continue
    fi

    aws ec2 deregister-image --region "$REGION" --image-id "$AMI_ID"
    echo "✅ Deregistered AMI: $AMI_ID"

    for SNAP in $SNAPSHOTS; do
      aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAP"
      echo "🗑 Deleted snapshot: $SNAP"
    done
  done

done < "$CONFIG_FILE"

# ---------------- Summary ----------------
echo
echo "====================================================="
echo "SUMMARY:"
echo "Total AMIs scanned                 : $TOTAL_SCANNED"
echo "Skipped (no AutomatedBackup tag)   : $SKIP_NO_TAG"
echo "Skipped (invalid RetentionDays)    : $SKIP_BAD_RETENTION"
echo "Skipped (not yet expired)          : $SKIP_NOT_EXPIRED"
echo "AMIs eligible for cleanup          : $ELIGIBLE_COUNT"
echo "====================================================="

echo "AMI cleanup completed @ $(date)"
