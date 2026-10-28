# Brew Daily Update (using Homebrew)

Shannon Eldridge-Kuehn · October 27, 2026

A small macOS utility that keeps everything installed through Homebrew up to date without you having to think about it. It runs `brew update`, upgrades formulae and casks, cleans up old versions, and keeps a Brewfile backup of everything you have installed, so rebuilding a Mac later is a single `brew bundle` away.

## How the "at least once a day" part works

A plain daily schedule has a weakness on a laptop: if the lid is closed or the Mac is off at the scheduled time, that day's run is simply missed. Instead, a launchd agent checks in at the top of every hour and at login, and the script only does real work when its last successful run is more than 20 hours old. Most check-ins exit in milliseconds. In practice you get one update per day, and if your Mac was asleep all day, the update happens right after you open the lid rather than waiting until tomorrow.

The agent uses `StartCalendarInterval` rather than `StartInterval`, and the difference matters on a laptop. launchd skips `StartInterval` firings that come due while the Mac is asleep, so an "every four hours" timer can go most of a day without firing. Calendar firings missed during sleep are coalesced into a single run when the Mac wakes, which is exactly the catch-up behavior this tool depends on.

The script also skips quietly when there's no network, uses a lock so two runs never overlap, and runs at low CPU and disk priority so you won't notice while you work. Every check-in, quiet or not, writes one line to `~/Library/Logs/brew-daily-update/heartbeat.log`, so you can always tell whether the agent is waiting or stuck.

## Install

```bash
chmod +x install.sh uninstall.sh brew-daily-update.sh
./install.sh
```

The installer copies the script to `~/.local/bin/brew-daily-update`, writes the launchd agent to `~/Library/LaunchAgents/com.sbek.brew-daily-update.plist`, creates a default config, and kicks off the first run in the background.

## Everyday commands

```bash
brew-daily-update --force    # update right now, ignoring the 20 hour gate
brew-daily-update --status   # last success, when the next update is due, recent check-ins
tail -f ~/Library/Logs/brew-daily-update/$(date +%Y-%m-%d).log
cat ~/Library/Logs/brew-daily-update/heartbeat.log          # every check-in, including quiet ones
launchctl print gui/$(id -u)/com.sbek.brew-daily-update   # agent details
```

## Configuration

Edit `~/.config/brew-daily-update/config`. Changes apply on the next run with no reload needed.

| Setting | Default | What it does |
| --- | --- | --- |
| `MIN_HOURS_BETWEEN_RUNS` | `20` | Hours since the last success before another update runs |
| `GREEDY_CASKS` | `false` | Also upgrade casks that normally update themselves (Chrome, Slack, Zoom) |
| `UPDATE_MAS` | `false` | Upgrade Mac App Store apps with `mas` (install it with `brew install mas`) |
| `SKIP_ON_BATTERY` | `false` | Wait until the Mac is plugged in |
| `DUMP_BREWFILE` | `true` | Save a Brewfile to `~/Library/Application Support/brew-daily-update/Brewfile` |
| `NOTIFY` | `true` | Show a notification when packages were upgraded or something failed |
| `LOG_RETENTION_DAYS` | `30` | How long daily logs are kept |

## A note on casks that need your password

A handful of casks install system components (drivers, VPN clients, some Microsoft and Adobe apps) and ask for an admin password during upgrade. A background job can't answer that prompt, so those specific casks will fail and you'll get a notification. Everything else still upgrades, and the run still counts for the day. When you see that notification, run `brew upgrade --cask` in Terminal once to catch up on the ones that need you.

## Uninstall

```bash
./uninstall.sh           # remove the script and agent, keep logs and Brewfile
./uninstall.sh --purge   # remove everything
```
