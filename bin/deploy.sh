#!/usr/bin/env bash
set -euo pipefail

APP_NAME="clawd_ex"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="${HOME}/.clawd/deploy"
RELEASE_DIR="${DEPLOY_DIR}/current"
ENV_FILE="${DEPLOY_DIR}/.env"
LOG_DIR="${HOME}/.clawd/logs"
PLIST_LABEL="com.hemifuture.clawd-ex"

log() { echo -e "\033[0;32m[deploy]\033[0m $1"; }
warn() { echo -e "\033[1;33m[deploy]\033[0m $1"; }
error() { echo -e "\033[0;31m[deploy]\033[0m $1"; exit 1; }

[ -f "$ENV_FILE" ] || error ".env not found at $ENV_FILE"
mkdir -p "$LOG_DIR" "$DEPLOY_DIR/artifacts" "$DEPLOY_DIR/releases"

cd "$APP_DIR"

# 0. Stop old service gracefully
log "Stopping current service..."
if [ -x "$RELEASE_DIR/bin/clawd_ex" ]; then
  "$RELEASE_DIR/bin/clawd_ex" stop 2>/dev/null || true
  # Wait for BEAM process to actually exit (up to 40s for long-poll to expire)
  log "Waiting for old process to exit..."
  for i in $(seq 1 40); do
    pgrep -f "clawd_ex.*beam" > /dev/null 2>&1 || break
    sleep 1
  done
fi
# Kill any orphan epmd from old releases
pkill -f "clawd_ex.*epmd" 2>/dev/null || true

# 1. Check CI
log "Checking CI status for main branch..."
LATEST_RUN=$(gh run list --branch main --workflow ci.yml --limit 1 --json databaseId,conclusion,headSha --jq '.[0]' 2>/dev/null)
CONCLUSION=$(echo "$LATEST_RUN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conclusion',''))" 2>/dev/null)
RUN_ID=$(echo "$LATEST_RUN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('databaseId',''))" 2>/dev/null)
HEAD_SHA=$(echo "$LATEST_RUN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('headSha','')[:7])" 2>/dev/null)

if [ "$CONCLUSION" != "success" ]; then
  error "CI not passed (status: $CONCLUSION). Fix CI first."
fi
log "✅ CI passed (run $RUN_ID, sha $HEAD_SHA)"

# 2. Download artifact
log "Downloading release artifact..."
ARTIFACT_DIR="${DEPLOY_DIR}/artifacts/${HEAD_SHA}"
mkdir -p "$ARTIFACT_DIR"
gh run download "$RUN_ID" --name "clawd_ex-release-macos-arm64" --dir "$ARTIFACT_DIR" 2>/dev/null || error "Failed to download artifact. Build job may not have run."

TARBALL=$(ls "$ARTIFACT_DIR"/clawd_ex-*.tar.gz 2>/dev/null | head -1)
[ -f "$TARBALL" ] || error "No release tarball found in artifact"
log "Downloaded: $(basename $TARBALL)"

# 3. Extract to release dir
log "Extracting release..."
RELEASE_DEST="${DEPLOY_DIR}/releases/${HEAD_SHA}"
rm -rf "$RELEASE_DEST"
mkdir -p "$RELEASE_DEST"
tar xzf "$TARBALL" -C "$RELEASE_DEST"

# 4. Symlink current
ln -sfn "$RELEASE_DEST/clawd_ex" "$RELEASE_DIR"
cp "$ENV_FILE" "$RELEASE_DIR/.env"
log "Release at: $RELEASE_DIR"

# 5. Run migrations
log "Running migrations..."
set -a; . "$ENV_FILE"; set +a
"$RELEASE_DIR/bin/clawd_ex" eval "ClawdEx.Release.migrate()" 2>/dev/null || warn "Migration eval not available, skipping"

# 6. Restart service
log "Restarting service..."
if launchctl list | grep -q "$PLIST_LABEL"; then
  launchctl kickstart -k "gui/$(id -u)/${PLIST_LABEL}"
else
  warn "Service not installed. Run: bin/service.sh install"
fi

# 6.5 Cleanup old releases (keep last 3)
log "Cleaning up old releases..."
ls -dt "${DEPLOY_DIR}/releases"/*/ 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true
# Cleanup old artifacts (keep last 3)
ls -dt "${DEPLOY_DIR}/artifacts"/*/ 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true

# 7. Health check
log "Waiting for startup..."
for i in $(seq 1 20); do
  if no_proxy=localhost curl -sf "http://localhost:${PORT:-4000}/api/health" > /dev/null 2>&1; then
    log "✅ Deployed $HEAD_SHA — healthy (attempt $i)"
    exit 0
  fi
  sleep 1
done
error "❌ Health check failed"
