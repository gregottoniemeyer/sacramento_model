#!/usr/bin/env python3
"""Capture chair receiver serial output and feed it gallery clock state.

The Governator (.11) owns the wall clock.  This process keeps the receiver's
existing text output flowing into motion_log.txt while sending one compact
command back over the same full-duplex USB serial connection:

    GALLERY <open:0|1> <seconds-until-next-open>\n

The receiver treats commands as stale after a short timeout.  Sensors are
therefore allowed to deep-sleep only while this bridge is alive and updating
the receiver; loss of .11 clock data fails awake.
"""

from __future__ import annotations

import argparse
import datetime as dt
import errno
import math
import os
import select
import subprocess
import time
from pathlib import Path
from zoneinfo import ZoneInfo


DEFAULT_TIMEZONE = "America/Los_Angeles"
DEFAULT_OPEN_HOUR = 9
DEFAULT_CLOSE_HOUR = 21
DEFAULT_PERIOD_S = 5.0


def gallery_schedule(
    when: dt.datetime,
    open_hour: int = DEFAULT_OPEN_HOUR,
    close_hour: int = DEFAULT_CLOSE_HOUR,
) -> tuple[bool, int]:
    """Return (is_open, seconds_until_next_open) for a local zoned time."""
    if when.tzinfo is None or when.utcoffset() is None:
        raise ValueError("when must be timezone-aware")
    if not 0 <= open_hour < close_hour <= 24:
        raise ValueError("hours must describe one daytime open interval")

    opens = when.replace(
        hour=open_hour, minute=0, second=0, microsecond=0
    )
    if open_hour <= when.hour < close_hour:
        return True, 0

    if when < opens:
        next_open = opens
    else:
        next_open = dt.datetime.combine(
            when.date() + dt.timedelta(days=1),
            dt.time(open_hour),
            tzinfo=when.tzinfo,
        )

    # timestamp subtraction observes daylight-saving transitions, unlike
    # subtracting two datetimes that share the same ZoneInfo instance.
    remaining = max(1, math.ceil(next_open.timestamp() - when.timestamp()))
    return False, remaining


def schedule_command(
    when: dt.datetime,
    open_hour: int = DEFAULT_OPEN_HOUR,
    close_hour: int = DEFAULT_CLOSE_HOUR,
) -> bytes:
    is_open, seconds_until_open = gallery_schedule(
        when, open_hour=open_hour, close_hour=close_hour
    )
    return f"GALLERY {int(is_open)} {seconds_until_open}\n".encode("ascii")


def configure_serial(fd: int, baud: int) -> None:
    """Use macOS stty on the already-open descriptor to avoid a second reset."""
    subprocess.run(
        ["stty", "-f", f"/dev/fd/{fd}", str(baud), "raw", "-echo"],
        pass_fds=(fd,),
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def write_nonblocking(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        try:
            written = os.write(fd, view)
            view = view[written:]
        except BlockingIOError:
            _, ready, _ = select.select([], [fd], [], 0.25)
            if not ready:
                raise TimeoutError("receiver serial output queue stayed full")


def run_bridge(args: argparse.Namespace) -> None:
    zone = ZoneInfo(args.timezone)
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    fd = os.open(
        args.port,
        os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK,
    )
    try:
        configure_serial(fd, args.baud)
        next_schedule = 0.0
        with log_path.open("ab", buffering=0) as output:
            while True:
                now_mono = time.monotonic()
                if now_mono >= next_schedule:
                    command = schedule_command(dt.datetime.now(zone))
                    try:
                        write_nonblocking(fd, command)
                    except (BrokenPipeError, TimeoutError, OSError) as exc:
                        if isinstance(exc, OSError) and exc.errno not in {
                            errno.EAGAIN,
                            errno.EWOULDBLOCK,
                            errno.EIO,
                        }:
                            raise
                    next_schedule = now_mono + args.schedule_period

                timeout = max(0.0, min(0.5, next_schedule - time.monotonic()))
                readable, _, _ = select.select([fd], [], [], timeout)
                if fd not in readable:
                    continue
                try:
                    chunk = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    raise OSError("receiver serial port closed")
                output.write(chunk)
    finally:
        os.close(fd)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--timezone", default=DEFAULT_TIMEZONE)
    parser.add_argument("--open-hour", type=int, default=DEFAULT_OPEN_HOUR)
    parser.add_argument("--close-hour", type=int, default=DEFAULT_CLOSE_HOUR)
    parser.add_argument(
        "--schedule-period", type=float, default=DEFAULT_PERIOD_S
    )
    args = parser.parse_args()
    if args.schedule_period <= 0:
        parser.error("--schedule-period must be positive")
    if not 0 <= args.open_hour < args.close_hour <= 23:
        parser.error("hours must satisfy 0 <= open < close <= 23")
    return args


if __name__ == "__main__":
    run_bridge(parse_args())
