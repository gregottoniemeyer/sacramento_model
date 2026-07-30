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

# One-time cleanup after 2026-07-30. This job used to start tools/live_plot.py,
# a dashboard running the confidence-decay model that was deleted on 2026-07-29.
# A host that has not been touched since is still running it, and nothing below
# would stop it, so it would sit next to the controller showing the abandoned
# model as though it were live. Harmless to run forever once it is gone.
if pgrep -f "live_plot.py" > /dev/null; then
  echo "[$(date)] stopping stale live_plot.py (retired dashboard, old model)"
  pkill -f "live_plot.py" 2>/dev/null || true
fi

# Restarts controller.py, which is what feeds the artwork. It used to restart
# tools/live_plot.py, a dashboard that ran the old confidence-decay model, so
# this machine was keeping the abandoned model alive and nothing was driving
# the piece.
if [ "$BEFORE" != "$AFTER" ] || ! pgrep -f "controller.py" > /dev/null; then
  echo "[$(date)] restarting controller (code changed: $([ "$BEFORE" != "$AFTER" ] && echo yes || echo no), was running: $(pgrep -f "controller.py" > /dev/null && echo yes || echo no))"
  pkill -f "controller.py" 2>/dev/null || true
  sleep 1
  cd "$REPO_ROOT"
  PY="$APP_DIR/venv/bin/python"
  [ -x "$PY" ] || PY=python3
  nohup "$PY" -u controller.py --source sensors > "$REPO_ROOT/controller.log" 2>&1 &
  disown
fi
