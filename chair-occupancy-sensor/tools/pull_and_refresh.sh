#!/bin/bash
# Run on a timer (see the launchd job in README.md's "Mac Mini setup"
# section). Pulls the latest code, and restarts the live dashboard only if
# the pull actually brought in new commits, or if the dashboard isn't
# currently running at all (e.g. right after a reboot). This is what makes
# "edit on the MacBook, push, and the Mac Mini picks it up automatically"
# also apply to the running dashboard, not just the files on disk -- a
# Python process does not hot-reload a script that changed out from
# under it, so a plain `git pull` alone is not enough.

set -e
cd "$(dirname "$0")/../.."   # repo root (this script lives in chair-occupancy-sensor/tools/)
REPO_ROOT="$(pwd)"
APP_DIR="$REPO_ROOT/chair-occupancy-sensor"

BEFORE=$(git rev-parse HEAD)
git pull --ff-only
AFTER=$(git rev-parse HEAD)

if [ "$BEFORE" != "$AFTER" ] || ! pgrep -f "tools/live_plot.py" > /dev/null; then
  echo "[$(date)] restarting dashboard (code changed: $([ "$BEFORE" != "$AFTER" ] && echo yes || echo no), was running: $(pgrep -f "tools/live_plot.py" > /dev/null && echo yes || echo no))"
  pkill -f "tools/live_plot.py" 2>/dev/null || true
  sleep 1
  cd "$APP_DIR"
  nohup venv/bin/python tools/live_plot.py > "$REPO_ROOT/dashboard.log" 2>&1 &
  disown
fi
