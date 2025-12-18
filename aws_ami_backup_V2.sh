#!/usr/bin/env bash
# ==============================================================================
# create_ami_v2.sh – Hardened AWS AMI Automation (WITH STATUS VALIDATION)
# ==============================================================================
# Config format:
# AccountId , Region , EC2_InstanceId , RetentionDays , BackupReason
#
# AMI Name:
# instance_name-BackupReason-DD-MM-YYYY-HHMM-automated-ami
#
# Modes:
#   dry-run
#   run
# ==============================================================================

set -euo pipefail

CONFIG_FILE="${1:-ami_config.txt}"
MODE="${2:-dry-run}"

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H%M)"

# ---------------- AMI WAIT CONFIG ----------------
AMI_POLL_INTERVAL=30          # seconds
AMI_MAX_WAIT_TIME=3600        # 1 hour max wait

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
        echo "⚠️ Unknown AMI state '$state' for $ami_id"
        ;;
    esac

    if (( waited >= AMI_MAX_WAIT_TIME )); then
      echo "❌ Timeout waiting for AMI $ami_id after ${AMI_MAX_WAIT_TIME}s"
      return 1
    fi

    sleep "$AMI_POLL_INTERVAL"
    waited=$((waited + AMI_POLL_INTERVAL))
  done
}

# ---------------- VALIDATIONS ----------------
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

  [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "❌ Invalid AccountId"; exit 1; }
  [[ "$ACCOUNT_ID" == "$CURRENT_ACCOUNT" ]] || { echo "❌ Account mismatch"; exit 1; }
  [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]] || { echo "❌ Invalid InstanceId"; exit 1; }
  [[ "$RETENTION" =~ ^[0-9]+$ ]] || { echo "❌ RetentionDays must be numeric"; exit 1; }

  if ! aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text >/tmp/inst.out 2>/tmp/inst.err; then
      echo "❌ AWS error while describing instance:"
      cat /tmp/inst.err
      exit 1
  fi

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

  # ---------------- CREATE AMI ----------------
  AMI_ID="$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "$REASON" \
    --no-reboot \
    --query ImageId \
    --output text)"

  [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]] && { echo "❌ AMI creation failed"; exit 1; }

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
  if ! wait_for_ami "$AMI_ID" "$REGION"; then
    echo "❌ AMI validation failed for instance $INSTANCE_ID"
    exit 1
  fi

done < "$CONFIG_FILE"

echo "====================================================="
echo "AMI creation completed successfully @ $(date)"
echo "====================================================="
