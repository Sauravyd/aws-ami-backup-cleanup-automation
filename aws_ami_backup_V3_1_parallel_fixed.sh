#!/usr/bin/env bash
# ==============================================================================
# aws_ami_backup_V3_1_parallel_fixed.sh
# Parallel + Cross-Account SAFE AMI Backup Automation
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

# ---------------- AMI WAIT CONFIG ----------------
AMI_POLL_INTERVAL=30
AMI_MAX_WAIT_TIME=3600

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

# ---------------- WAIT FOR AMI (ISOLATED CREDS) ----------------
wait_for_ami() {
  local ami_id="$1"
  local region="$2"
  local cred_prefix="$3"
  local waited=0

  while true; do
    state="$(
      eval "$cred_prefix aws ec2 describe-images \
        --image-ids $ami_id \
        --region $region \
        --query 'Images[0].State' \
        --output text 2>/dev/null || echo unknown"
    )"

    case "$state" in
      available) return 0 ;;
      failed)    return 1 ;;
    esac

    (( waited >= AMI_MAX_WAIT_TIME )) && return 1
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

  CREDS=$(assume_role "$ACCOUNT_ID") || {
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (assume-role failed)" >> "$FAILED_FILE"
    return
  }

  if [[ "$CREDS" == "USE_CURRENT" ]]; then
    CREDS_ENV=""
  else
    read AK SK ST <<< "$CREDS"
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
echo "====================================================="

JOB_COUNT=0

while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE="$(trim "$RAWLINE")"
  [[ -z "$LINE" || "$LINE" == \#* ]] && continue

  process_instance "$LINE" &
  ((JOB_COUNT++))

  if (( JOB_COUNT % MAX_PARALLEL_JOBS == 0 )); then
    wait
  fi
done < "$CONFIG_FILE"

wait

SUCCESS_COUNT=$(wc -l < "$SUCCESS_FILE" 2>/dev/null || echo 0)
FAILED_COUNT=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
TOTAL=$((SUCCESS_COUNT + FAILED_COUNT))

echo "====================================================="
echo "AMI BACKUP SUMMARY"
echo "Total   : $TOTAL"
echo "Success : $SUCCESS_COUNT"
echo "Failed  : $FAILED_COUNT"
echo "====================================================="

[[ -s "$FAILED_FILE" ]] && {
  echo "❌ Failed Resources:"
  cat "$FAILED_FILE"
}

rm -rf "$WORKDIR"

if (( SUCCESS_COUNT == 0 )); then
  exit 1
elif (( FAILED_COUNT > 0 )); then
  exit 2
else
  exit 0
fi
