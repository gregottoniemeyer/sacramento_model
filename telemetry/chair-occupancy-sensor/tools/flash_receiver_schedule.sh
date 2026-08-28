#!/bin/bash
# Safely compile or flash the USB ESP-NOW receiver with the .11 schedule relay.
#
# Usage:
#   tools/flash_receiver_schedule.sh /dev/cu.wchusbserial10 scheduled compile
#   tools/flash_receiver_schedule.sh /dev/cu.wchusbserial10 scheduled upload
#   tools/flash_receiver_schedule.sh /dev/cu.wchusbserial10 rollback upload

set -euo pipefail

PORT="${1:-}"
VERSION="${2:-scheduled}"
ACTION="${3:-upload}"

if [[ -z "$PORT" ]]; then
  echo "usage: $0 <port> [scheduled|rollback] [compile|upload]" >&2
  exit 2
fi
if [[ "$VERSION" != "scheduled" && "$VERSION" != "rollback" ]]; then
  echo "version must be scheduled or rollback" >&2
  exit 2
fi
if [[ "$ACTION" != "compile" && "$ACTION" != "upload" ]]; then
  echo "action must be compile or upload" >&2
  exit 2
fi

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(git -C "$APP_DIR" rev-parse --show-toplevel)"
ARDUINO_CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
ESPTOOL="$(find "$HOME/Library/Arduino15/packages/esp32/tools/esptool_py" -type f -name esptool | sort | tail -1)"
FQBN="esp32:esp32:esp32"
RECEIVER_MAC="78:1c:3c:35:83:6c"
ROLLBACK_COMMIT="0cfad3388a3d5956b160d64e4b853b0b0ac2eccd"
ROLLBACK_SHA256="3789618f600dd553f61698ba04f6046cefda44536f244ca5076d1064cdcb0100"

if [[ ! -x "$ARDUINO_CLI" || ! -x "$ESPTOOL" ]]; then
  echo "Arduino ESP32 tools are not installed." >&2
  exit 1
fi

echo "Reading receiver identity on $PORT ..."
MAC=$("$ESPTOOL" --port "$PORT" read-mac 2>/dev/null |
  grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
if [[ "$MAC" != "$RECEIVER_MAC" ]]; then
  echo "REFUSING: expected receiver $RECEIVER_MAC, found ${MAC:-no MAC}." >&2
  exit 1
fi
echo "Confirmed USB ESP-NOW receiver: $MAC"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
SKETCH="receiver_scheduled"
mkdir -p "$STAGE/$SKETCH"

if [[ "$VERSION" == "scheduled" ]]; then
  cp "$APP_DIR/firmware/receiver_scheduled/receiver_scheduled.ino" \
     "$STAGE/$SKETCH/$SKETCH.ino"
else
  git -C "$REPO" show \
    "$ROLLBACK_COMMIT:chair-occupancy-sensor/firmware/receiver_esp_now.ino" \
    > "$STAGE/$SKETCH/$SKETCH.ino"
  ACTUAL_SHA256=$(openssl dgst -sha256 "$STAGE/$SKETCH/$SKETCH.ino" |
    awk '{print $NF}')
  if [[ "$ACTUAL_SHA256" != "$ROLLBACK_SHA256" ]]; then
    echo "REFUSING: receiver rollback source checksum mismatch." >&2
    exit 1
  fi
  echo "Receiver rollback source verified: $ROLLBACK_COMMIT"
fi

echo "Compiling receiver $VERSION with $FQBN ..."
"$ARDUINO_CLI" compile --fqbn "$FQBN" "$STAGE/$SKETCH"

if [[ "$ACTION" == "compile" ]]; then
  echo "COMPILE OK: receiver $VERSION"
  exit 0
fi

echo "Uploading receiver $VERSION ..."
"$ARDUINO_CLI" upload -p "$PORT" --fqbn "$FQBN" "$STAGE/$SKETCH"
echo "Hard resetting receiver ..."
"$ESPTOOL" --port "$PORT" --after hard-reset chip-id >/dev/null 2>&1 || true

echo "DONE: USB ESP-NOW receiver is running $VERSION."
if [[ "$VERSION" == "scheduled" ]]; then
  echo "Rollback command:"
  echo "  $0 $PORT rollback upload"
fi
