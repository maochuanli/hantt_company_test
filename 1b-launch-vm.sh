#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/1b-launch-vm.log"
REGION="ap-southeast-6"
TOKEN_FILE="/home/ansible/secrets/azure-aws/oidc-token"
AMI_ID="$(cat "$LOG_DIR/linux-ami-id.txt")"
INSTANCE_TYPE="t3.small"
IAM_PROFILE="hantt-main-vpc-nginx-vm-profile"
KEY_NAME="hantt-ansible"
SG_ID="$(cat "$LOG_DIR/1b-sg-id.txt")"
SUBNET_ID="$(cat "$LOG_DIR/1b-subnet-id.txt")"

mkdir -p "$LOG_DIR"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

# Fetch /var/log/user-data.log + nginx status via SSM
fetch_instance_log() {
  local instance_id="$1"
  log ""
  log "=== Fetching instance diagnostics via SSM ==="

  local ssm_ok=false
  for i in $(seq 1 18); do
    local ping
    ping=$(aws ssm describe-instance-information \
      --region "$REGION" \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo "None")
    log "  SSM ping [$i/18]: $ping"
    [[ "$ping" == "Online" ]] && { ssm_ok=true; break; }
    sleep 10
  done

  if ! $ssm_ok; then
    log "  SSM agent not reachable — cannot fetch log"
    return
  fi

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
      "echo === /var/log/user-data.log ===",
      "cat /var/log/user-data.log 2>/dev/null || echo (not written)",
      "echo === nginx status ===",
      "systemctl status nginx --no-pager 2>&1 || true",
      "echo === port 443 listeners ===",
      "ss -tlnp 2>&1 | grep -E (443|LISTEN) || echo (none)",
      "echo === /etc/nginx/ssl/ ===",
      "ls -la /etc/nginx/ssl/ 2>&1 || echo (missing)"
    ]' \
    --query 'Command.CommandId' \
    --output text 2>/dev/null || echo "")

  [[ -z "$cmd_id" ]] && { log "  SSM send-command failed"; return; }
  log "  SSM command: $cmd_id — waiting 10s ..."
  sleep 10

  aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$cmd_id" \
    --instance-id "$instance_id" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null | tee -a "$LOG" || log "  Could not retrieve SSM output"
}

log "============================================================"
log "  Launch Linux AMI: Secrets Manager SSL → nginx HTTPS"
log "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "============================================================"
log "AMI:           $AMI_ID"
log "Instance type: $INSTANCE_TYPE"
log "IAM profile:   $IAM_PROFILE"
log "Security group: $SG_ID"
log "Subnet:        $SUBNET_ID"
log ""

# ── Auth ──────────────────────────────────────────────────────
log "=== Refreshing OIDC token ==="
/home/ansible/secrets/azure-aws/get-token.sh 2>&1 | tee -a "$LOG"

export AWS_STS_REGIONAL_ENDPOINTS=regional
export AWS_DEFAULT_REGION="$REGION"
export AWS_ROLE_ARN="arn:aws:iam::996992102979:role/terraform-svc-role"
export AWS_WEB_IDENTITY_TOKEN_FILE="$TOKEN_FILE"

# ── User-data ─────────────────────────────────────────────────
USER_DATA_FILE=$(mktemp)

cat > "$USER_DATA_FILE" <<'USERDATA'
#!/bin/bash
exec > /var/log/user-data.log 2>&1
set -x

echo "=== [$(date -u '+%Y-%m-%d %H:%M:%S UTC')] user-data start ==="

echo "--- Fetching SSL cert from Secrets Manager ---"
export AWS_STS_REGIONAL_ENDPOINTS=regional
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region ap-southeast-6 \
  --secret-id hantt/nginx-ssl-cert \
  --query SecretString \
  --output text) || { echo "FATAL: secretsmanager call failed"; exit 1; }
echo "Secret fetched OK"

echo "--- Writing cert and key ---"
mkdir -p /etc/nginx/ssl
SECRET_JSON="$SECRET_JSON" python3 -c "
import json, os
s = json.loads(os.environ['SECRET_JSON'])
open('/etc/nginx/ssl/server.crt', 'w').write(s['cert'])
open('/etc/nginx/ssl/server.key', 'w').write(s['key'])
print('cert + key written')
"
chmod 0600 /etc/nginx/ssl/server.key
ls -la /etc/nginx/ssl/

echo "--- Resetting nginx failed state and restarting ---"
systemctl reset-failed nginx 2>/dev/null || true
systemctl restart nginx
systemctl status nginx --no-pager

echo "--- Verifying port 443 is listening ---"
ss -tlnp | grep ':443' || echo "WARNING: nothing on 443 yet"

echo "=== [$(date -u '+%Y-%m-%d %H:%M:%S UTC')] user-data done ==="
USERDATA

# ── Launch instance ───────────────────────────────────────────
log ""
log "=== Launching instance ==="
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$IAM_PROFILE" \
  --key-name "$KEY_NAME" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
  --user-data "file://$USER_DATA_FILE" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=hantt-linux-ami-test},{Key=ManagedBy,Value=packer-test}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --no-cli-pager)
log "Instance: $INSTANCE_ID"
echo "$INSTANCE_ID" > "$LOG_DIR/1b-instance-id.txt"

rm -f "$USER_DATA_FILE"

# ── Wait for running ──────────────────────────────────────────
log ""
log "=== Waiting for instance to reach 'running' state ==="
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
log "Public IP: $PUBLIC_IP"
echo "$PUBLIC_IP" > "$LOG_DIR/1b-instance-ip.txt"

# ── Wait for 2/2 status checks ────────────────────────────────
log ""
log "=== Waiting for instance status checks (2/2) ==="
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"
log "Status checks passed — waiting 60s for cloud-init / user-data to finish ..."
sleep 60

# ── HTTPS test loop ───────────────────────────────────────────
log ""
log "=== Testing HTTPS: https://$PUBLIC_IP ==="

ATTEMPT=0
MAX_ATTEMPTS=12
SUCCESS=false

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
  HTTP_CODE=$(curl --silent --insecure --max-time 10 \
    --write-out "%{http_code}" --output /dev/null \
    "https://$PUBLIC_IP" 2>/dev/null || echo "000")

  log "  Attempt $((ATTEMPT+1))/$MAX_ATTEMPTS  →  HTTP $HTTP_CODE"

  if [[ "$HTTP_CODE" == "200" ]]; then
    SUCCESS=true
    break
  fi

  ATTEMPT=$((ATTEMPT+1))
  [[ $ATTEMPT -lt $MAX_ATTEMPTS ]] && sleep 15
done

log ""
if $SUCCESS; then
  log "=== PASS: nginx is serving HTTPS with cert from Secrets Manager ==="
  log ""
  log "--- Page content ---"
  curl --silent --insecure --max-time 10 \
    --write-out "\n[HTTP %{http_code}  time=%{time_total}s]\n" \
    "https://$PUBLIC_IP" 2>&1 | tee -a "$LOG"

  log ""
  log "--- SSL certificate ---"
  echo | openssl s_client -connect "$PUBLIC_IP:443" -servername hantt-nginx \
    2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates 2>&1 \
    | tee -a "$LOG"
else
  fetch_instance_log "$INSTANCE_ID"
  log ""
  log "=== FAIL: nginx did not return HTTP 200 after $MAX_ATTEMPTS attempts ==="
fi

log ""
log "Instance is still running — connect with:"
log "  ssh ec2-user@$PUBLIC_IP"
log "  aws ssm start-session --region $REGION --target $INSTANCE_ID"
log ""
log "Instance ID saved: logs/1b-instance-id.txt"
log "Public IP saved:   logs/1b-instance-ip.txt"
log "Log saved: $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
