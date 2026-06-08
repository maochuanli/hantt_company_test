#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/1-packer-linux.log"
REGION="ap-southeast-6"

mkdir -p "$LOG_DIR"
: > "$LOG"   # truncate / create

log() { echo "$*" | tee -a "$LOG"; }

log "============================================================"
log "  Packer: Build Linux (Amazon Linux 2023) Nginx HTTPS AMI"
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

# ── Packer init ───────────────────────────────────────────────
log ""
log "=== packer init ==="
cd "$REPO_ROOT/packer/linux"
packer init linux.pkr.hcl 2>&1 | tee -a "$LOG"

# ── Packer build ──────────────────────────────────────────────
log ""
log "=== packer build ==="
packer build linux.pkr.hcl 2>&1 | tee -a "$LOG"

# ── Extract AMI ID ────────────────────────────────────────────
AMI_ID=$(grep -oE 'ami-[a-f0-9]+' "$LOG" | tail -1)
if [[ -z "$AMI_ID" ]]; then
  log "ERROR: could not extract AMI ID from build output"
  exit 1
fi
echo "$AMI_ID" > "$LOG_DIR/linux-ami-id.txt"

log ""
log "=== Result ==="
log "Linux AMI ID : $AMI_ID"
log "Log saved    : $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
