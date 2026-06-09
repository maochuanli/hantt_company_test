#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/1b-test-linux-ami.log"
REGION="ap-southeast-6"
TOKEN_FILE="/home/ansible/secrets/azure-aws/oidc-token"
AMI_ID="$(cat "$LOG_DIR/linux-ami-id.txt")"
INSTANCE_TYPE="t3.small"
IAM_PROFILE="hantt-main-vpc-nginx-vm-profile"

mkdir -p "$LOG_DIR"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

INSTANCE_ID=""
SG_ID=""
USER_DATA_FILE=""

cleanup() {
  log ""
  log "=== Cleanup ==="
  [[ -n "$USER_DATA_FILE" ]] && rm -f "$USER_DATA_FILE"
  if [[ -n "$INSTANCE_ID" ]]; then
    log "Terminating $INSTANCE_ID ..."
    aws ec2 terminate-instances \
      --region "$REGION" --instance-ids "$INSTANCE_ID" --no-cli-pager || true
    aws ec2 wait instance-terminated \
      --region "$REGION" --instance-ids "$INSTANCE_ID" || true
    log "Instance terminated"
  fi
  if [[ -n "$SG_ID" ]]; then
    aws ec2 delete-security-group \
      --region "$REGION" --group-id "$SG_ID" --no-cli-pager || true
    log "Security group $SG_ID deleted"
  fi
}
trap cleanup EXIT

# Fetch /var/log/user-data.log + nginx status via SSM (for failure diagnosis)
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
log "  Test Linux AMI: Secrets Manager SSL → nginx HTTPS"
log "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "============================================================"
log "AMI:           $AMI_ID"
log "Instance type: $INSTANCE_TYPE"
log "IAM profile:   $IAM_PROFILE"
log ""

# ── Auth ──────────────────────────────────────────────────────
log "=== Refreshing OIDC token ==="
/home/ansible/secrets/azure-aws/get-token.sh 2>&1 | tee -a "$LOG"

export AWS_STS_REGIONAL_ENDPOINTS=regional
export AWS_DEFAULT_REGION="$REGION"
export AWS_ROLE_ARN="arn:aws:iam::996992102979:role/terraform-svc-role"
export AWS_WEB_IDENTITY_TOKEN_FILE="$TOKEN_FILE"

# ── Default VPC and public subnet (same VPC packer uses) ─────
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

# ── Temporary security group: inbound 443 only ────────────────
log ""
log "=== Creating temporary security group ==="
TIMESTAMP=$(date +%s)
SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "hantt-linux-ami-test-$TIMESTAMP" \
  --description "Ephemeral SG for Linux AMI SSL cert test" \
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

# ── User-data ─────────────────────────────────────────────────
# nginx is *enabled* in the AMI but has no certs, so systemd marks it
# "failed" at first boot. We must reset-failed before restarting so that
# systemd doesn't block the restart with "start limit hit".
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
# nginx failed at boot because certs were absent; clear that before restart
systemctl reset-failed nginx 2>/dev/null || true
systemctl restart nginx
systemctl status nginx --no-pager

echo "--- Verifying port 443 is listening ---"
ss -tlnp | grep ':443' || echo "WARNING: nothing on 443 yet"

echo "=== [$(date -u '+%Y-%m-%d %H:%M:%S UTC')] user-data done ==="
USERDATA

# ── Launch test instance ──────────────────────────────────────
log ""
log "=== Launching test instance ==="
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$IAM_PROFILE" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
  --user-data "file://$USER_DATA_FILE" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=hantt-linux-ami-test},{Key=ManagedBy,Value=packer-test}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --no-cli-pager)
log "Instance: $INSTANCE_ID"

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

# ── Wait for 2/2 status checks, then extra time for user-data ─
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
  exit 1
fi

log ""
log "Log saved: $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
