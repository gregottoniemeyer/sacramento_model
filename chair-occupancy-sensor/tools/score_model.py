"""Score tools/occupancy_model.py against a labeled dataset. THE HONESTY TOOL.

WHY THIS FILE EXISTS
The model rebuilt on 2026-07-29 reported sit 9/9 at 2.6s, release 9/9 at 6.0s,
seated held 100%, 0 false positives. Those numbers were produced ad hoc during
development and nothing in the repository could reproduce them: as committed,
occupancy_model.py was imported by no tool at all. An unreproducible score is
not a measurement, and the previous model's reputation was built on exactly
that kind of number. This file makes the claim checkable, on any dataset, by
anybody, in one command.

It is deliberately separate from the model. The model file holds no scoring
code and this file holds no thresholds, so there is no way to quietly tune a
constant to make a score come out.

WHAT IT DOES
Two input formats, both produced by tools/collect_dataset.py:

  fmt=raw   100Hz samples straight off the sensor. These are replayed through
            a faithful reimplementation of sender_summary.ino (see SenderSim)
            so the model sees exactly the packets the real firmware would have
            transmitted, including the 1s trailing std window, the window-max
            peak jump, and the per-packet yaw sum. This is what lets a raw
            recording answer questions about the deployed 8Hz fleet.

  fmt=sum   Summary packets as the firmware sent them. Used directly.
            Recordings made before 2026-07-29 have no Peak/YawS/YawN columns,
            so the model runs DEGRADED: no impulse fast path, no swivel gate,
            vote path only. The report says so explicitly rather than letting a
            weaker configuration be mistaken for the real one.

Ground truth comes from the is_occupied column, which collect_dataset.py writes
per row per chair. Events are taken from the 0->1 and 1->0 edges of that column,
so the scorer works on any profile without knowing the protocol.

WHAT IS EXCLUDED FROM SCORING, AND WHY
  - is_transition rows. During "sit down now" and "stand up now" the label is
    genuinely ambiguous: the person is mid-movement and neither answer is
    wrong. Counting those as errors measures the collection protocol, not the
    model.
  - A settle window after each stand-up (--settle, default 12s). A chair keeps
    wobbling for seconds after somebody leaves, and the release latency is
    already reported as its own number. Counting the same seconds again as
    false-positive time would double-charge for one behaviour. Both the masked
    and unmasked figures are printed.

Usage:
  venv/bin/python tools/score_model.py data/dataset_20260729_154404.csv
  venv/bin/python tools/score_model.py data/*.csv --chairs 3,4,5
  venv/bin/python tools/score_model.py data/foo.csv --tx-hz 100   # no decimation
"""

import argparse
import csv
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from occupancy_model import ChairModel  # noqa: E402  (path set above)

# ---- constants mirrored from firmware/sender_summary.ino --------------------
# These describe the SENDER, not the model, which is why they live here and not
# in occupancy_model.py. If the firmware changes, change these to match and the
# replay stays faithful.
WINDOW_SAMPLES = 100          # WINDOW_MS 1000 / SAMPLE_PERIOD_MS 10
BIG_DELTA_RAW = 3000          # a single-sample gyro jump this large counts as "big"
TX_PERIOD_MS = 125            # 8Hz

# ---- scoring windows -------------------------------------------------------
# Latencies are measured from the ground-truth occupancy edge, which is the
# instant the "sit down now" / "stand up now" cue was spoken. That means every
# latency reported here INCLUDES human reaction time to the cue. It is the
# pessimistic reading and the one that matches what a visitor experiences.
SIT_DEADLINE = 15.0           # a sit-down not seen within this counts as missed
STAND_DEADLINE = 30.0         # a stand-up not released within this counts as missed


class SenderSim:
    """Reimplementation of sender_summary.ino's summarising, for replay.

    Faithful to the firmware in the three details that matter to the model:
    the std is over a 1s trailing window of 100Hz samples; peakJump is the MAX
    over that whole overlapping window (not just the new samples, so a dropped
    packet cannot hide a sit-down); and yawSum/nNew partition the timeline,
    resetting at every transmission.
    """

    def __init__(self, tx_period_ms=TX_PERIOD_MS):
        self.tx_period = tx_period_ms / 1000.0
        self.buf = []               # [(gx, gy, gz, jump)], newest last, <= 100
        self.prev_gyro = None
        self.yaw_accum = 0
        self.yaw_count = 0
        self.next_tx = None

    def push(self, t, gx, gy, gz):
        """Feed one 100Hz sample. Returns a packet dict, or None."""
        if self.prev_gyro is None:
            jump = 0
        else:
            jump = max(abs(gx - self.prev_gyro[0]),
                       abs(gy - self.prev_gyro[1]),
                       abs(gz - self.prev_gyro[2]))
        self.prev_gyro = (gx, gy, gz)

        self.buf.append((gx, gy, gz, jump))
        if len(self.buf) > WINDOW_SAMPLES:
            self.buf.pop(0)
        self.yaw_accum += gz
        self.yaw_count = min(255, self.yaw_count + 1)

        if self.next_tx is None:
            self.next_tx = t + self.tx_period
            return None
        if t < self.next_tx:
            return None
        self.next_tx += self.tx_period
        return self._packet(t)

    def _packet(self, t):
        n = len(self.buf)
        stds = []
        for axis in range(3):
            vals = [s[axis] for s in self.buf]
            # Population std, matching stdOf()'s sumSq/n - mean^2, then
            # truncated to an integer the way the uint16_t cast does.
            if n < 2:
                stds.append(0)
                continue
            mean = sum(vals) / n
            var = sum(v * v for v in vals) / n - mean * mean
            stds.append(int(max(0.0, var) ** 0.5))
        pkt = dict(
            t=t,
            std_x=stds[0], std_y=stds[1], std_z=stds[2],
            peak=min(65535, max(s[3] for s in self.buf)) if n else 0,
            big=sum(1 for s in self.buf if s[3] > BIG_DELTA_RAW),
            yaw_sum=self.yaw_accum,
            n_new=self.yaw_count,
            # The firmware sends the window MEAN of gyroZ, which is what the
            # bias tracker consumes. Not the same span as yaw_sum, by design.
            gyro_mean_z=int(sum(s[2] for s in self.buf) / n) if n else 0,
        )
        self.yaw_accum = 0
        self.yaw_count = 0
        return pkt


def load(path):
    """Rows grouped by chair, in timestamp order, one dominant format each.

    A chair recorded in summary format sometimes has a minority of rows written
    as fmt=raw. That is not a firmware event: it is the collector's log tailer
    reading an unterminated line, so V2_RE misses and the V1_RE prefix matches
    the same text. Those rows carry no statistics and are dropped here, with a
    count, because a handful of stray 100Hz-shaped rows inside an 8Hz stream
    would otherwise be replayed as if the chair had changed firmware mid-run.
    """
    by_chair = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            by_chair.setdefault(int(row["chair"]), []).append(row)

    out = {}
    for chair, rows in sorted(by_chair.items()):
        # Datasets from before the fmt column existed are all summary format.
        fmts = [r.get("fmt") or "sum" for r in rows]
        dominant = max(set(fmts), key=fmts.count)
        keep = [r for r, fm in zip(rows, fmts) if fm == dominant]
        out[chair] = dict(fmt=dominant, rows=keep, dropped=len(rows) - len(keep))
    return out


def run_chair(rows, fmt, tx_hz):
    """Replay one chair. Returns [(t, occupied, is_occupied, is_transition)]."""
    model = ChairModel()
    trace = []
    sim = SenderSim(1000.0 / tx_hz) if fmt == "raw" else None

    for r in rows:
        t = float(r["t"])
        truth = r["is_occupied"] == "1"
        trans = r["is_transition"] == "1"

        if sim is not None:
            pkt = sim.push(t, int(r["gyroX"]), int(r["gyroY"]), int(r["gyroZ"]))
            if pkt is None:
                continue
            model.update(pkt["t"], pkt["std_x"], pkt["std_y"], pkt["std_z"],
                         pkt["peak"], pkt["yaw_sum"], pkt["n_new"],
                         pkt["gyro_mean_z"])
        else:
            if not r.get("stdZ"):
                continue                      # torn or v1 row, no statistics
            # Peak/YawS/YawN are absent in recordings made before 2026-07-29.
            # Passing None makes the model skip the swivel gate rather than
            # guess at it, and there is no impulse to feed the fast path.
            peak = int(r["peak"]) if r.get("peak") else 0
            yaw_sum = int(r["yawSum"]) if r.get("yawSum") else None
            n_new = int(r["yawN"]) if r.get("yawN") else None
            model.update(t, int(r["stdX"]), int(r["stdY"]), int(r["stdZ"]),
                         peak, yaw_sum, n_new, int(r["gyroZ"]))

        trace.append((t, model.occupied, truth, trans))
    return trace


def score(trace, settle):
    """Events and steady-state accuracy from one replayed trace."""
    sits, stands = [], []           # latencies in seconds; None means missed
    prev_truth = None

    # Ground-truth edges. Everything downstream is derived from these, so the
    # scorer needs no knowledge of which collection profile produced the file.
    edges = []
    for i, (t, _occ, truth, _tr) in enumerate(trace):
        if prev_truth is not None and truth != prev_truth:
            edges.append((t, truth, i))
        prev_truth = truth

    for t_edge, became_occupied, i in edges:
        deadline = t_edge + (SIT_DEADLINE if became_occupied else STAND_DEADLINE)
        hit = None
        for t, occ, _truth, _tr in trace[i:]:
            if t > deadline:
                break
            if occ == became_occupied:
                hit = t - t_edge
                break
        (sits if became_occupied else stands).append(hit)

    # Steady state, transitions excluded. A stand-up edge also opens a settle
    # window: the chair is physically still moving and the release latency
    # above already accounts for it.
    stand_times = [t for t, became, _ in edges if not became]
    seated_n = seated_hit = empty_n = empty_fp = empty_fp_masked = masked_n = 0
    for t, occ, truth, trans in trace:
        if trans:
            continue
        if truth:
            seated_n += 1
            seated_hit += occ
        else:
            empty_n += 1
            empty_fp += occ
            if any(0 <= t - ts <= settle for ts in stand_times):
                continue
            masked_n += 1
            empty_fp_masked += occ

    def med(xs):
        got = [x for x in xs if x is not None]
        return statistics.median(got) if got else None

    return dict(
        sit_hit=sum(1 for s in sits if s is not None), sit_n=len(sits),
        sit_med=med(sits), sit_max=max([s for s in sits if s is not None],
                                       default=None),
        stand_hit=sum(1 for s in stands if s is not None), stand_n=len(stands),
        stand_med=med(stands), stand_max=max([s for s in stands
                                              if s is not None], default=None),
        seated_frac=(seated_hit / seated_n) if seated_n else None,
        seated_n=seated_n,
        fp_frac=(empty_fp / empty_n) if empty_n else None,
        fp_frac_masked=(empty_fp_masked / masked_n) if masked_n else None,
        empty_n=empty_n,
    )


def fmt_num(x, suffix="", nd=1):
    return "     -" if x is None else f"{x:.{nd}f}{suffix}"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("datasets", nargs="+")
    ap.add_argument("--chairs", default="", help="comma list, default all")
    ap.add_argument("--tx-hz", type=float, default=1000.0 / TX_PERIOD_MS,
                    help="packet rate to simulate from raw rows (default 8)")
    ap.add_argument("--settle", type=float, default=12.0,
                    help="seconds after a stand-up excluded from false-positive "
                         "accounting (default 12)")
    args = ap.parse_args()

    want = {int(c) for c in args.chairs.split(",") if c.strip()}

    for path in args.datasets:
        data = load(path)
        print(f"\n{'=' * 78}\n{Path(path).name}")
        print(f"{'=' * 78}")
        header = (f"{'chair':>5} {'fmt':>4} {'mode':>9} │ "
                  f"{'sit':>7} {'med':>6} {'max':>6} │ "
                  f"{'stand':>7} {'med':>6} {'max':>6} │ "
                  f"{'seated':>7} {'FP':>6} {'FPmask':>7}")
        print(header)
        print("-" * len(header))

        for chair, d in data.items():
            if want and chair not in want:
                continue
            trace = run_chair(d["rows"], d["fmt"], args.tx_hz)
            if not trace:
                print(f"{chair:>5} {d['fmt']:>4}  no usable packets")
                continue
            s = score(trace, args.settle)

            if d["fmt"] == "raw":
                mode = f"{args.tx_hz:g}Hz sim"
            else:
                has_yaw = any(r.get("yawSum") for r in d["rows"])
                mode = "full" if has_yaw else "DEGRADED"

            print(f"{chair:>5} {d['fmt']:>4} {mode:>9} │ "
                  f"{s['sit_hit']:>3}/{s['sit_n']:<3} "
                  f"{fmt_num(s['sit_med'], 's'):>6} {fmt_num(s['sit_max'], 's'):>6} │ "
                  f"{s['stand_hit']:>3}/{s['stand_n']:<3} "
                  f"{fmt_num(s['stand_med'], 's'):>6} "
                  f"{fmt_num(s['stand_max'], 's'):>6} │ "
                  f"{fmt_num(s['seated_frac'] and s['seated_frac'] * 100, '%', 0):>7} "
                  f"{fmt_num(s['fp_frac'] and s['fp_frac'] * 100, '%', 0):>6} "
                  f"{fmt_num(s['fp_frac_masked'] and s['fp_frac_masked'] * 100, '%', 0):>7}")
            if d["dropped"]:
                print(f"{'':>5} {'':>4} {'':>9}   ({d['dropped']} torn rows dropped)")

        print("\nDEGRADED means the recording predates peakJump/yawSum, so the")
        print("impulse fast path and the swivel gate are both inactive: this is")
        print("the vote path alone, and is NOT the deployed configuration.")
        print("Latencies include human reaction time to the spoken cue.")


if __name__ == "__main__":
    main()
