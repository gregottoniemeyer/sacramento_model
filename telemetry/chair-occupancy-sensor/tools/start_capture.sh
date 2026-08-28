#!/bin/bash
# Start the receiver's serial capture if it is not already writing live data.

set -uo pipefail

TELEMETRY_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIVE_BUFFER="${WATER_COUNCIL_CHAIR_LOG:-$TELEMETRY_DIR/motion_log.txt}"
BRIDGE="$TELEMETRY_DIR/serial_schedule_bridge.py"
BRIDGE_LOG="$TELEMETRY_DIR/schedule_bridge.log"
BAUD=921600
STALE_S=15

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] capture: $*"; }

if [[ -f "$LIVE_BUFFER" ]]; then
  age=$(( $(date +%s) - $(stat -f %m "$LIVE_BUFFER") ))
  if (( age < STALE_S )) && pgrep -f "$BRIDGE" >/dev/null; then
    exit 0
  fi
  if (( age < STALE_S )); then
    log "upgrading live serial capture to the .11 clock bridge"
  else
    log "live buffer is ${age}s stale, restarting"
  fi
else
  log "no live buffer yet, starting"
fi

PORT=$(ls /dev/cu.wchusbserial* 2>/dev/null | head -1)
if [[ -z "$PORT" ]]; then
  log "NO RECEIVER FOUND. Is it plugged in? Ports present:"
  ls /dev/cu.* 2>/dev/null | sed 's/^/    /'
  exit 1
fi

pkill -f "$BRIDGE" 2>/dev/null || true
pkill -f "cat <&3" 2>/dev/null || true
for pid in $(pgrep -x cat 2>/dev/null); do
  if lsof -p "$pid" 2>/dev/null | grep -q "motion_log.txt"; then
    kill "$pid" 2>/dev/null || true
  fi
done

# This file is an inter-process live buffer, not a historical sensor log.
# Discard everything from the previous capture before opening the receiver.
: > "$LIVE_BUFFER"
nohup /usr/bin/python3 -u "$BRIDGE" \
  --port "$PORT" \
  --log "$LIVE_BUFFER" \
  --baud "$BAUD" \
  --timezone America/Los_Angeles \
  --open-hour 9 \
  --close-hour 21 \
  >> "$BRIDGE_LOG" 2>&1 &
disown

sleep 3
if [[ -f "$LIVE_BUFFER" ]] && (( $(date +%s) - $(stat -f %m "$LIVE_BUFFER") < 5 )); then
  log "running on $PORT"
else
  log "STARTED ON $PORT BUT NOTHING IS ARRIVING."
  exit 1
fi
