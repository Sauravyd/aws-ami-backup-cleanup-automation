#!/usr/bin/env bash
# ==============================================================================
# AWS AMI Automation Script – Standard Naming Convention
# ==============================================================================
# Config fields:
# AccountId , Region , EC2_InstanceId , RetentionDays , BackupReason
#
# AMI Name format:
# instance_name-BackupReason <DD-MM-YYYY>-<HHMM>-automated-ami
#
# Safety:
# - NO REBOOT (hard enforced)
# ==============================================================================

set -euo pipefail

CONFIG_FILE="${1:-ami_config.txt}"
MODE="${2:-dry-run}"   # dry-run | run

trim() { echo "$1" | xargs; }

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Config file not found: $CONFIG_FILE"
  exit 1
fi

echo "▶ MODE        : $MODE"
echo "▶ CONFIG FILE : $CONFIG_FILE"
echo "-----------------------------------------------------"

LINE_NO=0

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  LINE_NO=$((LINE_NO + 1))
  line="$(trim "$raw_line")"

  [[ -z "$line" || "$line" == \#* ]] && continue

  IFS=',' read -r f1 f2 f3 f4 f5 <<< "$line"

  ACCOUNT_ID="$(trim "${f1:-}")"
  REGION="$(trim "${f2:-}")"
  INSTANCE_ID="$(trim "${f3:-}")"
  RETENTION_DAYS="$(trim "${f4:-}")"
  BACKUP_REASON="$(trim "${f5:-}")"

  # ---------------- Validation ----------------
  if [[ -z "$ACCOUNT_ID" || -z "$REGION" || -z "$INSTANCE_ID" || -z "$RETENTION_DAYS" || -z "$BACKUP_REASON" ]]; then
    echo "⚠️ Line $LINE_NO skipped (missing fields)"
    continue
  fi

  if ! [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "⚠️ Line $LINE_NO skipped (invalid AccountId)"
    continue
  fi

  if ! [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
    echo "⚠️ Line $LINE_NO skipped (invalid InstanceId)"
    continue
  fi

  if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "⚠️ Line $LINE_NO skipped (RetentionDays must be numeric)"
    continue
  fi

  # Verify instance exists
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text &>/dev/null || {
      echo "⚠️ Line $LINE_NO skipped (instance not found)"
      continue
    }

  # ---------------- Fetch Instance Name ----------------
  INSTANCE_NAME=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]" \
    --output text)

  [[ "$INSTANCE_NAME" == "None" || -z "$INSTANCE_NAME" ]] && INSTANCE_NAME="$INSTANCE_ID"

  # ---------------- Build AMI Name ----------------
  DATE_PART=$(date +"%d-%m-%Y")
  TIME_PART=$(date +"%H%M")

  SAFE_INSTANCE_NAME=$(echo "$INSTANCE_NAME" | tr ' /' '--')
  SAFE_REASON=$(echo "$BACKUP_REASON" | tr ' /' '--')

  AMI_NAME="${SAFE_INSTANCE_NAME}-${SAFE_REASON}-${DATE_PART}-${TIME_PART}-automated-ami"

  echo "-----------------------------------------------------"
  echo "✔ Line $LINE_NO"
  echo "Instance Name : $INSTANCE_NAME"
  echo "AMI Name      : $AMI_NAME"
  echo "Region        : $REGION"
  echo "RetentionDays : $RETENTION_DAYS"

  if [[ "$MODE" == "dry-run" ]]; then
    echo "🟡 DRY-RUN: AMI would be created"
    continue
  fi

  # ---------------- Create AMI (NO REBOOT) ----------------
  AMI_ID=$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "$BACKUP_REASON" \
    --no-reboot \
    --query "ImageId" \
    --output text)

  # ---------------- Tag AMI ----------------
  aws ec2 create-tags \
    --region "$REGION" \
    --resources "$AMI_ID" \
    --tags \
      Key=Name,Value="$AMI_NAME" \
      Key=AutomatedBackup,Value=true \
      Key=RetentionDays,Value="$RETENTION_DAYS" \
      Key=AccountId,Value="$ACCOUNT_ID" \
      Key=CreatedBy,Value=AMI-Automation \
      Key=BackupReason,Value="$BACKUP_REASON" \
      Key=CreatedOn,Value="$(date +"%d-%m-%Y %H:%M")"

  echo "✅ AMI Created: $AMI_ID"

done < "$CONFIG_FILE"

echo "-----------------------------------------------------"
echo "✔ AMI automation completed"
