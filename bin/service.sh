#!/usr/bin/env bash
set -euo pipefail

PLIST_LABEL="com.hemifuture.clawd-ex"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_BIN="${APP_DIR}/_build/prod/rel/clawd_ex/bin/clawd_ex"
LOG_DIR="${HOME}/.clawd/logs"
ENV_FILE="${HOME}/.clawd/deploy/.env"

case "${1:-help}" in
  install)
    mkdir -p "$LOG_DIR" "${HOME}/.clawd/deploy"

    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RELEASE_BIN}</string>
    <string>start</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>RELEASE_ROOT</key>
    <string>${APP_DIR}/_build/prod/rel/clawd_ex</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>${APP_DIR}</string>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/clawd_ex.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/clawd_ex.stderr.log</string>
  <key>ThrottleInterval</key>
  <integer>5</integer>
</dict>
</plist>
EOF

    launchctl load "$PLIST_PATH"
    echo "✅ Service installed and started"
    ;;

  uninstall)
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "✅ Service uninstalled"
    ;;

  start)
    launchctl load "$PLIST_PATH"
    echo "✅ Service started"
    ;;

  stop)
    launchctl unload "$PLIST_PATH"
    echo "✅ Service stopped"
    ;;

  restart)
    launchctl kickstart -k "gui/$(id -u)/${PLIST_LABEL}"
    echo "✅ Service restarted"
    ;;

  status)
    if launchctl list | grep -q "$PLIST_LABEL"; then
      echo "✅ Service is running"
      launchctl list "$PLIST_LABEL"
    else
      echo "❌ Service is not running"
    fi
    ;;

  logs)
    tail -f "$LOG_DIR/clawd_ex.stdout.log"
    ;;

  *)
    echo "Usage: $0 {install|uninstall|start|stop|restart|status|logs}"
    ;;
esac
