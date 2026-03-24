#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="${HOME}/.clawd/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"
LOG_DIR="${HOME}/.clawd/logs"

log() { echo -e "\033[0;32m[deploy]\033[0m $1"; }
warn() { echo -e "\033[1;33m[deploy]\033[0m $1"; }
error() { echo -e "\033[0;31m[deploy]\033[0m $1"; exit 1; }

cd "$APP_DIR"

# 0. Prerequisites
[ -f "$ENV_FILE" ] || error ".env not found at $ENV_FILE"
mkdir -p "$LOG_DIR"

# 1. Check CI status for current HEAD
log "Checking CI status..."
SHA=$(git rev-parse HEAD)
CI_STATUS=$(gh run list --commit "$SHA" --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")

if [ "$CI_STATUS" = "success" ]; then
  log "✅ CI passed for $SHA"
elif [ "$CI_STATUS" = "failure" ]; then
  error "❌ CI failed for $SHA — fix CI before deploying"
elif [ "$CI_STATUS" = "unknown" ] || [ -z "$CI_STATUS" ]; then
  warn "⚠️ CI status unknown (no run found for $SHA), proceeding anyway..."
else
  warn "⚠️ CI status: $CI_STATUS, proceeding..."
fi

# 2. Build release locally (macOS arm64)
log "Installing dependencies..."
MIX_ENV=prod mix deps.get --only prod

log "Compiling..."
MIX_ENV=prod mix compile

log "Building assets..."
MIX_ENV=prod mix assets.deploy 2>/dev/null || warn "No assets to deploy"

log "Running migrations..."
set -a; . "$ENV_FILE"; set +a
MIX_ENV=prod mix ecto.migrate

log "Building release..."
MIX_ENV=prod mix release --overwrite

# 3. Copy .env to release
cp "$ENV_FILE" "_build/prod/rel/clawd_ex/.env"

# 4. Restart service
log "Restarting service..."
PLIST_LABEL="com.hemifuture.clawd-ex"
if launchctl list | grep -q "$PLIST_LABEL"; then
  launchctl kickstart -k "gui/$(id -u)/${PLIST_LABEL}"
else
  warn "launchd service not loaded. Run: bin/service.sh install"
fi

# 5. Health check
log "Waiting for startup..."
for i in $(seq 1 20); do
  if no_proxy=localhost curl -sf "http://localhost:${PORT:-4000}/api/health" > /dev/null 2>&1; then
    log "✅ Deployed $(git rev-parse --short HEAD) — healthy (attempt $i)"
    exit 0
  fi
  sleep 1
done
error "❌ Health check failed"
