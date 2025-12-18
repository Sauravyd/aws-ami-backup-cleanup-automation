#!/usr/bin/env bash
# ==============================================================================
# aws_ami_cleanup.sh – Retention-based AMI cleanup (Fully stable)
# ==============================================================================
# Deletes AMIs where:
#   AutomatedBackup = true
#   AND age_in_days >= RetentionDays
#
# Modes:
#   dry-run (default)
#   run
# ==============================================================================

set -euo pipefail

MODE="${1:-dry-run}"
REGION="${2:-us-east-1}"

NOW_EPOCH=$(date +%s)

LOGDIR="./ami_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/cleanup-ami-$(date +%d-%m-%Y-%H%M).log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "====================================================="
echo "Starting AMI cleanup @ $(date)"
echo "Mode   : $MODE"
echo "Region : $REGION"
echo "====================================================="

# ------------------------------------------------------
# Fetch AMIs with AutomatedBackup=true (IDs only)
# ------------------------------------------------------
aws ec2 describe-images \
  --region "$REGION" \
  --owners self \
  --filters "Name=tag:AutomatedBackup,Values=true" \
  --query "Images[].ImageId" \
  --output text | tr '\t' '\n' | while read -r AMI_ID; do

  [[ -z "$AMI_ID" ]] && continue

  # -------- Fetch CreationDate safely per AMI --------
  CREATION_DATE=$(aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query "Images[0].CreationDate" \
    --output text)

  # Convert ISO-8601 → epoch (portable)
  CREATED_EPOCH=$(python3 - <<EOF
from datetime import datetime, timezone
dt = datetime.fromisoformat("${CREATION_DATE}".replace("Z", "+00:00"))
print(int(dt.timestamp()))
EOF
)

  RETENTION=$(aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query "Images[0].Tags[?Key=='RetentionDays'].Value | [0]" \
    --output text)

  [[ "$RETENTION" =~ ^[0-9]+$ ]] || {
    echo "Skipping $AMI_ID (missing/invalid RetentionDays tag)"
    continue
  }

  AGE_DAYS=$(( (NOW_EPOCH - CREATED_EPOCH) / 86400 ))

  if (( AGE_DAYS >= RETENTION )); then
    echo "-----------------------------------------------------"
    echo "AMI           : $AMI_ID"
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

    # -------- Deregister AMI --------
    aws ec2 deregister-image \
      --region "$REGION" \
      --image-id "$AMI_ID"
    echo "✅ Deregistered AMI: $AMI_ID"

    # -------- Delete snapshots --------
    for SNAP in $SNAPSHOTS; do
      aws ec2 delete-snapshot \
        --region "$REGION" \
        --snapshot-id "$SNAP"
      echo "🗑 Deleted snapshot: $SNAP"
    done
  fi
done

echo "====================================================="
echo "AMI cleanup completed @ $(date)"
echo "====================================================="
