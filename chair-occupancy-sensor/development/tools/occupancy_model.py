"""Re-exports the model from controller.py, which is where it now lives.

One implementation only: the development tools score exactly what runs.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from controller import (  # noqa: F401,E402
    ChairModel, Z_FLOOR_RAW, RATIO_THRESHOLD, VOTE_WINDOW, ENTER_FRAC,
    EXIT_FRAC, PEAK_JUMP_RAW, PROVISIONAL_S, CONFIRM_FRAC,
    IMPULSE_REFRACTORY_S, YAW_WINDOW, YAW_MIN_DEG, BIAS_ALPHA, BIAS_QUIET_STD,
    GYRO_LSB_PER_DEG_S, SAMPLE_HZ,
)
