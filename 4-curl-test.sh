#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/4-curl-test.log"
REGION="ap-southeast-6"
TOKEN_FILE="/home/ansible/secrets/azure-aws/oidc-token"

mkdir -p "$LOG_DIR"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

log "============================================================"
log "  HTTPS Curl Tests"
log "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "============================================================"

# ── Read NLB DNS ──────────────────────────────────────────────
NLB_DNS="$(cat "$LOG_DIR/nlb-dns.txt")"
log ""
log "Target: https://$NLB_DNS"

# ── Auth (needed for target health check via AWS CLI) ────────
/home/ansible/secrets/azure-aws/get-token.sh 2>&1 | tee -a "$LOG"

export AWS_STS_REGIONAL_ENDPOINTS=regional
export AWS_DEFAULT_REGION="$REGION"
export AWS_ROLE_ARN="arn:aws:iam::996992102979:role/terraform-svc-role"
export AWS_WEB_IDENTITY_TOKEN_FILE="$TOKEN_FILE"

# ── Wait for healthy targets ──────────────────────────────────
log ""
log "=== Waiting for NLB targets to become healthy ==="

TG_ARN=$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --names "hantt-main-vpc-tg-443" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>&1 | tee -a "$LOG")

log "Target group: $TG_ARN"

WAIT_SECS=0
MAX_WAIT=600   # 10 min ceiling for Windows boot
while true; do
  HEALTHY=$(aws elbv2 describe-target-health \
    --region "$REGION" \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' \
    --output text 2>/dev/null || echo 0)

  TOTAL=$(aws elbv2 describe-target-health \
    --region "$REGION" \
    --target-group-arn "$TG_ARN" \
    --query 'length(TargetHealthDescriptions)' \
    --output text 2>/dev/null || echo 0)

  log "  [${WAIT_SECS}s] healthy targets: $HEALTHY / $TOTAL"

  if [[ "$HEALTHY" -ge 2 ]]; then
    log "  Both targets healthy — proceeding"
    break
  fi

  if [[ "$WAIT_SECS" -ge "$MAX_WAIT" ]]; then
    log "  Timeout reached — proceeding with $HEALTHY healthy target(s)"
    break
  fi

  sleep 20
  WAIT_SECS=$(( WAIT_SECS + 20 ))
done

# ── Curl requests ─────────────────────────────────────────────
log ""
log "=== Running 8 HTTPS requests (round-robin across Linux + Windows) ==="
log ""

for i in $(seq 1 8); do
  log "--- Request $i / 8  $(date -u '+%H:%M:%S UTC') ---"
  curl --silent --insecure \
       --max-time 10 \
       --write-out "\n[HTTP %{http_code}  %{time_total}s]\n" \
       "https://$NLB_DNS" \
    2>&1 | tee -a "$LOG"
  log ""
  sleep 3
done

log "=== Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
log "Log saved: $LOG"
