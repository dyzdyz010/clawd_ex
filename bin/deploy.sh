#!/usr/bin/env bash
set -euo pipefail

APP_NAME="clawd_ex"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="${HOME}/.clawd/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"
LOG_DIR="${HOME}/.clawd/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[deploy]${NC} $1"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $1"; }
error() { echo -e "${RED}[deploy]${NC} $1"; exit 1; }

# 0. Prerequisites
[ -f "$ENV_FILE" ] || error ".env not found at $ENV_FILE. Copy from .env.example"
mkdir -p "$LOG_DIR"

# 1. Git pull
log "Pulling latest code..."
cd "$APP_DIR"
git pull origin main

# 2. Deps & compile
log "Installing dependencies..."
MIX_ENV=prod mix deps.get --only prod

log "Compiling..."
MIX_ENV=prod mix compile

# 3. Assets
log "Building assets..."
MIX_ENV=prod mix assets.deploy 2>/dev/null || warn "No assets to deploy"

# 4. Database migration
log "Running migrations..."
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
MIX_ENV=prod mix ecto.migrate

# 5. Build release
log "Building release..."
MIX_ENV=prod mix release --overwrite

# 6. Copy .env to release
RELEASE_DIR="_build/prod/rel/${APP_NAME}"
cp "$ENV_FILE" "$RELEASE_DIR/.env"

# 7. Restart via launchd
log "Restarting service..."
PLIST_LABEL="com.hemifuture.clawd-ex"
if launchctl list | grep -q "$PLIST_LABEL"; then
  launchctl kickstart -k "gui/$(id -u)/${PLIST_LABEL}"
else
  warn "launchd service not loaded. Run: bin/service.sh install"
fi

# 8. Health check
log "Waiting for startup..."
sleep 3
for i in $(seq 1 10); do
  if curl -sf "http://localhost:${PORT:-4000}/api/health" > /dev/null 2>&1; then
    log "✅ Service is healthy!"
    exit 0
  fi
  sleep 1
done

error "❌ Health check failed after 10 attempts"
