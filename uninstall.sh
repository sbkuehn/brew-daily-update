#!/usr/bin/env bash
#
# uninstall.sh: removes brew-daily-update and its launchd agent.
# Pass --purge to also delete logs, config, state, and the Brewfile backup.
# Author: Shannon Eldridge-Kuehn

set -uo pipefail

LABEL="com.sbek.brew-daily-update"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "Unloaded launchd agent."
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/.local/bin/brew-daily-update"
echo "Removed script and agent."

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/Library/Logs/brew-daily-update" \
         "$HOME/Library/Application Support/brew-daily-update" \
         "$HOME/.config/brew-daily-update"
  echo "Removed logs, config, and state."
else
  echo "Logs, config, and Brewfile backup were kept. Run with --purge to remove them too."
fi
