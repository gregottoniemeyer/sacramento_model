"""Command line interface for local policy previews and deliberate live sends."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .agent import DEFAULT_MODEL, MODEL_PRICING, propose_policy
from .controller import (
    PartialApplyError,
    apply_decision,
    assert_studio_operator,
    assert_watershed_active,
)
from .data import load_observation
from .policy import validate_policy
from .schemas import ValidatedBasinDecision


def default_project_root() -> Path:
    marker = Path(
        "godot_experiments/flow/data/water_pipeline/shasta_720.txt"
    )
    local_marker = Path("flow/data/water_pipeline/shasta_720.txt")
    candidates = (Path.cwd(), Path.cwd().parent, Path(__file__).resolve().parents[3])
    for candidate in candidates:
        if (candidate / marker).is_file() or (candidate / local_marker).is_file():
            return candidate.resolve()
    return Path.cwd().resolve()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a bounded Watershed visualization policy with OpenAI"
    )
    parser.add_argument("--project-root", type=Path, default=default_project_root())
    parser.add_argument("--frame", type=int, help="installation frame 0..719")
    parser.add_argument("--fraction", type=float, help="fraction toward next frame")
    parser.add_argument(
        "--current",
        action="store_true",
        help="use the fleet's current validated model phase (live mode only)",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        choices=tuple(MODEL_PRICING),
        help="cost-accounted OpenAI model",
    )
    parser.add_argument(
        "--decision",
        type=Path,
        help="validate or replay a saved decision without an OpenAI API call",
    )
    parser.add_argument(
        "--live",
        action="store_true",
        help="send to Godot; otherwise print a dry-run decision only",
    )
    return parser


def persist_live_decision(
    project_root: Path,
    decision: ValidatedBasinDecision,
) -> Path:
    """Save a non-secret recovery copy before the first fleet packet."""
    runlog_directory = project_root.resolve() / "watershed_ai/runlogs"
    runlog_directory.mkdir(parents=True, exist_ok=True)
    target = runlog_directory / f"decision-{decision.decision_id}.json"
    latest = runlog_directory / "latest-decision.json"
    serialized = decision.model_dump_json(indent=2) + "\n"
    for destination in (target, latest):
        temporary = runlog_directory / f".{destination.name}.tmp"
        temporary.write_text(serialized, encoding="utf-8")
        temporary.replace(destination)
    return target


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    recovery_path: Path | None = None
    try:
        if args.current and not args.live:
            raise ValueError("--current requires --live")
        if args.current and args.decision is not None:
            raise ValueError("--current cannot be combined with --decision")
        if args.current and (args.frame is not None or args.fraction is not None):
            raise ValueError("--current cannot be combined with --frame or --fraction")
        if args.fraction is not None and args.frame is None:
            raise ValueError("--fraction requires --frame")
        fleet_moment = None
        if args.live:
            assert_studio_operator()
            fleet_moment = assert_watershed_active()
        if args.decision is not None:
            decision = ValidatedBasinDecision.model_validate_json(
                args.decision.read_text(encoding="utf-8")
            )
        else:
            if args.current:
                if fleet_moment is None:
                    raise RuntimeError("current fleet phase was not returned")
                frame_index = fleet_moment.frame_index
                frame_fraction = fleet_moment.frame_fraction
            else:
                frame_index = args.frame if args.frame is not None else 0
                frame_fraction = args.fraction if args.fraction is not None else 0.0
            observation = load_observation(
                args.project_root,
                frame_index,
                frame_fraction,
            )
            agent_run = propose_policy(observation, args.project_root, args.model)
            decision = validate_policy(
                observation,
                agent_run.proposal,
                agent_run.report,
            )
        if args.live:
            recovery_path = persist_live_decision(args.project_root, decision)
            applied = apply_decision(decision)
            print(
                f"APPLIED Watershed AI decision {decision.decision_id} to "
                f"{len(applied)} screens"
            )
            if args.decision is not None:
                original = (
                    f"; original generation estimated ${decision.model_run.estimated_cost_usd:.6f}"
                    if decision.model_run is not None
                    else ""
                )
                print(f"OPENAI REPLAY cost $0.000000{original}")
            elif decision.model_run is not None:
                report = decision.model_run
                print(
                    f"OPENAI RUN {report.model}: {report.input_tokens} input + "
                    f"{report.output_tokens} output tokens; estimated "
                    f"${report.estimated_cost_usd:.6f}"
                )
        else:
            print(decision.model_dump_json(indent=2))
            if args.decision is not None:
                print("REPLAY — no OpenAI API call; cost $0.000000", file=sys.stderr)
            elif decision.model_run is not None:
                print(
                    f"OPENAI RUN — estimated cost "
                    f"${decision.model_run.estimated_cost_usd:.6f}",
                    file=sys.stderr,
                )
            print("DRY RUN — no Godot packets were sent", file=sys.stderr)
        return 0
    except PartialApplyError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        if recovery_path is not None:
            print(
                "RETRY THE SAME DECISION: "
                f"watercouncil-ai --live --decision {recovery_path}",
                file=sys.stderr,
            )
        return 1
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
