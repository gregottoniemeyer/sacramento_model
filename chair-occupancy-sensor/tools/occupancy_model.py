"""The occupancy model. One implementation, imported by every tool.

Rebuilt 2026-07-29 after the previous model false-positived badly in the real
seven-chair installation. It is DELIBERATELY SMALLER than what it replaces.

WHAT WAS WRONG BEFORE
The core detector was always right: gyro-Z dominance over X/Y, i.e. a swivel,
which is Max's original design. Measured on 9 real sit/stand cycles it fires on
96% of 1s windows while seated, 4% while somebody walks past, and 0% on an
empty chair. That discriminates fine.

What broke it was the machinery bolted on top to handle statue-sitters:
confidence set to 100 on any single fire, a 90-second linear decay, and release
gated on a "departure event" (a burst followed by quiet below a GLOBAL
threshold of 16 raw). Two fatal consequences:

  1. A 4% false-fire rate during a walk-by got latched into 90 seconds of
     OCCUPIED. That is the false-positive complaint, in full.
  2. Chairs whose noise floor sits above the global quiet bar can never
     register as quiet, so they can never be released at all. Chair 6 has only
     3.2% of its empty samples below 16: permanently OCCUPIED by construction.

So the fix was to delete that layer, not to tune it.

THE MODEL
Three signals, all computed on the sender over the full 100Hz stream and
transmitted at 8Hz (see firmware/sender_summary.ino):

  vote    Each packet votes "person-like motion" if gyro-Z std clears a floor
          AND dominates X+Y. Occupancy is decided by the FRACTION of votes over
          a trailing window, with hysteresis. No decay, no stickiness: the
          state follows the evidence and stops when the evidence stops.

  peak    The largest single-sample gyro step in the window. Sitting down is an
          impulse: 2009-10976 raw across nine sit-downs, against a maximum of
          952 for walking past an empty chair. That gap allows immediate
          detection instead of waiting for the vote window to fill, halving
          sit-down latency from 5.5s to 2.6s. An impulse-triggered entry is
          PROVISIONAL and reverts if the vote fraction does not back it up
          within a few seconds, so a hard knock cannot latch.

  yaw     Net rotation about the vertical axis, Max's idea. These are swivel
          chairs, so sitting rotates the seat slightly while passing footsteps
          do not: median 2.8 degrees for a sit-down against 0.2 for a walk-by.
          Gating entry on this removed the last false positive.

MEASURED, on data/dataset_20260729_154404.csv (9 cycles, chair 2, raw 100Hz),
and identically on the same data decimated to 8Hz summaries:
    sit detected     9/9    median latency 2.6s
    stand released   9/9    median latency 6.0s
    seated held      100% of the time, worst segment 100%
    false positives  0/9 walk-around blocks

GYRO BIAS IS NOT OPTIONAL. Integrating gyro-Z without removing the bias
fabricates rotation: chair 2's Z bias alone produces 3.4 degrees of fake yaw
every 8 seconds, which is larger than a real sit-down. The bias is learned
per chair, adaptively, from windows where the chair reads FREE and quiet --
there is no hand calibration to get wrong across seven chairs.

HONEST LIMITS
Tuned and measured on 9 cycles from ONE chair. The thresholds below are not
validated against data they did not see, which is exactly how the previous
model came to look better than it was. Re-run tools/collect_dataset.py
--profile basics on a second chair and score it before trusting these numbers.
"""

# ---- tunable constants -----------------------------------------------------
Z_FLOOR_RAW = 15          # gyro-Z 1s std must clear this to vote
RATIO_THRESHOLD = 0.65    # ...and exceed this * (stdX + stdY)

VOTE_WINDOW = 5.0         # trailing seconds of votes that decide occupancy
ENTER_FRAC = 0.50         # vote fraction to become OCCUPIED
# 0.25 -> 0.15 on 2026-07-29, on request, to hold a very still sitter slightly
# longer. Deliberately the SMALLEST available lever: it touches only the release
# side, so sit-down latency and the entry gates are bit-for-bit unchanged.
# Swept against both labeled datasets before picking (see tools/score_model.py):
#   EXIT_FRAC  release latency  still-sitter held  false positives
#     0.25          6.0s              81%               0%
#     0.15          6.5s              85%               0%     <- chosen
#     0.10          6.7s              88%               0%
# Stopped at 0.15 because "a tiny bit" was the request and the curve is nearly
# linear, so going further is available later at a known price. NOT a return to
# the old stickiness: there is still no decay and no confidence, so the state
# stops when the evidence stops. Lengthening VOTE_WINDOW would buy the same hold
# but slows entry too, which is why it was left alone.
EXIT_FRAC = 0.15          # vote fraction to fall back to FREE (hysteresis)

PEAK_JUMP_RAW = 1500      # sit-down impulse; walk-bys peaked at 952, sits at 2009+
PROVISIONAL_S = 4.0       # an impulse entry must be confirmed within this
CONFIRM_FRAC = 0.40       # ...by at least this vote fraction, or it reverts
IMPULSE_REFRACTORY_S = 4.0  # after an unconfirmed impulse, ignore impulses this long

YAW_WINDOW = 6.0          # trailing seconds over which net rotation accumulates
YAW_MIN_DEG = 1.0         # net yaw required for a vote-based entry

BIAS_ALPHA = 1.0 / 512.0  # gyro-Z bias tracker, only adapts while FREE and quiet
BIAS_QUIET_STD = 20       # "quiet" for bias learning, generous on purpose

GYRO_LSB_PER_DEG_S = 131.0
SAMPLE_HZ = 100.0         # the sender's internal sampling rate


class ChairModel:
    """Occupancy for one chair. Feed it packets, read `.occupied`."""

    def __init__(self):
        self.votes = []            # [(t, bool)]
        self.yaw_parts = []        # [(t, gyroZ_sum, n_samples)]
        self.occupied = False
        self.provisional_at = None
        self.bias_z = None
        self.vote_frac = 0.0
        self.yaw_deg = 0.0
        self.last_peak = 0
        self.prev_peak = None      # for rising-edge detection, see _decide
        self.impulse_blocked_until = None
        self.reason = "no data"

    # -- inputs ---------------------------------------------------------------
    def update(self, t, std_x, std_y, std_z, peak_jump,
               yaw_sum_new=None, n_new=None, gyro_mean_z=None):
        """One packet. yaw_* and gyro_mean_z may be None on older firmware,
        in which case the swivel gate is skipped rather than guessed at."""
        self.last_peak = peak_jump

        fires = (std_z > Z_FLOOR_RAW
                 and std_z / (std_x + std_y + 1) > RATIO_THRESHOLD)
        self.votes.append((t, fires))
        cutoff = t - VOTE_WINDOW
        self.votes = [v for v in self.votes if v[0] >= cutoff]
        self.vote_frac = (sum(f for _, f in self.votes) / len(self.votes)
                          if self.votes else 0.0)

        # Learn the gyro-Z bias only while this chair is FREE and quiet, so a
        # seated person's genuine rotation never gets absorbed into the bias.
        smax = max(std_x, std_y, std_z)
        if gyro_mean_z is not None and not self.occupied and smax < BIAS_QUIET_STD:
            if self.bias_z is None:
                self.bias_z = float(gyro_mean_z)
            else:
                self.bias_z += (gyro_mean_z - self.bias_z) * BIAS_ALPHA

        have_yaw = yaw_sum_new is not None and n_new is not None
        if have_yaw:
            self.yaw_parts.append((t, yaw_sum_new, n_new))
            ycut = t - YAW_WINDOW
            self.yaw_parts = [y for y in self.yaw_parts if y[0] >= ycut]
            bias = self.bias_z if self.bias_z is not None else 0.0
            tot_y = sum(y[1] for y in self.yaw_parts)
            tot_n = sum(y[2] for y in self.yaw_parts)
            self.yaw_deg = (abs((tot_y - bias * tot_n) / SAMPLE_HZ
                                / GYRO_LSB_PER_DEG_S) if tot_n else 0.0)
        else:
            self.yaw_deg = float("nan")

        self._decide(t, peak_jump, have_yaw)

    def _decide(self, t, peak_jump, have_yaw):
        # RISING EDGE, not level. peak_jump is a MAX over the sender's trailing
        # 1s window, so sustained motion holds it above the threshold
        # continuously: measured on chair 2 during vigorous play, 95% of packets
        # were above it, in unbroken runs of up to 17 seconds. A level test
        # therefore re-arms the instant an unconfirmed entry reverts, and the
        # state machine oscillates FREE/OCCUPIED with a period of exactly
        # PROVISIONAL_S. That was observed live on 2026-07-29 and is the reason
        # this is an edge test. "Sitting down is an impulse" means a transient,
        # and a level test on a window maximum cannot express a transient.
        rising = (self.prev_peak is not None
                  and self.prev_peak < PEAK_JUMP_RAW <= peak_jump)
        blocked = (self.impulse_blocked_until is not None
                   and t < self.impulse_blocked_until)
        self.prev_peak = peak_jump

        if not self.occupied:
            if rising and not blocked:
                # The sit-down impulse. Provisional: a knock on an empty chair
                # looks the same for an instant, so it must be confirmed.
                self.occupied = True
                self.provisional_at = t
                self.reason = "impulse (provisional)"
                return
            gate = (self.yaw_deg >= YAW_MIN_DEG) if have_yaw else True
            if self.vote_frac >= ENTER_FRAC and gate:
                self.occupied = True
                self.provisional_at = None
                self.reason = "sustained motion"
            return

        if self.provisional_at is not None:
            if t - self.provisional_at >= PROVISIONAL_S:
                if self.vote_frac >= CONFIRM_FRAC:
                    self.provisional_at = None
                    self.reason = "confirmed"
                else:
                    self.occupied = False
                    self.provisional_at = None
                    # Hold the impulse path off briefly. The edge test above
                    # already stops a latched peak from re-firing, but a train
                    # of separate knocks still produces separate edges, and
                    # without this a repeatedly-disturbed empty chair could
                    # still stutter.
                    self.impulse_blocked_until = t + IMPULSE_REFRACTORY_S
                    self.reason = "impulse not confirmed - was a knock"
            return

        if self.vote_frac <= EXIT_FRAC:
            self.occupied = False
            self.reason = "motion stopped"
