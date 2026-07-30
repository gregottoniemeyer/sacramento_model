#!/bin/bash
# Flash one chair sender, identifying the board by MAC before writing anything.
#
# WHY IT CHECKS THE MAC FIRST
# ../development/ARCHIVE.md records that flashing sender code onto the receiver "succeeds" with no
# error and leaves the two boards disagreeing about the packet struct, which then
# presents as shifted field values rather than as a failure. The port name cannot
# prevent that: a CP2102 chair and the receiver can both land on a
# /dev/cu.usbserial-* node, and the suffix moves between USB slots. So this
# refuses to write until it has read the MAC and recognised it as a chair.
#
# It also always finishes with an explicit hard reset. Two of seven boards land
# in the ROM bootloader after an upload (GPIO0 sampled low from the USB adapter's
# RTS/DTR timing), printing "waiting for download" and looking completely dead
# while arduino-cli reports success.
#
# Usage:  tools/flash_chair.sh /dev/cu.SLAB_USBtoUART
#         tools/flash_chair.sh /dev/cu.SLAB_USBtoUART receiver

set -euo pipefail

PORT="${1:-}"
ROLE="${2:-sender}"
if [[ -z "$PORT" ]]; then
  echo "usage: $0 <port> [sender|receiver]" >&2
  echo "ports present:" >&2
  ls /dev/cu.* >&2
  exit 2
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESPTOOL=$(echo "$HOME"/Library/Arduino15/packages/esp32/tools/esptool_py/*/esptool | tr ' ' '\n' | tail -1)
FQBN="esp32:esp32:esp32"
RECEIVER_MAC="78:1c:3c:35:83:6c"

# Chair number by MAC, mirroring the table in firmware/receiver_esp_now.ino.
# Labels carry the last two
# octets precisely so a board can be identified without opening anything.
mac_to_chair() {
  case "$1" in
    8c:94:df:46:b5:54) echo 1 ;;
    88:f1:55:30:af:b4) echo 2 ;;
    88:f1:55:32:49:c4) echo 3 ;;
    8c:94:df:45:ca:28) echo 4 ;;
    88:f1:55:30:a6:58) echo 5 ;;
    8c:94:df:97:4f:34) echo 6 ;;
    8c:94:df:45:b3:d0) echo 7 ;;
    78:1c:3c:35:83:6c) echo receiver ;;
    # Slot 8 = the recovered original chair-2 board, reassigned 2026-07-30.
    # It was retired on 2026-07-22 for corrupted I2C reads (see ../development/ARCHIVE.md); its
    # sensor must pass a bench check before this board is trusted as a spare.
    88:f1:55:32:5f:6c) echo 8 ;;
    # 78:1c:3c:35:04:84 (the Lonely Binary bench board, ex-MAC-cloned second
    # receiver) HELD slot 8 until 2026-07-30 and is now displaced, so it is
    # deliberately absent here and will be refused as "unknown". To bring it
    # back, give it a slot in receiver_esp_now.ino first, then add it here.
    *) echo unknown ;;
  esac
}

echo "reading MAC on $PORT ..."
MAC=$("$ESPTOOL" --port "$PORT" read-mac 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
if [[ -z "$MAC" ]]; then
  echo "FAILED to read a MAC on $PORT." >&2
  echo "Most likely causes, in order:" >&2
  echo "  1. a charge-only USB cable (powers the board, no data wires)" >&2
  echo "  2. the board's power switch is off" >&2
  echo "  3. macOS is still waiting on its 'Allow USB accessory' prompt" >&2
  exit 1
fi

WHO=$(mac_to_chair "$MAC")
echo "  MAC $MAC  ->  $WHO"

if [[ "$ROLE" == "sender" ]]; then
  if [[ "$MAC" == "$RECEIVER_MAC" || "$WHO" == receiver* ]]; then
    echo "REFUSING: that is the RECEIVER. Flashing sender code onto it would" >&2
    echo "succeed silently and break the whole fleet. Pass 'receiver' if you" >&2
    echo "really mean to reflash the receiver." >&2
    exit 1
  fi
  if [[ "$WHO" == "unknown" ]]; then
    echo "REFUSING: MAC $MAC is not in the chair table." >&2
    echo "Add it to firmware/receiver_esp_now.ino AND to this script first," >&2
    echo "so the receiver can label its packets. See README.md." >&2
    exit 1
  fi
  SKETCH=sender_summary
else
  SKETCH=receiver_esp_now
fi

# arduino-cli needs one sketch per directory, named after the directory, and
# firmware/ holds every .ino flat. Stage a copy rather than restructure the repo.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$SKETCH"
cp "$REPO/firmware/$SKETCH.ino" "$STAGE/$SKETCH/"

echo "compiling $SKETCH ..."
arduino-cli compile --fqbn "$FQBN" "$STAGE/$SKETCH" >/dev/null
echo "uploading to $WHO on $PORT ..."
arduino-cli upload -p "$PORT" --fqbn "$FQBN" "$STAGE/$SKETCH" >/dev/null

# Always reset explicitly, see the DOWNLOAD_BOOT note above.
echo "hard resetting ..."
"$ESPTOOL" --port "$PORT" --after hard-reset chip-id >/dev/null 2>&1 || true

echo
echo "DONE: $WHO flashed with $SKETCH."
echo "Verify it is really alive before moving on:"
echo "  grep -c 'Chair:$WHO ' ~/motion_log.txt   # should climb at ~8/sec"
echo "and confirm the line carries Peak:/YawS:/YawN: and Flags:7 N:100."
