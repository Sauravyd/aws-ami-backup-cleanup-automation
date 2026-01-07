#!/usr/bin/env bash
# ==============================================================================
# aws_ami_backup_V3_3_parallel_slot_based_stable.sh
# Parallel AMI Backup – SAFE, FAST, PRODUCTION
# HARD GUARD: AMI created ONLY if InstanceId is explicitly provided
# ATOMIC per-line logging (NO interleaving)
# RUN logic fully restored
# ==============================================================================

set -uo pipefail

CONFIG_FILE="${1:-serverlist.txt}"
MODE="${2:-dry-run}"

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H%M)"

MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-5}"

declare -A ROLE_MAP
ROLE_MAP["782511039777"]="arn:aws:iam::782511039777:role/CrossAccount-AMICleanupRole"

AMI_POLL_INTERVAL=30
AMI_MAX_WAIT_TIME=1800   # 30 min hard cap

LOGDIR="./ami_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-ami-${DATE_TAG}-${TIME_TAG}.log"

# Jenkins console + file logging
exec 3>&1
exec >>"$LOGFILE" 2>&1

WORKDIR="/tmp/ami_parallel_$$"
mkdir -p "$WORKDIR"
SUCCESS_FILE="$WORKDIR/success.txt"
FAILED_FILE="$WORKDIR/failed.txt"
SKIPPED_FILE="$WORKDIR/skipped.txt"

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
  local CURRENT_ACCOUNT

  CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

  [[ "$TARGET_ACCOUNT" == "$CURRENT_ACCOUNT" ]] && {
    echo "USE_CURRENT"
    return 0
  }

  aws sts assume-role \
    --role-arn "${ROLE_MAP[$TARGET_ACCOUNT]}" \
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

    case "$state" in
      available) return 0 ;;
      failed)    return 1 ;;
    esac

    (( waited >= AMI_MAX_WAIT_TIME )) && return 1
    sleep "$AMI_POLL_INTERVAL"
    waited=$((waited + AMI_POLL_INTERVAL))
  done
}

# ---------------- PER INSTANCE (ATOMIC LOGGING) ----------------
process_instance() {
  local LINE_NO="$1"
  local LINE="$2"
  local BUF
  BUF="$(mktemp)"

  IFS=',' read -r f1 f2 f3 f4 f5 <<< "$LINE"
  ACCOUNT_ID="$(trim "$f1")"
  REGION="$(trim "$f2")"
  INSTANCE_ID="$(trim "$f3")"
  RETENTION="$(trim "$f4")"
  REASON="$(trim "$f5")"

  {
    echo "====================================================="
    echo "[LINE $LINE_NO]"
    echo "ACCOUNT : $ACCOUNT_ID"
    echo "REGION  : $REGION"
    echo "INSTANCE: ${INSTANCE_ID:-'-'}"
  } >>"$BUF"

  # ---------------- HARD GUARD ----------------
  if [[ -z "$INSTANCE_ID" || ! "$INSTANCE_ID" =~ ^i-[a-f0-9]{8,}$ ]]; then
    {
      echo "STATUS  : SKIPPED"
      echo "REASON  : Missing or invalid InstanceId in config file"
      echo "====================================================="
    } >>"$BUF"

    cat "$BUF" >&3
    rm -f "$BUF"
    echo "$LINE_NO|$ACCOUNT_ID|$REGION|$INSTANCE_ID|SKIPPED|invalid-instance-id" >>"$SKIPPED_FILE"
    return
  fi

  CREDS_RAW=$(assume_role "$ACCOUNT_ID") || {
    {
      echo "STATUS  : FAILED"
      echo "REASON  : AssumeRole failed"
      echo "====================================================="
    } >>"$BUF"

    cat "$BUF" >&3
    rm -f "$BUF"
    echo "$LINE_NO|$ACCOUNT_ID|$REGION|$INSTANCE_ID|FAILED|assume-role" >>"$FAILED_FILE"
    return
  }

  if [[ "$CREDS_RAW" != "USE_CURRENT" ]]; then
    read AK SK ST <<< "$CREDS_RAW"
    export AWS_ACCESS_KEY_ID="$AK"
    export AWS_SECRET_ACCESS_KEY="$SK"
    export AWS_SESSION_TOKEN="$ST"
  fi

  INSTANCE_STATE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].State.Name" \
    --output text 2>/dev/null)

  if [[ -z "$INSTANCE_STATE" || "$INSTANCE_STATE" == "None" ]]; then
    {
      echo "STATUS  : SKIPPED"
      echo "REASON  : Instance not found (terminated / wrong region)"
      echo "====================================================="
    } >>"$BUF"

    cat "$BUF" >&3
    rm -f "$BUF"
    echo "$LINE_NO|$ACCOUNT_ID|$REGION|$INSTANCE_ID|SKIPPED|not-found" >>"$SKIPPED_FILE"
    return
  fi

  # ---------------- DRY RUN ----------------
  if [[ "$MODE" == "dry-run" ]]; then
    {
      echo "STATUS  : SUCCESS"
      echo "ACTION  : DRY-RUN (AMI would be created)"
      echo "AMI     : N/A"
      echo "====================================================="
    } >>"$BUF"

    cat "$BUF" >&3
    rm -f "$BUF"
    echo "$LINE_NO|$ACCOUNT_ID|$REGION|$INSTANCE_ID|SUCCESS|dry-run" >>"$SUCCESS_FILE"
    return
  fi

  # ---------------- RUN MODE ----------------
  INSTANCE_NAME="$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]" \
    --output text 2>/dev/null)"

  [[ -z "$INSTANCE_NAME" || "$INSTANCE_NAME" == "None" ]] && INSTANCE_NAME="$INSTANCE_ID"

  SAFE_INSTANCE="$(echo "$INSTANCE_NAME" | tr ' /' '--')"
  SAFE_REASON="$(echo "$REASON" | tr ' /' '--')"
  AMI_NAME="${SAFE_INSTANCE}-${SAFE_REASON}-${DATE_TAG}-${TIME_TAG}-automated-ami"

  AMI_ID=$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "$REASON" \
    --no-reboot \
    --query ImageId \
    --output text 2>/dev/null)

  if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    {
      echo "STATUS  : FAILED"
      echo "REASON  : create-image API failed"
      echo "====================================================="
    } >>"$BUF"

    cat "$BUF" >&3
    rm -f "$BUF"
    echo "$LINE_NO|$ACCOUNT_ID|$REGION|$INSTANCE_ID|FAILED|create-image" >>"$FAILED_FILE"
    return
  fi

  aws ec2 create-tags \
    --region "$REGION" \
    --resources "$AMI_ID" \
    --tags \
      Key=Name,Value="$AMI_NAME" \
      Key=AutomatedBackup,Value=true \
      Key=RetentionDays,Value="$RETENTION" \
      Key=BackupReason,Value="$REASON" \
      Key=CreatedBy,Value=AMI-Automation || true

  if wait_for_ami "$AMI_ID" "$REGION"; then
    {
      echo "STATUS  : SUCCESS"
      echo "AMI     : $AMI_ID"
      echo "====================================================="
    } >>"$BUF"

    cat "$BUF" >&3
    rm -f "$BUF"
    echo "$LINE_NO|$ACCOUNT_ID|$REGION|$INSTANCE_ID|SUCCESS|$AMI_ID" >>"$SUCCESS_FILE"
  else
    {
      echo "STATUS  : FAILED"
      echo "REASON  : AMI did not reach 'available' within timeout"
      echo "AMI     : $AMI_ID"
      echo "====================================================="
    } >>"$BUF"

    cat "$BUF" >&3
    rm -f "$BUF"
    echo "$LINE_NO|$ACCOUNT_ID|$REGION|$INSTANCE_ID|FAILED|ami-timeout" >>"$FAILED_FILE"
  fi
}

# ========================= MAIN =========================
echo "Starting AMI creation @ $(date)" >&3
echo "Mode       : $MODE" >&3
echo "Config     : $CONFIG_FILE" >&3
echo "Log file   : $LOGFILE" >&3
echo "=====================================================" >&3

LINE_NO=0
while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE="$(trim "$RAWLINE")"
  [[ -z "$LINE" || "$LINE" == \#* ]] && continue

  LINE_NO=$((LINE_NO + 1))

  while (( $(jobs -r | wc -l) >= MAX_PARALLEL_JOBS )); do
    wait -n
  done

  process_instance "$LINE_NO" "$LINE" &
done < "$CONFIG_FILE"

wait

SUCCESS_COUNT=$(wc -l <"$SUCCESS_FILE" 2>/dev/null || echo 0)
FAILED_COUNT=$(wc -l <"$FAILED_FILE" 2>/dev/null || echo 0)
SKIPPED_COUNT=$(wc -l <"$SKIPPED_FILE" 2>/dev/null || echo 0)

echo "=====================================================" >&3
echo "AMI BACKUP SUMMARY" >&3
echo "Total     : $((SUCCESS_COUNT + FAILED_COUNT + SKIPPED_COUNT))" >&3
echo "Success   : $SUCCESS_COUNT" >&3
echo "Skipped   : $SKIPPED_COUNT" >&3
echo "Failed    : $FAILED_COUNT" >&3
echo "=====================================================" >&3

[[ "$MODE" == "dry-run" ]] && echo "⚠️ THIS WAS A DRY RUN – NO AMIs WERE CREATED" >&3

rm -rf "$WORKDIR"

(( FAILED_COUNT > 0 )) && exit 2
exit 0
