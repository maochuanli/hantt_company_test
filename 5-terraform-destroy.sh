#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/5-terraform-destroy.log"
TOKEN_FILE="/home/ansible/secrets/azure-aws/oidc-token"

mkdir -p "$LOG_DIR"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

log "============================================================"
log "  Terraform Destroy"
log "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "============================================================"

# ── Read AMI IDs (required by variable definitions) ───────────
LINUX_AMI="$(cat "$LOG_DIR/linux-ami-id.txt")"
WINDOWS_AMI="$(cat "$LOG_DIR/windows-ami-id.txt")"
log ""
log "Linux AMI  : $LINUX_AMI"
log "Windows AMI: $WINDOWS_AMI"

# ── Auth ──────────────────────────────────────────────────────
log ""
log "=== Refreshing OIDC token ==="
/home/ansible/secrets/azure-aws/get-token.sh 2>&1 | tee -a "$LOG"

export AWS_STS_REGIONAL_ENDPOINTS=regional

# ── Terraform destroy ─────────────────────────────────────────
log ""
log "=== terraform destroy ==="
cd "$REPO_ROOT/terraform/vpc"
terraform destroy -auto-approve \
  -var="web_identity_token_file=$TOKEN_FILE" \
  -var="nginx_ami_id=$WINDOWS_AMI" \
  -var="linux_ami_id=$LINUX_AMI" \
  2>&1 | tee -a "$LOG"

log ""
log "=== Result ==="
log "All infrastructure destroyed"
log "Log saved: $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
