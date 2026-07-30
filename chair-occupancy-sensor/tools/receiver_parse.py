"""The ONE parser for receiver serial output. Every tool imports this.

WHY THIS FILE EXISTS
On 2026-07-29 the receiver firmware gained three fields (Peak, YawS, YawN)
printed between TBase: and Up:. collect_dataset.py had its own private regex
that required Up: to follow TBase: directly, so it stopped matching. It did not
fail loudly: its raw-format fallback regex is a PREFIX of the summary line, so
it matched instead and every summary packet would have been recorded as a raw
100Hz sample with all statistics blank. A collection run would have produced a
file that looked plausible and was worthless.

That is the whole argument for this module. The wire format is described in
exactly one place, so adding a field to the firmware cannot silently
invalidate a tool that was not updated with it.

THE THREE FORMATS, newest first. They are tried in this order because each
older one is a prefix of the newer, so the newest match must win.

  v3  summary + Peak/YawS/YawN. Current firmware. Packet is 39 bytes.
  v2  summary without them. Packet was 32 bytes. Still parsed because logs
      recorded before 2026-07-29 are full of it and remain useful.
  v1  raw 100Hz sample, accel/gyro/temp only. Packet is 14 bytes. Used for
      model development, where offline code needs the samples the firmware
      would otherwise have summarised away.

A line reporting BAD PACKET is returned as fmt="bad". That is not noise to be
skipped: it is the signature of a sender and receiver disagreeing about the
packet length, which is exactly what happens when one is flashed and the other
is not. Tools should surface it rather than drop it.
"""

import os
import re
import time

# Field order matters: it is the CSV column order collect_dataset.py writes.
SUMMARY_FIELDS = ["accX", "accY", "accZ", "gyroX", "gyroY", "gyroZ", "temp",
                  "stdX", "stdY", "stdZ", "big", "n", "touch", "tbase",
                  "peak", "yawSum", "yawN", "up", "seq", "flags", "rssi"]
RAW_FIELDS = ["accX", "accY", "accZ", "gyroX", "gyroY", "gyroZ", "temp"]

_COMMON = (r"Chair:(\d+)\s+"
           r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
           r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
           r"Temp:(-?\d+)")
_STATS = (r"\s+Std\s+X:(\d+)\s+Y:(\d+)\s+Z:(\d+)\s+"
          r"Big:(\d+)\s+N:(\d+)\s+"
          r"Touch:(\d+)\s+TBase:(\d+)")
_TAIL = r"\s+Up:(\d+)\s+Seq:(\d+)\s+Flags:(\d+)\s+Rssi:(-?\d+)"

V3_RE = re.compile(_COMMON + _STATS +
                   r"\s+Peak:(\d+)\s+YawS:(-?\d+)\s+YawN:(\d+)" + _TAIL)
V2_RE = re.compile(_COMMON + _STATS + _TAIL)
V1_RE = re.compile(_COMMON + r"\s+Rssi:(-?\d+)")
BAD_RE = re.compile(r"Chair:(\d+)\s+BAD PACKET len:(\d+)")


def parse(line):
    """One serial line to a dict, or None if it is not a packet.

    Returned dicts always carry "chair" and "fmt". Summary rows carry every key
    in SUMMARY_FIELDS, with peak/yawSum/yawN set to None on a v2 line rather
        than to a plausible-looking zero: the model treats None as "this
    firmware cannot tell me", and a zero would read as "no rotation happened",
    which is a different and wrong claim.
    """
    m = BAD_RE.search(line)
    if m:
        return dict(chair=int(m.group(1)), fmt="bad", length=int(m.group(2)))

    m = V3_RE.search(line)
    if m:
        # V3_RE's group order is SUMMARY_FIELDS exactly, which is the reason
        # SUMMARY_FIELDS is written in wire order rather than in a tidier one.
        vals = [int(g) for g in m.groups()[1:]]
        return dict(chair=int(m.group(1)), fmt="sum",
                    **dict(zip(SUMMARY_FIELDS, vals)))

    m = V2_RE.search(line)
    if m:
        vals = [int(g) for g in m.groups()[1:]]
        body = vals[:14] + [None, None, None] + vals[14:]
        return dict(chair=int(m.group(1)), fmt="sum",
                    **dict(zip(SUMMARY_FIELDS, body)))

    m = V1_RE.search(line)
    if m:
        vals = [int(g) for g in m.groups()[1:]]
        return dict(chair=int(m.group(1)), fmt="raw",
                    **dict(zip(RAW_FIELDS, vals[:7])), rssi=vals[7])
    return None


def follow(path, stop=None):
    """Yield COMPLETE lines as they are appended, surviving truncation.

    The completeness matters and was a real bug. A reader doing readline() on a
    file another process is appending to gets whatever bytes have landed, which
    is frequently half a line. Those fragments then fail the summary regex and
    match the shorter raw one, so about 5% of the rows for chairs 1, 4 and 5 in
    data/dataset_20260729_154404.csv are recorded as raw with no statistics.
    Holding a partial line until its newline arrives is the entire fix.
    """
    f = open(path, "r", errors="replace")
    f.seek(0, os.SEEK_END)
    where = f.tell()
    buf = ""
    while stop is None or not stop.is_set():
        try:
            if os.stat(path).st_size < where:      # truncated or replaced
                f.close()
                f = open(path, "r", errors="replace")
                buf = ""
        except FileNotFoundError:
            time.sleep(0.2)
            continue
        chunk = f.readline()
        where = f.tell()
        if not chunk:
            time.sleep(0.02)
            continue
        buf += chunk
        if not buf.endswith("\n"):
            continue                              # incomplete, wait for more
        line, buf = buf, ""
        yield line
