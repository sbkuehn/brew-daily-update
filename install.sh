#!/usr/bin/env bash
#
# install.sh: installs brew-daily-update and schedules it with launchd.
# Author: Shannon Eldridge-Kuehn

set -euo pipefail

LABEL="com.sbek.brew-daily-update"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SCRIPT_DEST="$BIN_DIR/brew-daily-update"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST_DEST="$AGENT_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/brew-daily-update"
CONFIG_DIR="$HOME/.config/brew-daily-update"
CONFIG_FILE="$CONFIG_DIR/config"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This utility is for macOS only." >&2; exit 1
fi
if [[ ! -x /opt/homebrew/bin/brew && ! -x /usr/local/bin/brew ]]; then
  echo "Homebrew isn't installed. Get it from https://brew.sh first." >&2; exit 1
fi

mkdir -p "$BIN_DIR" "$AGENT_DIR" "$LOG_DIR" "$CONFIG_DIR"

echo "Installing script to $SCRIPT_DEST"
install -m 0755 "$SRC_DIR/brew-daily-update.sh" "$SCRIPT_DEST"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Writing default config to $CONFIG_FILE"
  cat > "$CONFIG_FILE" <<'EOF'
# brew-daily-update settings. Uncomment and change any line you like.
# MIN_HOURS_BETWEEN_RUNS=20
# GREEDY_CASKS=false       # true also upgrades self-updating casks (Chrome, Slack, Zoom...)
# UPDATE_MAS=false         # true runs "mas upgrade" for App Store apps (brew install mas)
# SKIP_ON_BATTERY=false
# DUMP_BREWFILE=true
# NOTIFY=true
# LOG_RETENTION_DAYS=30
EOF
else
  echo "Keeping existing config at $CONFIG_FILE"
fi

echo "Installing launchd agent to $PLIST_DEST"
sed -e "s|__SCRIPT_PATH__|$SCRIPT_DEST|" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$SRC_DIR/$LABEL.plist" > "$PLIST_DEST"
plutil -lint "$PLIST_DEST" >/dev/null

# Reload cleanly if a previous version is loaded.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
launchctl enable "gui/$(id -u)/$LABEL"

echo
echo "Done. The first update is running in the background now."
echo "  Run manually:   $SCRIPT_DEST --force"
echo "  Check status:   $SCRIPT_DEST --status"
echo "  Watch the log:  tail -f \"$LOG_DIR/\$(date +%Y-%m-%d).log\""
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo
     echo "Tip: add $BIN_DIR to your PATH to call brew-daily-update directly:"
     echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
