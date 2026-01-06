#!/usr/bin/env bash
# ==============================================================================
# aws_ami_backup_V3_3_parallel_slot_based_stable.sh
# Slot-based Parallel + Cross-Account SAFE AMI Backup Automation (STABLE)
# ==============================================================================

set -uo pipefail

CONFIG_FILE="${1:-serverlist.txt}"
MODE="${2:-dry-run}"

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H%M)"

# ---------------- PARALLEL CONFIG ----------------
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-5}"

# ---------------- ROLE MAP ----------------
declare -A ROLE_MAP
ROLE_MAP["782511039777"]="arn:aws:iam::782511039777:role/CrossAccount-AMICleanupRole"

# ---------------- AMI WAIT CONFIG (FAIL-FAST) ----------------
AMI_POLL_INTERVAL=20
AMI_MAX_WAIT_TIME=900   # 15 minutes max per AMI

# ---------------- LOGGING ----------------
LOGDIR="./ami_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-ami-${DATE_TAG}-${TIME_TAG}.log"
exec > >(tee -a "$LOGFILE") 2>&1

# ---------------- RESULT FILES ----------------
WORKDIR="/tmp/ami_parallel_$$"
mkdir -p "$WORKDIR"
SUCCESS_FILE="$WORKDIR/success.txt"
FAILED_FILE="$WORKDIR/failed.txt"

# ---------------- CLEANUP ON ABORT ----------------
cleanup() {
  echo "⚠️ Pipeline aborted. Killing background jobs..."
  kill $(jobs -p) 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

trim() { echo "$1" | xargs; }

# ---------------- ASSUME ROLE (RETURN CREDS) ----------------
assume_role() {
  local TARGET_ACCOUNT="$1"

  CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

  if [[ "$TARGET_ACCOUNT" == "$CURRENT_ACCOUNT" ]]; then
    echo "USE_CURRENT"
    return 0
  fi

  local ROLE_ARN="${ROLE_MAP[$TARGET_ACCOUNT]:-}"
  [[ -z "$ROLE_ARN" ]] && return 1

  aws sts assume-role \
    --role-arn "$ROLE_ARN" \
    --role-session-name "ami-backup-$(date +%s)" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>/dev/null
}

# ---------------- WAIT FOR AMI (WITH VISIBILITY) ----------------
wait_for_ami() {
  local ami_id="$1"
  local region="$2"
  local creds="$3"
  local waited=0

  while true; do
    state="$(
      eval "$creds aws ec2 describe-images \
        --image-ids $ami_id \
        --region $region \
        --query 'Images[0].State' \
        --output text 2>/dev/null || echo unknown"
    )"

    echo "⏳ Waiting for AMI $ami_id | Region=$region | State=$state | Elapsed=${waited}s"

    case "$state" in
      available)
        echo "✅ AMI $ami_id is available"
        return 0
        ;;
      failed)
        echo "❌ AMI $ami_id entered FAILED state"
        return 1
        ;;
    esac

    if (( waited >= AMI_MAX_WAIT_TIME )); then
      echo "❌ AMI $ami_id timeout after ${AMI_MAX_WAIT_TIME}s"
      return 1
    fi

    sleep "$AMI_POLL_INTERVAL"
    waited=$((waited + AMI_POLL_INTERVAL))
  done
}

# ---------------- PER-INSTANCE JOB ----------------
process_instance() {
  local LINE="$1"

  IFS=',' read -r f1 f2 f3 f4 f5 <<< "$LINE"
  ACCOUNT_ID="$(trim "$f1")"
  REGION="$(trim "$f2")"
  INSTANCE_ID="$(trim "$f3")"
  RETENTION="$(trim "$f4")"
  REASON="$(trim "$f5")"

  echo "▶ Processing $ACCOUNT_ID | $REGION | $INSTANCE_ID"

  if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ||
        ! "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ||
        ! "$RETENTION" =~ ^[0-9]+$ ]]; then
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (invalid input)" >> "$FAILED_FILE"
    return
  fi

  CREDS_RAW=$(assume_role "$ACCOUNT_ID") || {
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (assume-role failed)" >> "$FAILED_FILE"
    return
  }

  if [[ "$CREDS_RAW" == "USE_CURRENT" ]]; then
    CREDS_ENV=""
  else
    read AK SK ST <<< "$CREDS_RAW"
    CREDS_ENV="AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST"
  fi

  INSTANCE_STATE="$(
    eval "$CREDS_ENV aws ec2 describe-instances \
      --region $REGION \
      --instance-ids $INSTANCE_ID \
      --query 'Reservations[].Instances[].State.Name' \
      --output text 2>/dev/null"
  )"

  [[ ! "$INSTANCE_STATE" =~ ^(running|stopped|stopping)$ ]] && {
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (state=$INSTANCE_STATE)" >> "$FAILED_FILE"
    return
  }

  INSTANCE_NAME="$(
    eval "$CREDS_ENV aws ec2 describe-instances \
      --region $REGION \
      --instance-ids $INSTANCE_ID \
      --query \"Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]\" \
      --output text 2>/dev/null"
  )"

  [[ -z "$INSTANCE_NAME" || "$INSTANCE_NAME" == "None" ]] && INSTANCE_NAME="$INSTANCE_ID"

  SAFE_INSTANCE="$(echo "$INSTANCE_NAME" | tr ' /' '--')"
  SAFE_REASON="$(echo "$REASON" | tr ' /' '--')"
  AMI_NAME="${SAFE_INSTANCE}-${SAFE_REASON}-${DATE_TAG}-${TIME_TAG}-automated-ami"

  if [[ "$MODE" == "dry-run" ]]; then
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (dry-run)" >> "$SUCCESS_FILE"
    return
  fi

  AMI_ID="$(
    eval "$CREDS_ENV aws ec2 create-image \
      --region $REGION \
      --instance-id $INSTANCE_ID \
      --name \"$AMI_NAME\" \
      --description \"$REASON\" \
      --no-reboot \
      --query ImageId \
      --output text 2>/dev/null"
  )"

  [[ -z "$AMI_ID" ]] && {
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (create-image failed)" >> "$FAILED_FILE"
    return
  }

  eval "$CREDS_ENV aws ec2 create-tags \
    --region $REGION \
    --resources $AMI_ID \
    --tags \
      Key=Name,Value=\"$AMI_NAME\" \
      Key=AutomatedBackup,Value=true \
      Key=RetentionDays,Value=$RETENTION \
      Key=BackupReason,Value=\"$REASON\" \
      Key=CreatedBy,Value=AMI-Automation" || true

  wait_for_ami "$AMI_ID" "$REGION" "$CREDS_ENV" || {
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (ami-timeout)" >> "$FAILED_FILE"
    return
  }

  echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID ($AMI_ID)" >> "$SUCCESS_FILE"
}

# ---------------- MAIN ----------------
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config file not found"; exit 1; }

echo "====================================================="
echo "AMI BACKUP STARTED @ $(date)"
echo "Mode               : $MODE"
echo "Max Parallel Jobs  : $MAX_PARALLEL_JOBS"
echo "Parallel Strategy  : SLOT-BASED (wait -n)"
echo "====================================================="

while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE="$(trim "$RAWLINE")"
  [[ -z "$LINE" || "$LINE" == \#* ]] && continue

  while (( $(jobs -r | wc -l) >= MAX_PARALLEL_JOBS )); do
    wait -n
  done

  process_instance "$LINE" &
done < "$CONFIG_FILE"

wait

SUCCESS_COUNT=$(wc -l < "$SUCCESS_FILE" 2>/dev/null || echo 0)
FAILED_COUNT=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)

echo "====================================================="
echo "AMI BACKUP SUMMARY"
echo "Success : $SUCCESS_COUNT"
echo "Failed  : $FAILED_COUNT"
echo "====================================================="

[[ -s "$FAILED_FILE" ]] && cat "$FAILED_FILE"

rm -rf "$WORKDIR"

(( FAILED_COUNT > 0 )) && exit 2
exit 0
