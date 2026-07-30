#!/bin/bash
# Start the receiver's serial capture if it is not already running.
#
# Safe to run repeatedly: it does nothing when the capture is healthy. Called
# from pull_and_refresh.sh on the installation host, so a reboot, a replug or
# an unplugged cable heals itself within one timer tick.
#
# WHY THIS EXISTS
# The capture was the one step in the chain that never auto-started, and it is
# also the one whose failure is invisible: nothing downstream errors, every
# display simply freezes on its last values. Every other component announces a
# problem. This one just stops.
#
# HOW "IS IT RUNNING" IS DECIDED
# Not by looking for the process, which can survive while the board behind it
# has gone away. By whether the log FILE has been written to recently, which is
# the thing that actually matters. Seven chairs at 8Hz write ~56 lines a
# second, so a log untouched for STALE_S is not being fed.

set -uo pipefail

LOG="$HOME/motion_log.txt"
BAUD=921600          # must match Serial.begin() in firmware/receiver_esp_now.ino
STALE_S=15

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] capture: $*"; }

if [[ -f "$LOG" ]]; then
  age=$(( $(date +%s) - $(stat -f %m "$LOG") ))
  if (( age < STALE_S )); then
    exit 0                       # healthy, nothing to do
  fi
  log "log is ${age}s stale, restarting"
else
  log "no log yet, starting"
fi

# The receiver is a CH340 board and lands on a wchusbserial* node. The suffix
# changes with the USB socket, so it is discovered rather than hard-coded.
PORT=$(ls /dev/cu.wchusbserial* 2>/dev/null | head -1)
if [[ -z "$PORT" ]]; then
  log "NO RECEIVER FOUND. Is it plugged in? Ports present:"
  ls /dev/cu.* 2>/dev/null | sed 's/^/    /'
  exit 1
fi

pkill -f "cat <&3" 2>/dev/null
for pid in $(pgrep -x cat 2>/dev/null); do
  # only our capture holds the log open
  if lsof -p "$pid" 2>/dev/null | grep -q "motion_log.txt"; then
    kill "$pid" 2>/dev/null
  fi
done

# stty and cat must share one open of the port. Opening it twice resets the
# board and silently drops the baud rate back to 9600.
nohup bash -c "exec 3<>'$PORT'; stty -f /dev/fd/3 $BAUD raw; exec cat <&3 >> '$LOG'" \
  >/dev/null 2>&1 &
disown

sleep 3
if [[ -f "$LOG" ]] && (( $(date +%s) - $(stat -f %m "$LOG") < 5 )); then
  log "running on $PORT"
else
  log "STARTED ON $PORT BUT NOTHING IS ARRIVING."
  log "  check the chairs are switched on, and that the receiver is the"
  log "  board flashed with receiver_esp_now.ino"
  exit 1
fi
