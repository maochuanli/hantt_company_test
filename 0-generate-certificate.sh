#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SSL_DIR="$REPO_ROOT/packer/shared/ssl"
LOG_DIR="$REPO_ROOT/logs"
LOG="$LOG_DIR/0-generate-certificate.log"

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
log "Log saved: $LOG"
log "Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
