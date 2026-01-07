#!/usr/bin/env bash
# ==============================================================================
# aws_ami_backup_V3_3_parallel_slot_based_stable.sh
# Parallel AMI Backup with V2-style Jenkins output
# Skip-per-resource + Fail-at-summary (PRODUCTION SAFE)
# ==============================================================================

set -uo pipefail

CONFIG_FILE="${1:-serverlist.txt}"
MODE="${2:-dry-run}"

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H%M)"

MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-5}"

declare -A ROLE_MAP
ROLE_MAP["782511039777"]="arn:aws:iam::782511039777:role/CrossAccount-AMICleanupRole"

AMI_POLL_INTERVAL=20
AMI_MAX_WAIT_TIME=900

LOGDIR="./ami_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-ami-${DATE_TAG}-${TIME_TAG}.log"

# Jenkins console output
exec 3>&1
# File logging
exec >>"$LOGFILE" 2>&1

WORKDIR="/tmp/ami_parallel_$$"
mkdir -p "$WORKDIR"
SUCCESS_FILE="$WORKDIR/success.txt"
FAILED_FILE="$WORKDIR/failed.txt"

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

  if [[ "$TARGET_ACCOUNT" == "$CURRENT_ACCOUNT" ]]; then
    echo "USE_CURRENT"
    return 0
  fi

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

    [[ "$state" == "available" ]] && return 0
    [[ "$state" == "failed" ]] && return 1

    (( waited >= AMI_MAX_WAIT_TIME )) && return 1
    sleep "$AMI_POLL_INTERVAL"
    waited=$((waited + AMI_POLL_INTERVAL))
  done
}

# ---------------- PER INSTANCE ----------------
process_instance() {
  local LINE_NO="$1"
  local LINE="$2"

  IFS=',' read -r f1 f2 f3 f4 f5 <<< "$LINE"
  ACCOUNT_ID="$(trim "$f1")"
  REGION="$(trim "$f2")"
  INSTANCE_ID="$(trim "$f3")"
  REASON="$(trim "$f5")"

  echo "-----------------------------------------------------" >&3
  echo "Line $LINE_NO → Account $ACCOUNT_ID | Instance $INSTANCE_ID" >&3

  # ---------------- ASSUME ROLE ----------------
  CREDS_RAW=$(assume_role "$ACCOUNT_ID") || {
    echo "❌ Assume role failed — skipping" >&3
    echo "$ACCOUNT_ID:$INSTANCE_ID (assume-role-failed)" >>"$FAILED_FILE"
    return
  }

  if [[ "$CREDS_RAW" == "USE_CURRENT" ]]; then
    echo "ℹ️ Using existing Jenkins credentials for account $ACCOUNT_ID" >&3
  else
    echo "✅ Switched to AWS Account: $ACCOUNT_ID" >&3
    read AK SK ST <<< "$CREDS_RAW"
    export AWS_ACCESS_KEY_ID="$AK"
    export AWS_SECRET_ACCESS_KEY="$SK"
    export AWS_SESSION_TOKEN="$ST"
  fi

  # ---------------- INSTANCE EXISTENCE CHECK ----------------
  INSTANCE_STATE="$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[].Instances[].State.Name' \
    --output text 2>/dev/null)"

  if [[ -z "$INSTANCE_STATE" || "$INSTANCE_STATE" == "None" ]]; then
    echo "❌ Instance not found (likely terminated). Skipping." >&3
    echo "$ACCOUNT_ID:$INSTANCE_ID (not-found)" >>"$FAILED_FILE"
    return
  fi

  if [[ ! "$INSTANCE_STATE" =~ ^(running|stopped|stopping)$ ]]; then
    echo "❌ Invalid instance state: $INSTANCE_STATE. Skipping." >&3
    echo "$ACCOUNT_ID:$INSTANCE_ID (state=$INSTANCE_STATE)" >>"$FAILED_FILE"
    return
  fi

  # ---------------- DRY RUN ----------------
  if [[ "$MODE" == "dry-run" ]]; then
    echo "ℹ️ DRY RUN – AMI would be created (no action taken)" >&3
    echo "$ACCOUNT_ID:$INSTANCE_ID (dry-run)" >>"$SUCCESS_FILE"
    return
  fi

  # ---------------- CREATE AMI ----------------
  AMI_ID="$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "${INSTANCE_ID}-${DATE_TAG}-${TIME_TAG}-automated-ami" \
    --description "$REASON" \
    --no-reboot \
    --query ImageId \
    --output text 2>/dev/null)"

  if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "❌ AMI creation failed immediately" >&3
    echo "$ACCOUNT_ID:$INSTANCE_ID (create-image-failed)" >>"$FAILED_FILE"
    return
  fi

  # ---------------- WAIT FOR AMI ----------------
  if wait_for_ami "$AMI_ID" "$REGION"; then
    echo "✅ AMI SUCCESS: $AMI_ID" >&3
    echo "$ACCOUNT_ID:$INSTANCE_ID:$AMI_ID" >>"$SUCCESS_FILE"
  else
    echo "❌ AMI FAILED for $INSTANCE_ID" >&3
    echo "$ACCOUNT_ID:$INSTANCE_ID (ami-timeout)" >>"$FAILED_FILE"
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
TOTAL=$((SUCCESS_COUNT + FAILED_COUNT))

echo "=====================================================" >&3
echo "AMI BACKUP SUMMARY" >&3
echo "Total     : $TOTAL" >&3
echo "Success   : $SUCCESS_COUNT" >&3
echo "Failed    : $FAILED_COUNT" >&3
echo "=====================================================" >&3

[[ "$MODE" == "dry-run" ]] && \
echo "ℹ️ DRY RUN completed — no AMIs were created" >&3

rm -rf "$WORKDIR"

(( FAILED_COUNT > 0 )) && exit 2
exit 0
