#!/bin/bash
# Safely compile or flash an explicitly selected validation chair with the
# power-save test or exact rollback.
#
# Usage:
#   tools/flash_chair_power_test.sh /dev/cu.usbserial-0001 power-save-scheduled upload chair1
#   tools/flash_chair_power_test.sh /dev/cu.usbserial-0001 power-save-scheduled upload agriculture
#   tools/flash_chair_power_test.sh /dev/cu.usbserial-0001 power-save-scheduled upload gold-rush
#   tools/flash_chair_power_test.sh /dev/cu.usbserial-0001 rollback upload gold-rush

set -euo pipefail

PORT="${1:-}"
VERSION="${2:-power-save}"
ACTION="${3:-upload}"
TARGET="${4:-chair1}"

if [[ -z "$PORT" ]]; then
  echo "usage: $0 <port> [power-save|rollback] [compile|upload]" >&2
  exit 2
fi
if [[ "$VERSION" != "power-save" &&
      "$VERSION" != "power-save-scheduled" &&
      "$VERSION" != "rollback" ]]; then
  echo "version must be power-save, power-save-scheduled, or rollback" >&2
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
case "$TARGET" in
  chair1|kinship)
    EXPECTED_MAC="8c:94:df:46:b5:54"
    TARGET_LABEL="Kinship (logical chair 1, receiver slot 1)"
    ;;
  chair2|agriculture)
    EXPECTED_MAC="88:f1:55:30:af:b4"
    TARGET_LABEL="Agriculture (logical chair 2, receiver slot 2)"
    ;;
  gold-rush)
    # Receiver slot 8 replaces retired slot 3 for logical chair 3.
    EXPECTED_MAC="88:f1:55:32:5f:6c"
    TARGET_LABEL="Gold Rush (logical chair 3, receiver slot 8)"
    ;;
  chair4|water-projects)
    EXPECTED_MAC="8c:94:df:45:ca:28"
    TARGET_LABEL="Water Projects (logical chair 4, receiver slot 4)"
    ;;
  chair5|hydropower)
    EXPECTED_MAC="88:f1:55:30:a6:58"
    TARGET_LABEL="Hydropower (logical chair 5, receiver slot 5)"
    ;;
  chair6|tech)
    EXPECTED_MAC="8c:94:df:97:4f:34"
    TARGET_LABEL="Tech (logical chair 6, receiver slot 6)"
    ;;
  chair7|watershed)
    EXPECTED_MAC="8c:94:df:45:b3:d0"
    TARGET_LABEL="Watershed (logical chair 7, receiver slot 7)"
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    echo "targets: chair1 agriculture gold-rush water-projects hydropower tech watershed" >&2
    exit 2
    ;;
esac
ROLLBACK_COMMIT="0cfad3388a3d5956b160d64e4b853b0b0ac2eccd"
ROLLBACK_SHA256="4de847e0fe9840ea7eea282d0f3ab3d31333b21ba405e2c6b034d98695ee0c9f"

if [[ ! -x "$ARDUINO_CLI" || ! -x "$ESPTOOL" ]]; then
  echo "Arduino ESP32 tools are not installed." >&2
  exit 1
fi

echo "Reading board identity on $PORT ..."
MAC=$("$ESPTOOL" --port "$PORT" read-mac 2>/dev/null |
  grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
if [[ "$MAC" != "$EXPECTED_MAC" ]]; then
  echo "REFUSING: expected $TARGET_LABEL ($EXPECTED_MAC), found ${MAC:-no MAC}." >&2
  exit 1
fi
echo "Confirmed $TARGET_LABEL: $MAC"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [[ "$VERSION" == "power-save" || "$VERSION" == "power-save-scheduled" ]]; then
  SKETCH="sender_power_save"
  mkdir -p "$STAGE/$SKETCH"
  cp "$APP_DIR/firmware/sender_power_save/sender_power_save.ino" \
     "$STAGE/$SKETCH/$SKETCH.ino"
  if [[ "$VERSION" == "power-save-scheduled" ]]; then
    SCHEDULE_BUILD_PROPERTY="compiler.cpp.extra_flags=-DGALLERY_SCHEDULE_ENABLED=1"
  fi
else
  SKETCH="sender_summary"
  mkdir -p "$STAGE/$SKETCH"
  git -C "$REPO" show \
    "$ROLLBACK_COMMIT:chair-occupancy-sensor/firmware/sender_summary.ino" \
    > "$STAGE/$SKETCH/$SKETCH.ino"
  ACTUAL_SHA256=$(openssl dgst -sha256 "$STAGE/$SKETCH/$SKETCH.ino" |
    awk '{print $NF}')
  if [[ "$ACTUAL_SHA256" != "$ROLLBACK_SHA256" ]]; then
    echo "REFUSING: rollback source checksum mismatch." >&2
    exit 1
  fi
  echo "Rollback source verified: $ROLLBACK_COMMIT"
fi

echo "Compiling $VERSION with $FQBN ..."
if [[ "$VERSION" == "power-save-scheduled" ]]; then
  "$ARDUINO_CLI" compile --fqbn "$FQBN" \
    --build-property "$SCHEDULE_BUILD_PROPERTY" "$STAGE/$SKETCH"
else
  "$ARDUINO_CLI" compile --fqbn "$FQBN" "$STAGE/$SKETCH"
fi

if [[ "$ACTION" == "compile" ]]; then
  echo "COMPILE OK: $VERSION"
  exit 0
fi

echo "Uploading $VERSION to $TARGET_LABEL ..."
"$ARDUINO_CLI" upload -p "$PORT" --fqbn "$FQBN" "$STAGE/$SKETCH"

echo "Hard resetting $TARGET_LABEL ..."
"$ESPTOOL" --port "$PORT" --after hard-reset chip-id >/dev/null 2>&1 || true

echo "DONE: $TARGET_LABEL is running $VERSION."
if [[ "$VERSION" == "power-save" || "$VERSION" == "power-save-scheduled" ]]; then
  echo "Rollback command:"
  echo "  $0 $PORT rollback upload $TARGET"
fi
