#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/1b-prepare-sg.log"
REGION="ap-southeast-6"
TOKEN_FILE="/home/ansible/secrets/azure-aws/oidc-token"

mkdir -p "$LOG_DIR"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

log "============================================================"
log "  Prepare default VPC + security group for Linux AMI test"
log "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "============================================================"

# ── Auth ──────────────────────────────────────────────────────
log ""
log "=== Refreshing OIDC token ==="
/home/ansible/secrets/azure-aws/get-token.sh 2>&1 | tee -a "$LOG"

export AWS_STS_REGIONAL_ENDPOINTS=regional
export AWS_DEFAULT_REGION="$REGION"
export AWS_ROLE_ARN="arn:aws:iam::996992102979:role/terraform-svc-role"
export AWS_WEB_IDENTITY_TOKEN_FILE="$TOKEN_FILE"

# ── Default VPC and public subnet ─────────────────────────────
log ""
log "=== Resolving default VPC and public subnet ==="
DEFAULT_VPC=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text)
log "Default VPC: $DEFAULT_VPC"

SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters \
    "Name=vpc-id,Values=$DEFAULT_VPC" \
    "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[0].SubnetId' \
  --output text)
log "Public subnet: $SUBNET_ID"

# ── Security group ─────────────────────────────────────────────
log ""
log "=== Creating security group ==="
TIMESTAMP=$(date +%s)
SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "hantt-linux-ami-test-$TIMESTAMP" \
  --description "Linux AMI SSL cert test" \
  --vpc-id "$DEFAULT_VPC" \
  --query 'GroupId' \
  --output text)
log "Security group: $SG_ID"

aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$SG_ID" \
  --protocol tcp --port 443 \
  --cidr "0.0.0.0/0" \
  --no-cli-pager
log "Rule added: 0.0.0.0/0 → 443/tcp"

aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$SG_ID" \
  --protocol tcp --port 22 \
  --cidr "0.0.0.0/0" \
  --no-cli-pager
log "Rule added: 0.0.0.0/0 → 22/tcp"

# ── Persist IDs for launch script ──────────────────────────────
echo "$SG_ID"     > "$LOG_DIR/1b-sg-id.txt"
echo "$SUBNET_ID" > "$LOG_DIR/1b-subnet-id.txt"

log ""
log "Saved: logs/1b-sg-id.txt     → $SG_ID"
log "Saved: logs/1b-subnet-id.txt → $SUBNET_ID"
log ""
log "Log saved: $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
