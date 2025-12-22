#!/usr/bin/env bash
# ==============================================================================
# aws_ami_backup_V2.sh – Production-Ready Cross-Account AMI Backup Automation
# Skip-per-resource + Fail-at-summary
# ==============================================================================

set -uo pipefail   # ❗ removed -e (VERY IMPORTANT)

CONFIG_FILE="${1:-serverlist.txt}"
MODE="${2:-dry-run}"

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H%M)"

# ---------------- ROLE MAP ----------------
declare -A ROLE_MAP
ROLE_MAP["782511039777"]="arn:aws:iam::782511039777:role/CrossAccount-AMICleanupRole"

# ---------------- AMI WAIT CONFIG ----------------
AMI_POLL_INTERVAL=30
AMI_MAX_WAIT_TIME=3600

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

# ---------------- GLOBAL COUNTERS ----------------
TOTAL=0
SUCCESS=0
FAILED=0
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
    --role-session-name "ami-backup-$(date +%s)" \
    --query 'Credentials' \
    --output json 2>/dev/null) || return 1

  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.SessionToken')

  echo "✅ Switched to AWS Account: $(aws sts get-caller-identity --query Account --output text)"
}

# ---------------- AMI WAIT FUNCTION ----------------
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
      pending)   ;;
      *)         ;;
    esac

    (( waited >= AMI_MAX_WAIT_TIME )) && return 1
    sleep "$AMI_POLL_INTERVAL"
    waited=$((waited + AMI_POLL_INTERVAL))
  done
}

# ---------------- VALIDATION ----------------
[[ -f "$CONFIG_FILE" ]] || { echo "❌ Config file not found"; exit 1; }

LINE_NO=0

while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE_NO=$((LINE_NO+1))
  LINE="$(trim "$RAWLINE")"
  [[ -z "$LINE" || "$LINE" == \#* ]] && continue

  TOTAL=$((TOTAL+1))
  IFS=',' read -r f1 f2 f3 f4 f5 <<< "$LINE"

  ACCOUNT_ID="$(trim "$f1")"
  REGION="$(trim "$f2")"
  INSTANCE_ID="$(trim "$f3")"
  RETENTION="$(trim "$f4")"
  REASON="$(trim "$f5")"

  echo "-----------------------------------------------------"
  echo "Line $LINE_NO → Account $ACCOUNT_ID | Instance $INSTANCE_ID"

  # -------- Field validation (SKIP on error) --------
  if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ||
        ! "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ||
        ! "$RETENTION" =~ ^[0-9]+$ ]]; then
    echo "❌ Invalid input fields"
    FAILED=$((FAILED+1))
    FAILED_LIST+=("$ACCOUNT_ID:$REGION:$INSTANCE_ID (invalid input)")
    continue
  fi

  assume_role "$ACCOUNT_ID" || {
    echo "❌ AssumeRole failed"
    FAILED=$((FAILED+1))
    FAILED_LIST+=("$ACCOUNT_ID:$REGION:$INSTANCE_ID (assume-role)")
    continue
  }

  # -------- Instance existence & state --------
  INSTANCE_STATE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].State.Name" \
    --output text 2>/dev/null)

  if [[ ! "$INSTANCE_STATE" =~ ^(running|stopped|stopping)$ ]]; then
    echo "❌ Invalid instance state: $INSTANCE_STATE"
    FAILED=$((FAILED+1))
    FAILED_LIST+=("$ACCOUNT_ID:$REGION:$INSTANCE_ID (state=$INSTANCE_STATE)")
    continue
  fi

  INSTANCE_NAME="$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]" \
    --output text 2>/dev/null)"

  [[ -z "$INSTANCE_NAME" || "$INSTANCE_NAME" == "None" ]] && INSTANCE_NAME="$INSTANCE_ID"

  SAFE_INSTANCE="$(echo "$INSTANCE_NAME" | tr ' /' '--')"
  SAFE_REASON="$(echo "$REASON" | tr ' /' '--')"

  AMI_NAME="${SAFE_INSTANCE}-${SAFE_REASON}-${DATE_TAG}-${TIME_TAG}-automated-ami"

  if [[ "$MODE" == "dry-run" ]]; then
    echo "🟡 DRY-RUN: AMI would be created"
    SUCCESS=$((SUCCESS+1))
    continue
  fi

  AMI_ID=$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "$REASON" \
    --no-reboot \
    --query ImageId \
    --output text 2>/dev/null)

  [[ -z "$AMI_ID" ]] && {
    echo "❌ AMI creation failed"
    FAILED=$((FAILED+1))
    FAILED_LIST+=("$ACCOUNT_ID:$REGION:$INSTANCE_ID (create-image)")
    continue
  }

  aws ec2 create-tags \
    --region "$REGION" \
    --resources "$AMI_ID" \
    --tags \
      Key=Name,Value="$AMI_NAME" \
      Key=AutomatedBackup,Value=true \
      Key=RetentionDays,Value="$RETENTION" \
      Key=BackupReason,Value="$REASON" \
      Key=CreatedBy,Value=AMI-Automation || true

  wait_for_ami "$AMI_ID" "$REGION" || {
    echo "❌ AMI did not become available"
    FAILED=$((FAILED+1))
    FAILED_LIST+=("$ACCOUNT_ID:$REGION:$INSTANCE_ID (ami-timeout)")
    continue
  }

  echo "✅ AMI SUCCESS: $AMI_ID"
  SUCCESS=$((SUCCESS+1))

done < "$CONFIG_FILE"

# ---------------- FINAL SUMMARY ----------------
echo "====================================================="
echo "AMI BACKUP SUMMARY"
echo "Total     : $TOTAL"
echo "Success   : $SUCCESS"
echo "Failed    : $FAILED"
echo "====================================================="

if [[ "$MODE" == "dry-run" ]]; then
  echo "⚠️ THIS WAS A DRY RUN – NO AMIs WERE CREATED"
fi

if (( FAILED > 0 )); then
  echo "❌ Failed Resources:"
  for f in "${FAILED_LIST[@]}"; do
    echo " - $f"
  done
fi

# ---------------- EXIT LOGIC ----------------
if (( SUCCESS == 0 )); then
  echo "❌ All AMI operations failed"
  exit 1
elif (( FAILED > 0 )); then
  echo "⚠️ Partial failures detected"
  exit 2   # Jenkins = UNSTABLE
else
  echo "✅ All AMIs created successfully"
  exit 0
fi
