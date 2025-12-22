#!/usr/bin/env bash
# ==============================================================================
# aws_ami_cleanup_V2.sh – Production-Ready Cross-Account AMI Cleanup Automation
# Skip-per-resource + Fail-at-summary
# ==============================================================================
# Input file format:
# AccountId , Region , EC2_InstanceId , RetentionDays , BackupReason
#
# Modes:
#   dry-run
#   run
# ==============================================================================

set -uo pipefail   # ❗ NO -e (very important)

CONFIG_FILE="${1:-serverlist.txt}"
MODE="${2:-dry-run}"

NOW_EPOCH=$(date +%s)

# ---------------- ROLE MAP ----------------
declare -A ROLE_MAP
ROLE_MAP["782511039777"]="arn:aws:iam::782511039777:role/CrossAccount-AMICleanupRole"

LOGDIR="./ami_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/cleanup-ami-$(date +%d-%m-%Y-%H%M).log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "====================================================="
echo "Starting AMI cleanup @ $(date)"
echo "Mode        : $MODE"
echo "Config file : $CONFIG_FILE"
echo "Log file    : $LOGFILE"
echo "====================================================="

trim() { echo "$1" | xargs; }

# ---------------- GLOBAL COUNTERS ----------------
TOTAL_SCANNED=0
ELIGIBLE_COUNT=0
CLEANUP_SUCCESS=0
CLEANUP_FAILED=0

SKIP_NO_TAG=0
SKIP_BAD_RETENTION=0
SKIP_NOT_EXPIRED=0
SKIP_ASSUME_ROLE=0

FAILED_LIST=()

# ---------------- ASSUME ROLE FUNCTION ----------------
assume_role() {
  local TARGET_ACCOUNT="$1"

  CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

  if [[ "$TARGET_ACCOUNT" == "$CURRENT_ACCOUNT" ]]; then
    echo "ℹ️ Using existing Jenkins credentials for account $TARGET_ACCOUNT"
    return 0
  fi

  local ROLE_ARN="${ROLE_MAP[$TARGET_ACCOUNT]:-}"
  if [[ -z "$ROLE_ARN" ]]; then
    echo "❌ No IAM role mapped for account $TARGET_ACCOUNT"
    return 1
  fi

  CREDS=$(aws sts assume-role \
    --role-arn "$ROLE_ARN" \
    --role-session-name "ami-cleanup-$(date +%s)" \
    --query 'Credentials' \
    --output json 2>/dev/null) || return 1

  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.SessionToken')

  echo "✅ Switched to AWS Account: $(aws sts get-caller-identity --query Account --output text)"
}

# ---------------- VALIDATION ----------------
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config file not found"; exit 1; }

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

  if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "❌ Invalid AccountId – skipping"
    SKIP_ASSUME_ROLE=$((SKIP_ASSUME_ROLE+1))
    continue
  fi

  assume_role "$ACCOUNT_ID" || {
    echo "❌ AssumeRole failed – skipping account"
    SKIP_ASSUME_ROLE=$((SKIP_ASSUME_ROLE+1))
    continue
  }

  echo "🔍 Scanning AMIs in region $REGION"

  AMI_IDS=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners self \
    --query "Images[].ImageId" \
    --output text 2>/dev/null)

  for AMI_ID in $AMI_IDS; do
    TOTAL_SCANNED=$((TOTAL_SCANNED+1))

    IMAGE_JSON=$(aws ec2 describe-images \
      --region "$REGION" \
      --image-ids "$AMI_ID" \
      --query "Images[0]" \
      --output json 2>/dev/null) || {
        CLEANUP_FAILED=$((CLEANUP_FAILED+1))
        FAILED_LIST+=("$ACCOUNT_ID:$REGION:$AMI_ID (describe-image)")
        continue
      }

    AUTO_TAG=$(echo "$IMAGE_JSON" | jq -r '.Tags[]? | select(.Key=="AutomatedBackup") | .Value')
    RETENTION=$(echo "$IMAGE_JSON" | jq -r '.Tags[]? | select(.Key=="RetentionDays") | .Value')
    CREATION_DATE=$(echo "$IMAGE_JSON" | jq -r '.CreationDate')

    [[ "$AUTO_TAG" != "true" ]] && { SKIP_NO_TAG=$((SKIP_NO_TAG+1)); continue; }
    ! [[ "$RETENTION" =~ ^[0-9]+$ ]] && { SKIP_BAD_RETENTION=$((SKIP_BAD_RETENTION+1)); continue; }

    CREATED_EPOCH=$(python3 - <<EOF
from datetime import datetime
dt = datetime.fromisoformat("${CREATION_DATE}".replace("Z", "+00:00"))
print(int(dt.timestamp()))
EOF
)

    AGE_DAYS=$(( (NOW_EPOCH - CREATED_EPOCH) / 86400 ))
    (( AGE_DAYS < RETENTION )) && { SKIP_NOT_EXPIRED=$((SKIP_NOT_EXPIRED+1)); continue; }

    ELIGIBLE_COUNT=$((ELIGIBLE_COUNT+1))

    echo "-----------------------------------------------------"
    echo "ELIGIBLE AMI  : $AMI_ID"
    echo "Age (days)    : $AGE_DAYS"
    echo "RetentionDays : $RETENTION"

    SNAPSHOTS=$(echo "$IMAGE_JSON" | jq -r '.BlockDeviceMappings[].Ebs.SnapshotId')

    if [[ "$MODE" == "dry-run" ]]; then
      echo "🟡 DRY-RUN: Would deregister AMI and delete snapshots"
      echo "Snapshots: $SNAPSHOTS"
      CLEANUP_SUCCESS=$((CLEANUP_SUCCESS+1))
      continue
    fi

    aws ec2 deregister-image --region "$REGION" --image-id "$AMI_ID" || {
      CLEANUP_FAILED=$((CLEANUP_FAILED+1))
      FAILED_LIST+=("$ACCOUNT_ID:$REGION:$AMI_ID (deregister)")
      continue
    }

    echo "✅ Deregistered AMI: $AMI_ID"

    for SNAP in $SNAPSHOTS; do
      aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAP" || {
        CLEANUP_FAILED=$((CLEANUP_FAILED+1))
        FAILED_LIST+=("$ACCOUNT_ID:$REGION:$AMI_ID (snapshot:$SNAP)")
        continue
      }
      echo "🗑 Deleted snapshot: $SNAP"
    done

    CLEANUP_SUCCESS=$((CLEANUP_SUCCESS+1))
  done

done < "$CONFIG_FILE"

# ---------------- FINAL SUMMARY ----------------
echo
echo "====================================================="
echo "AMI CLEANUP SUMMARY"
echo "Total AMIs scanned                 : $TOTAL_SCANNED"
echo "Eligible for cleanup               : $ELIGIBLE_COUNT"
echo "Cleanup success                    : $CLEANUP_SUCCESS"
echo "Cleanup failed                     : $CLEANUP_FAILED"
echo "Skipped (no AutomatedBackup tag)   : $SKIP_NO_TAG"
echo "Skipped (invalid RetentionDays)    : $SKIP_BAD_RETENTION"
echo "Skipped (not yet expired)          : $SKIP_NOT_EXPIRED"
echo "Skipped (assume role / bad input)  : $SKIP_ASSUME_ROLE"
echo "====================================================="

if (( CLEANUP_FAILED > 0 )); then
  echo "❌ Failed resources:"
  for f in "${FAILED_LIST[@]}"; do
    echo " - $f"
  done
fi

# ---------------- EXIT LOGIC ----------------
if (( ELIGIBLE_COUNT > 0 && CLEANUP_SUCCESS == 0 )); then
  echo "❌ Cleanup failed for all eligible AMIs"
  exit 1
elif (( CLEANUP_FAILED > 0 )); then
  echo "⚠️ Partial cleanup failures detected"
  exit 2   # Jenkins = UNSTABLE
else
  echo "✅ AMI cleanup completed successfully"
  exit 0
fi
