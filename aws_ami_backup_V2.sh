#!/usr/bin/env bash
# ==============================================================================
# create_ami_v2.sh – Hardened AWS AMI Automation
# ==============================================================================
# Config format:
# AccountId , Region , EC2_InstanceId , RetentionDays , BackupReason
#
# AMI Name:
# instance_name-BackupReason-DD-MM-YYYY-HHMM-automated-ami
#
# Modes:
#   dry-run (default)
#   run
# ==============================================================================

set -euo pipefail

CONFIG_FILE="${1:-ami_config.txt}"
MODE="${2:-dry-run}"

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H%M)"

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

[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config file not found"; exit 1; }

CURRENT_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

LINE_NO=0

while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE_NO=$((LINE_NO+1))
  LINE="$(trim "$RAWLINE")"

  [[ -z "$LINE" || "$LINE" == \#* ]] && continue

  IFS=',' read -r f1 f2 f3 f4 f5 <<< "$LINE"

  ACCOUNT_ID="$(trim "${f1:-}")"
  REGION="$(trim "${f2:-}")"
  INSTANCE_ID="$(trim "${f3:-}")"
  RETENTION="$(trim "${f4:-}")"
  REASON="$(trim "${f5:-}")"

  echo "-----------------------------------------------------"
  echo "Processing line $LINE_NO → $INSTANCE_ID ($REGION)"

  # ---------------- Validations ----------------
  [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "❌ Invalid AccountId"; continue; }
  [[ "$ACCOUNT_ID" == "$CURRENT_ACCOUNT" ]] || { echo "❌ Account mismatch (expected $ACCOUNT_ID, running $CURRENT_ACCOUNT)"; continue; }
  [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]] || { echo "❌ Invalid InstanceId"; continue; }
  [[ "$RETENTION" =~ ^[0-9]+$ ]] || { echo "❌ RetentionDays must be numeric"; continue; }

  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text &>/dev/null || { echo "❌ Instance not found"; continue; }

  # ---------------- Instance Name ----------------
  INSTANCE_NAME="$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]" \
    --output text)"

  [[ "$INSTANCE_NAME" == "None" || -z "$INSTANCE_NAME" ]] && INSTANCE_NAME="$INSTANCE_ID"

  SAFE_INSTANCE="$(echo "$INSTANCE_NAME" | tr ' /' '--')"
  SAFE_REASON="$(echo "$REASON" | tr ' /' '--')"

  AMI_NAME="${SAFE_INSTANCE}-${SAFE_REASON}-${DATE_TAG}-${TIME_TAG}-automated-ami"

  echo "AMI Name      : $AMI_NAME"
  echo "RetentionDays : $RETENTION"

  if [[ "$MODE" == "dry-run" ]]; then
    echo "🟡 DRY-RUN: AMI would be created"
    continue
  fi

  # ---------------- Create AMI (NO REBOOT) ----------------
  AMI_ID="$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "$REASON" \
    --no-reboot \
    --query ImageId \
    --output text)"

  # ---------------- Tag AMI ----------------
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

  echo "✅ AMI Created: $AMI_ID"

done < "$CONFIG_FILE"

echo "====================================================="
echo "AMI creation completed @ $(date)"
echo "====================================================="
