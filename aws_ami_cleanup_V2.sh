#!/usr/bin/env bash
# ==============================================================================
# aws_ami_cleanup_V2.sh – Retention-based AMI cleanup (Correct counters)
# ==============================================================================
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

# ---------------- Counters ----------------
TOTAL_SCANNED=0
SKIP_NO_TAG=0
SKIP_BAD_RETENTION=0
SKIP_NOT_EXPIRED=0
ELIGIBLE_COUNT=0

# ------------------------------------------------------
# IMPORTANT: process substitution (NO pipe)
# ------------------------------------------------------
while read -r AMI_ID; do
  [[ -z "$AMI_ID" ]] && continue
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

  if [[ "$AUTO_TAG" != "true" ]]; then
    SKIP_NO_TAG=$((SKIP_NO_TAG+1))
    echo "SKIP $AMI_ID → AutomatedBackup tag missing or not 'true'"
    continue
  fi

  if ! [[ "$RETENTION" =~ ^[0-9]+$ ]]; then
    SKIP_BAD_RETENTION=$((SKIP_BAD_RETENTION+1))
    echo "SKIP $AMI_ID → RetentionDays tag missing/invalid"
    continue
  fi

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
    echo "SKIP $AMI_ID → Age $AGE_DAYS < RetentionDays $RETENTION"
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

done < <(
  aws ec2 describe-images \
    --region "$REGION" \
    --owners self \
    --query "Images[].ImageId" \
    --output text | tr '\t' '\n'
)

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

if [[ "$ELIGIBLE_COUNT" -eq 0 ]]; then
  echo "ℹ️ RESULT: No AMIs found eligible for deletion in this run."
else
  echo "ℹ️ RESULT: $ELIGIBLE_COUNT AMI(s) eligible for cleanup."
fi

echo "AMI cleanup completed @ $(date)"
