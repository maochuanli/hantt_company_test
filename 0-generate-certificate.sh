#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SSL_DIR="$REPO_ROOT/packer/shared/ssl"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/0-generate-certificate.log"
REGION="ap-southeast-6"
SECRET_NAME="hantt/nginx-ssl-cert"

mkdir -p "$SSL_DIR" "$LOG_DIR"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

log "============================================================"
log "  Generate Self-Signed SSL Certificate"
log "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "============================================================"
log ""
log "Output directory: $SSL_DIR"
log ""

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$SSL_DIR/server.key" \
  -out    "$SSL_DIR/server.crt" \
  -subj   "/CN=hantt-nginx/O=hantt/C=NZ" \
  2>&1 | tee -a "$LOG"

log ""
log "=== Certificate details ==="
openssl x509 -in "$SSL_DIR/server.crt" -noout -subject -issuer -dates \
  2>&1 | tee -a "$LOG"

log ""
log "Files written:"
log "  $SSL_DIR/server.crt"
log "  $SSL_DIR/server.key"

# ── AWS auth ──────────────────────────────────────────────────
log ""
log "=== Refreshing OIDC token ==="
/home/ansible/secrets/azure-aws/get-token.sh 2>&1 | tee -a "$LOG"

export AWS_STS_REGIONAL_ENDPOINTS=regional
export AWS_DEFAULT_REGION="$REGION"
export AWS_ROLE_ARN="arn:aws:iam::996992102979:role/terraform-svc-role"
export AWS_WEB_IDENTITY_TOKEN_FILE="/home/ansible/secrets/azure-aws/oidc-token"

# ── Upload to Secrets Manager ─────────────────────────────────
log ""
log "=== Uploading certificate to Secrets Manager ($SECRET_NAME) ==="

SECRET_VALUE=$(python3 -c "
import json
cert = open('$SSL_DIR/server.crt').read()
key  = open('$SSL_DIR/server.key').read()
print(json.dumps({'cert': cert, 'key': key}))
")

if aws secretsmanager describe-secret \
     --secret-id "$SECRET_NAME" \
     --no-cli-pager > /dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_VALUE" \
    --no-cli-pager 2>&1 | tee -a "$LOG"
  log "Secret updated: $SECRET_NAME"
else
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Nginx SSL certificate and private key" \
    --secret-string "$SECRET_VALUE" \
    --no-cli-pager 2>&1 | tee -a "$LOG"
  log "Secret created: $SECRET_NAME"
fi

log ""
log "Log saved: $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
