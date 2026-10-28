#!/usr/bin/env bash
#
# brew-daily-update.sh
# Keeps Homebrew formulae, casks, and (optionally) Mac App Store apps current.
# Designed to be run by launchd every hour (and on wake after a missed hour);
# it only does real work when the last successful run is older than
# MIN_HOURS_BETWEEN_RUNS, which guarantees at least one update per day even
# if the Mac was asleep or off at any particular scheduled time. Every
# check-in, including the quiet ones, writes one line to heartbeat.log.
#
# Usage:
#   brew-daily-update            # normal run (respects the hours gate)
#   brew-daily-update --force    # run now regardless of the last run time
#   brew-daily-update --status   # show last run and log location
#
# Author: Shannon Eldridge-Kuehn
# Date: October 27, 2026

set -uo pipefail

# ---------- defaults (override in the config file) ----------
MIN_HOURS_BETWEEN_RUNS=20     # hours since last success before running again
GREEDY_CASKS=false            # true = also upgrade casks that self-update (Chrome, Slack, etc.)
UPDATE_MAS=false              # true = run "mas upgrade" if mas is installed
SKIP_ON_BATTERY=false         # true = skip runs while unplugged
DUMP_BREWFILE=true            # true = keep a fresh Brewfile backup of everything installed
NOTIFY=true                   # true = macOS notification when finished
LOG_RETENTION_DAYS=30

CONFIG_FILE="$HOME/.config/brew-daily-update/config"
STATE_DIR="$HOME/Library/Application Support/brew-daily-update"
LOG_DIR="$HOME/Library/Logs/brew-daily-update"

# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

STAMP_FILE="$STATE_DIR/last-success"
LOCK_DIR="$STATE_DIR/lock"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"
HEARTBEAT_FILE="$LOG_DIR/heartbeat.log"

mkdir -p "$STATE_DIR" "$LOG_DIR"

log()    { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

# One line per check-in, so quiet exits still leave evidence that launchd ran us.
heartbeat() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HEARTBEAT_FILE"
  if [[ $(wc -l < "$HEARTBEAT_FILE") -gt 1000 ]]; then
    tail -n 500 "$HEARTBEAT_FILE" > "$HEARTBEAT_FILE.tmp" && mv "$HEARTBEAT_FILE.tmp" "$HEARTBEAT_FILE"
  fi
}
notify() {
  [[ "$NOTIFY" == "true" ]] || return 0
  /usr/bin/osascript -e "display notification \"${2//\"/\\\"}\" with title \"${1//\"/\\\"}\"" >/dev/null 2>&1 || true
}

last_success_epoch() { [[ -f "$STAMP_FILE" ]] && cat "$STAMP_FILE" || echo 0; }

# ---------- argument handling ----------
FORCE=false
case "${1:-}" in
  --force) FORCE=true ;;
  --status)
    last=$(last_success_epoch)
    if [[ "$last" -gt 0 ]]; then
      echo "Last successful run: $(date -r "$last" '+%Y-%m-%d %H:%M:%S')"
      due=$(( last + MIN_HOURS_BETWEEN_RUNS * 3600 ))
      if [[ "$due" -gt "$(date +%s)" ]]; then
        echo "Next update due:     at the first check-in after $(date -r "$due" '+%Y-%m-%d %H:%M')"
      else
        echo "Next update due:     now (it runs at the next check-in)"
      fi
    else
      echo "Last successful run: never"
      echo "Next update due:     now (it runs at the next check-in)"
    fi
    echo
    echo "Recent check-ins:"
    if [[ -s "$HEARTBEAT_FILE" ]]; then
      tail -n 5 "$HEARTBEAT_FILE" | sed 's/^/  /'
    else
      echo "  (none recorded yet)"
    fi
    echo
    echo "Logs:   $LOG_DIR"
    echo "Config: $CONFIG_FILE"
    exit 0 ;;
  "" ) ;;
  *) echo "Usage: $(basename "$0") [--force|--status]"; exit 2 ;;
esac

# ---------- gate: has it been long enough? ----------
now=$(date +%s)
elapsed_hours=$(( (now - $(last_success_epoch)) / 3600 ))
if [[ "$FORCE" != "true" && "$elapsed_hours" -lt "$MIN_HOURS_BETWEEN_RUNS" ]]; then
  # Quiet exit; launchd calls us often and most calls are no-ops.
  heartbeat "check-in: ${elapsed_hours}h since last success, not due yet"
  exit 0
fi

# ---------- gate: battery ----------
if [[ "$SKIP_ON_BATTERY" == "true" && "$FORCE" != "true" ]] && pmset -g batt | grep -q "Battery Power"; then
  heartbeat "check-in: due, but on battery power, skipping"
  log "On battery power, skipping until plugged in."
  exit 0
fi

# ---------- lock so two runs never overlap ----------
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Clear a stale lock left by a crash (older than 2 hours).
  if [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +120 2>/dev/null)" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" || exit 0
  else
    heartbeat "check-in: due, but another run is in progress"
    log "Another run is in progress, exiting."
    exit 0
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# ---------- find Homebrew (Apple Silicon or Intel) ----------
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x "$candidate" ]] && BREW="$candidate" && break
done
if [[ -z "$BREW" ]]; then
  heartbeat "check-in: due, but Homebrew was not found"
  log "ERROR: Homebrew not found."
  notify "Homebrew update failed" "Homebrew is not installed."
  exit 1
fi
eval "$("$BREW" shellenv)"
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1   # we run cleanup ourselves at the end

# ---------- gate: network ----------
if ! /usr/bin/curl -fsI --max-time 10 https://formulae.brew.sh >/dev/null 2>&1; then
  heartbeat "check-in: due, but no network, will retry next check-in"
  log "No network connection, will retry on the next scheduled check."
  exit 0
fi

# ---------- do the work ----------
if [[ "$FORCE" == "true" ]]; then
  heartbeat "manual run (--force): starting update"
else
  heartbeat "check-in: ${elapsed_hours}h since last success, starting update"
fi
log "========== Starting Homebrew update (brew at $BREW) =========="
failures=()

run_step() {
  local name="$1"; shift
  log "--> $name"
  if "$@" >>"$LOG_FILE" 2>&1; then
    log "    ok"
  else
    log "    FAILED (exit $?)"
    failures+=("$name")
  fi
}

run_step "brew update" brew update

greedy_flag=()
[[ "$GREEDY_CASKS" == "true" ]] && greedy_flag=(--greedy)

outdated=$(brew outdated --quiet ${greedy_flag[@]+"${greedy_flag[@]}"} 2>/dev/null)
outdated_count=$(printf '%s' "$outdated" | grep -c . || true)
if [[ "$outdated_count" -gt 0 ]]; then
  log "Outdated ($outdated_count): $(echo "$outdated" | tr '\n' ' ')"
fi

run_step "brew upgrade (formulae)" brew upgrade --formula
run_step "brew upgrade (casks)"    brew upgrade --cask ${greedy_flag[@]+"${greedy_flag[@]}"}

if [[ "$UPDATE_MAS" == "true" ]] && command -v mas >/dev/null 2>&1; then
  run_step "mas upgrade" mas upgrade
fi

run_step "brew autoremove" brew autoremove
run_step "brew cleanup"    brew cleanup --prune=30

if [[ "$DUMP_BREWFILE" == "true" ]]; then
  run_step "Brewfile backup" brew bundle dump --force --file "$STATE_DIR/Brewfile"
fi

# ---------- wrap up ----------
find "$LOG_DIR" -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null

if [[ ${#failures[@]} -eq 0 ]]; then
  date +%s > "$STAMP_FILE"
  heartbeat "update finished: $outdated_count package(s) upgraded"
  log "========== Finished: $outdated_count package(s) upgraded =========="
  if [[ "$outdated_count" -gt 0 ]]; then
    notify "Homebrew updated" "Upgraded $outdated_count package(s)."
  fi
  exit 0
else
  # Still record the run if only casks failed (usually ones needing a password),
  # so a single stubborn cask doesn't trigger retries every hour.
  if [[ ${#failures[@]} -eq 1 && "${failures[0]}" == "brew upgrade (casks)" ]]; then
    date +%s > "$STAMP_FILE"
  fi
  heartbeat "update finished with failures: ${failures[*]}"
  log "========== Finished with failures: ${failures[*]} =========="
  notify "Homebrew update had problems" "Failed: ${failures[*]}. See ~/Library/Logs/brew-daily-update"
  exit 1
fi
