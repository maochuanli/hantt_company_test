#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/6-ami-cleanup.log"
REGION="ap-southeast-6"

mkdir -p "$LOG_DIR"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

log "============================================================"
log "  AMI Deregister + Snapshot + Secret Cleanup"
log "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "============================================================"

# ── Auth ──────────────────────────────────────────────────────
log ""
log "=== Refreshing OIDC token ==="
/home/ansible/secrets/azure-aws/get-token.sh 2>&1 | tee -a "$LOG"

export AWS_STS_REGIONAL_ENDPOINTS=regional
export AWS_DEFAULT_REGION="$REGION"
export AWS_ROLE_ARN="arn:aws:iam::996992102979:role/terraform-svc-role"
export AWS_WEB_IDENTITY_TOKEN_FILE="/home/ansible/secrets/azure-aws/oidc-token"

# ── Read AMI IDs ──────────────────────────────────────────────
LINUX_AMI="$(cat "$LOG_DIR/linux-ami-id.txt")"
WINDOWS_AMI="$(cat "$LOG_DIR/windows-ami-id.txt")"

log ""
log "AMIs to clean up:"
log "  Linux  : $LINUX_AMI"
log "  Windows: $WINDOWS_AMI"

# ── Deregister + delete snapshots for each AMI ───────────────
for AMI_ID in "$LINUX_AMI" "$WINDOWS_AMI"; do
  log ""
  log "--- Processing $AMI_ID ---"

  # Collect snapshot IDs before deregistering
  SNAPSHOTS=$(aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
    --output text 2>&1 | tee -a "$LOG")

  log "  Snapshots: $SNAPSHOTS"

  # Deregister the AMI
  log "  Deregistering AMI $AMI_ID ..."
  aws ec2 deregister-image \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    2>&1 | tee -a "$LOG"
  log "  Deregistered: $AMI_ID"

  # Delete each snapshot
  for SNAP_ID in $SNAPSHOTS; do
    [[ "$SNAP_ID" == "None" || -z "$SNAP_ID" ]] && continue
    log "  Deleting snapshot $SNAP_ID ..."
    aws ec2 delete-snapshot \
      --region "$REGION" \
      --snapshot-id "$SNAP_ID" \
      2>&1 | tee -a "$LOG"
    log "  Deleted: $SNAP_ID"
  done
done

log ""
log "=== Deleting Secrets Manager secret ==="
aws secretsmanager delete-secret \
  --region "$REGION" \
  --secret-id hantt/nginx-ssl-cert \
  --force-delete-without-recovery \
  2>&1 | tee -a "$LOG"
log "Deleted secret: hantt/nginx-ssl-cert"

log ""
log "=== Result ==="
log "All AMIs, snapshots, and secrets removed from $REGION"
log "Log saved: $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
