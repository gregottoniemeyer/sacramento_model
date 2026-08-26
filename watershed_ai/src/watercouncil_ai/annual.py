"""Build and read the installation's one-decision-per-model-day AI cache."""

from __future__ import annotations

import argparse
import json
import math
import sys
from concurrent.futures import Future, ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Callable, Iterable

from .agent import (
    AgentPolicyRun,
    DEFAULT_MODEL,
    MODEL_PRICING,
    load_local_api_key,
    propose_policy,
)
from .data import MODEL_SAMPLE_COUNT, load_observation
from .policy import _visual_state_hash, validate_policy
from .schemas import BasinObservation, SCREEN_IDS, ValidatedBasinDecision


MODEL_DAY_COUNT = 365
ANNUAL_DECISIONS_FILENAME = "annual-decisions.json"
ANNUAL_PARTIAL_FILENAME = ".annual-decisions.partial.json"


def model_position_for_day(day_index: int) -> tuple[int, float]:
    """Return the 720-row position at local noon for model day ``day_index``."""
    if day_index < 0 or day_index >= MODEL_DAY_COUNT:
        raise ValueError("day_index must be in 0..364")
    position = (day_index + 0.5) * MODEL_SAMPLE_COUNT / MODEL_DAY_COUNT
    frame_index = int(math.floor(position)) % MODEL_SAMPLE_COUNT
    return frame_index, position - math.floor(position)


def model_day_for_position(frame_index: int, frame_fraction: float = 0.0) -> int:
    """Map a live 720-row fleet phase to its zero-based July-through-June day."""
    if frame_index < 0 or frame_index >= MODEL_SAMPLE_COUNT:
        raise ValueError("frame_index must be in 0..719")
    if frame_fraction < 0.0 or frame_fraction >= 1.0:
        raise ValueError("frame_fraction must be in [0, 1)")
    position = frame_index + frame_fraction
    return min(int(math.floor(position * MODEL_DAY_COUNT / MODEL_SAMPLE_COUNT)), 364)


def annual_decisions_path(project_root: Path) -> Path:
    return project_root.resolve() / "watershed_ai/runlogs" / ANNUAL_DECISIONS_FILENAME


def _serialized_array(entries: list[ValidatedBasinDecision | None]) -> str:
    payload = [
        entry.model_dump(mode="json") if entry is not None else None
        for entry in entries
    ]
    return json.dumps(payload, indent=2) + "\n"


def _write_atomic(path: Path, serialized: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.tmp"
    temporary.write_text(serialized, encoding="utf-8")
    temporary.replace(path)


def _load_array(path: Path) -> list[ValidatedBasinDecision | None]:
    if not path.is_file():
        return [None] * MODEL_DAY_COUNT
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list) or len(raw) != MODEL_DAY_COUNT:
        raise ValueError(f"{path} must be a {MODEL_DAY_COUNT}-entry JSON array")
    entries: list[ValidatedBasinDecision | None] = []
    for day_index, value in enumerate(raw):
        if value is None:
            entries.append(None)
            continue
        decision = ValidatedBasinDecision.model_validate(value)
        expected_frame, _fraction = model_position_for_day(day_index)
        if decision.frame_index != expected_frame:
            raise ValueError(
                f"{path} day {day_index} has frame {decision.frame_index}; "
                f"expected {expected_frame}"
            )
        if tuple(river.screen_id for river in decision.rivers) != SCREEN_IDS:
            raise ValueError(f"{path} day {day_index} has noncanonical river order")
        for river in decision.rivers:
            state = river.visual_state
            if (
                river.frame_index != decision.frame_index
                or state.frame_index != decision.frame_index
            ):
                raise ValueError(f"{path} day {day_index} has inconsistent frames")
            if state.decision_id != decision.decision_id:
                raise ValueError(f"{path} day {day_index} has inconsistent decision IDs")
            if _visual_state_hash(state.model_dump(mode="python")) != state.state_hash:
                raise ValueError(f"{path} day {day_index} has an invalid state hash")
        entries.append(decision)
    return entries


def _load_build_entries(
    partial_path: Path,
    final_path: Path,
) -> list[ValidatedBasinDecision | None]:
    """Resume a partial build, or reuse an already-complete final array."""
    return _load_array(partial_path if partial_path.is_file() else final_path)


def load_annual_decision(
    path: Path,
    frame_index: int,
    frame_fraction: float = 0.0,
) -> tuple[int, ValidatedBasinDecision]:
    """Validate the complete array and select the live fleet phase's entry."""
    entries = _load_array(path)
    if any(entry is None for entry in entries):
        raise ValueError(f"{path} must contain all {MODEL_DAY_COUNT} decisions")
    decision_ids = [entry.decision_id for entry in entries if entry is not None]
    if len(decision_ids) != len(set(decision_ids)):
        raise ValueError(f"{path} must contain {MODEL_DAY_COUNT} unique decisions")
    day_index = model_day_for_position(frame_index, frame_fraction)
    decision = entries[day_index]
    if decision is None:  # Narrow the type after the completeness check above.
        raise ValueError(f"{path} has no decision for day {day_index}")
    return day_index, decision


def _generate_day(
    project_root: Path,
    day_index: int,
    model: str,
    proposer: Callable[[BasinObservation, Path, str], AgentPolicyRun],
) -> ValidatedBasinDecision:
    frame_index, frame_fraction = model_position_for_day(day_index)
    observation = load_observation(project_root, frame_index, frame_fraction)
    agent_run = proposer(observation, project_root, model)
    return validate_policy(observation, agent_run.proposal, agent_run.report)


def build_annual_decisions(
    project_root: Path,
    *,
    model: str = DEFAULT_MODEL,
    workers: int = 4,
    proposer: Callable[[BasinObservation, Path, str], AgentPolicyRun] = propose_policy,
    days: Iterable[int] | None = None,
) -> tuple[Path | None, list[int], float]:
    """Resume generation, checkpointing one 365-entry partial array atomically."""
    if model not in MODEL_PRICING:
        raise ValueError(f"supported costed models: {', '.join(MODEL_PRICING)}")
    if workers < 1 or workers > 8:
        raise ValueError("workers must be in 1..8")
    root = project_root.resolve()
    runlogs = root / "watershed_ai/runlogs"
    partial_path = runlogs / ANNUAL_PARTIAL_FILENAME
    final_path = annual_decisions_path(root)
    entries = _load_build_entries(partial_path, final_path)
    requested_days = list(range(MODEL_DAY_COUNT) if days is None else days)
    if any(day < 0 or day >= MODEL_DAY_COUNT for day in requested_days):
        raise ValueError("all requested days must be in 0..364")
    if len(requested_days) != len(set(requested_days)):
        raise ValueError("requested days must not contain duplicates")
    pending = [day for day in requested_days if entries[day] is None]
    if not pending:
        if all(entry is not None for entry in entries):
            _write_atomic(final_path, _serialized_array(entries))
            partial_path.unlink(missing_ok=True)
            return final_path, [], sum(
                entry.model_run.estimated_cost_usd
                for entry in entries
                if entry is not None and entry.model_run is not None
            )
        return None, [], sum(
            entry.model_run.estimated_cost_usd
            for entry in entries
            if entry is not None and entry.model_run is not None
        )

    failures: list[int] = []
    runlogs.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=min(workers, len(pending))) as pool:
        futures: dict[Future[ValidatedBasinDecision], int] = {
            pool.submit(_generate_day, root, day, model, proposer): day
            for day in pending
        }
        for future in as_completed(futures):
            day_index = futures[future]
            try:
                decision = future.result()
            except Exception as error:  # The partial array makes every failure resumable.
                failures.append(day_index)
                print(f"ERROR day={day_index:03d}: {error}", file=sys.stderr, flush=True)
                continue
            entries[day_index] = decision
            _write_atomic(partial_path, _serialized_array(entries))
            completed = sum(entry is not None for entry in entries)
            cost = sum(
                entry.model_run.estimated_cost_usd
                for entry in entries
                if entry is not None and entry.model_run is not None
            )
            print(
                f"READY day={day_index:03d} frame={decision.frame_index:03d} "
                f"decision={decision.decision_id} completed={completed}/365 "
                f"estimated_cost=${cost:.6f}",
                flush=True,
            )

    total_cost = sum(
        entry.model_run.estimated_cost_usd
        for entry in entries
        if entry is not None and entry.model_run is not None
    )
    if not failures and all(entry is not None for entry in entries):
        _write_atomic(final_path, _serialized_array(entries))
        partial_path.unlink(missing_ok=True)
        return final_path, [], total_cost
    return None, sorted(failures), total_cost


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate the Water Council's 365-entry annual AI decision array"
    )
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--model", default=DEFAULT_MODEL, choices=tuple(MODEL_PRICING))
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument(
        "--day",
        type=int,
        action="append",
        help="generate only this zero-based model day; repeat for several days",
    )
    args = parser.parse_args(argv)
    try:
        load_local_api_key(args.project_root)
        path, failures, cost = build_annual_decisions(
            args.project_root,
            model=args.model,
            workers=args.workers,
            days=args.day,
        )
        if failures:
            print(
                f"INCOMPLETE failures={','.join(f'{day:03d}' for day in failures)} "
                f"estimated_cost=${cost:.6f}; rerun to resume",
                file=sys.stderr,
            )
            return 1
        if path is None:
            if args.day is not None:
                generated = ",".join(f"{day:03d}" for day in args.day)
                print(
                    f"CHECKPOINTED days={generated} estimated_cost=${cost:.6f}; "
                    "annual array remains incomplete"
                )
                return 0
            print("INCOMPLETE annual array; rerun to resume", file=sys.stderr)
            return 1
        print(f"COMPLETE {path} entries=365 estimated_cost=${cost:.6f}")
        return 0
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
