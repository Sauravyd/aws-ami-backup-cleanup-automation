#!/usr/bin/env bash
# ==============================================================================
# aws_ami_backup_V3_3_parallel_slot_based_stable.sh
# Slot-based Parallel + Cross-Account SAFE AMI Backup Automation (STABLE)
# Jenkins-console summary compatible
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
AMI_POLL_INTERVAL=20
AMI_MAX_WAIT_TIME=900   # 15 minutes

# ---------------- LOGGING ----------------
LOGDIR="./ami_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-ami-${DATE_TAG}-${TIME_TAG}.log"

# Save original stdout for Jenkins
exec 3>&1

# Redirect detailed logs to file
exec >>"$LOGFILE" 2>&1

# ---------------- RESULT FILES ----------------
WORKDIR="/tmp/ami_parallel_$$"
mkdir -p "$WORKDIR"
SUCCESS_FILE="$WORKDIR/success.txt"
FAILED_FILE="$WORKDIR/failed.txt"

# ---------------- CLEANUP (ONLY ON ABORT) ----------------
cleanup() {
  echo "⚠️ Pipeline interrupted. Killing background jobs..." >&3
  jobs -p | xargs -r kill 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup INT TERM

trim() { echo "$1" | xargs; }

# ---------------- ASSUME ROLE ----------------
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

# ---------------- WAIT FOR AMI ----------------
wait_for_ami() {
  local ami_id="$1"
  local region="$2"
  local waited=0

  while true; do
    state="$(aws ec2 describe-images \
      --image-ids "$ami_id" \
      --region "$region" \
      --query 'Images[0].State' \
      --output text 2>/dev/null || echo unknown)"

    echo "⏳ Waiting for AMI $ami_id | Region=$region | State=$state | Elapsed=${waited}s"

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

  if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ || ! "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (invalid input)" >> "$FAILED_FILE"
    return
  fi

  CREDS_RAW=$(assume_role "$ACCOUNT_ID") || {
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (assume-role failed)" >> "$FAILED_FILE"
    return
  }

  if [[ "$CREDS_RAW" != "USE_CURRENT" ]]; then
    read AK SK ST <<< "$CREDS_RAW"
    export AWS_ACCESS_KEY_ID="$AK"
    export AWS_SECRET_ACCESS_KEY="$SK"
    export AWS_SESSION_TOKEN="$ST"
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (dry-run)" >> "$SUCCESS_FILE"
    return
  fi

  AMI_ID="$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "${INSTANCE_ID}-${DATE_TAG}-${TIME_TAG}-automated-ami" \
    --description "$REASON" \
    --no-reboot \
    --query ImageId \
    --output text 2>/dev/null)" || {
      echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (create-image failed)" >> "$FAILED_FILE"
      return
  }

  wait_for_ami "$AMI_ID" "$REGION" || {
    echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID (ami-timeout)" >> "$FAILED_FILE"
    return
  }

  echo "$ACCOUNT_ID:$REGION:$INSTANCE_ID ($AMI_ID)" >> "$SUCCESS_FILE"
}

# ---------------- MAIN ----------------
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config file not found" >&3; exit 1; }

echo "=====================================================" >&3
echo "AMI BACKUP STARTED @ $(date)" >&3
echo "Mode               : $MODE" >&3
echo "Max Parallel Jobs  : $MAX_PARALLEL_JOBS" >&3
echo "=====================================================" >&3

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
TOTAL=$((SUCCESS_COUNT + FAILED_COUNT))

# ---------------- FINAL SUMMARY (JENKINS VISIBLE) ----------------
echo "" >&3
echo "=====================================================" >&3
echo "AMI BACKUP SUMMARY" >&3
echo "Total     : $TOTAL" >&3
echo "Success   : $SUCCESS_COUNT" >&3
echo "Failed    : $FAILED_COUNT" >&3
echo "Log file  : $LOGFILE" >&3
echo "=====================================================" >&3

rm -rf "$WORKDIR"

(( FAILED_COUNT > 0 )) && exit 2
exit 0
