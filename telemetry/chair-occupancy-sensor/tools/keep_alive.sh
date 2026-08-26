#!/bin/bash
# Keep acquisition, diagnostics, and the Godot chair bridge alive.

set -uo pipefail

TELEMETRY_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$TELEMETRY_DIR/chair-occupancy-sensor"
GODOT_CONTROLLER="$TELEMETRY_DIR/../fleet/godot_controller.py"
LIVE_BUFFER="${WATER_COUNCIL_CHAIR_LOG:-$TELEMETRY_DIR/motion_log.txt}"
MAX_LIVE_BUFFER_BYTES=$((1024 * 1024))
PYTHON="$APP_DIR/venv/bin/python"
[[ -x "$PYTHON" ]] || PYTHON=/usr/bin/python3

"$APP_DIR/tools/start_capture.sh" || true

# Keep at most a short rolling buffer. Readers detect the truncation and jump
# to the new live end, so discarded sensor history can never trigger Godot.
if [[ -f "$LIVE_BUFFER" ]]; then
  live_bytes=$(stat -f %z "$LIVE_BUFFER")
  if (( live_bytes > MAX_LIVE_BUFFER_BYTES )); then
    : > "$LIVE_BUFFER"
    echo "[$(date)] cleared ${live_bytes}-byte telemetry backlog"
  fi
fi

if ! pgrep -f "$TELEMETRY_DIR/controller[.]py --source sensors --port 5006" >/dev/null; then
  echo "[$(date)] starting chair diagnostic publisher on UDP 5006"
  nohup "$PYTHON" -u "$TELEMETRY_DIR/controller.py" \
    --source sensors --port 5006 --quiet \
    > "$TELEMETRY_DIR/controller.log" 2>&1 < /dev/null &
fi

if [[ ! -f "$GODOT_CONTROLLER" ]]; then
  echo "[$(date)] Godot controller not found: $GODOT_CONTROLLER"
  exit 1
fi

if ! pgrep -f "$GODOT_CONTROLLER chairs$" >/dev/null; then
  echo "[$(date)] starting Godot chair bridge"
  nohup /usr/bin/python3 -u "$GODOT_CONTROLLER" chairs \
    > "$TELEMETRY_DIR/godot_chairs.log" 2>&1 < /dev/null &
fi
