#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/3-terraform-apply.log"
TOKEN_FILE="/home/ansible/secrets/azure-aws/oidc-token"

mkdir -p "$LOG_DIR"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

log "============================================================"
log "  Terraform Apply"
log "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "============================================================"

# ── Read AMI IDs produced by Packer ──────────────────────────
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

# ── Terraform init ────────────────────────────────────────────
log ""
log "=== terraform init ==="
cd "$REPO_ROOT/terraform/vpc"
terraform init -upgrade 2>&1 | tee -a "$LOG"

# ── Terraform apply ───────────────────────────────────────────
log ""
log "=== terraform apply ==="
terraform apply -auto-approve \
  -var="web_identity_token_file=$TOKEN_FILE" \
  -var="nginx_ami_id=$WINDOWS_AMI" \
  -var="linux_ami_id=$LINUX_AMI" \
  2>&1 | tee -a "$LOG"

# ── Save NLB DNS for curl test ────────────────────────────────
NLB_DNS=$(terraform output -raw nlb_dns_name)
echo "$NLB_DNS" > "$LOG_DIR/nlb-dns.txt"

log ""
log "=== Result ==="
log "NLB DNS  : $NLB_DNS"
log "Log saved: $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
