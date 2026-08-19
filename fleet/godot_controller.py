#!/usr/bin/env python3
"""Control the Water Council Godot project on the master and three remote Macs."""

import argparse
import json
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Optional


COMPUTERS = {
    # Change only the `stages` tuples to alter the screen assignment.
    # Stage numbers correspond to scene_1.tscn through scene_7.tscn.
    "11": {
        "ip": "196.168.50.11",
        "user": "francescospagnolo",
        "project": "/Users/francescospagnolo/Documents/watercouncil/code",
        "stages": (7,),
        "local": True,
    },
    "21": {
        "ip": "196.168.50.21",
        "user": "gregniemeyer",
        "project": "/Users/gregniemeyer/Documents/watercouncil/code",
        "stages": (1, 2),
        "local": False,
    },
    "31": {
        "ip": "196.168.50.31",
        "user": "gregniemeyer",
        "project": "/Users/gregniemeyer/Documents/watercouncil/code",
        "stages": (3, 4),
        "local": False,
    },
    "41": {
        "ip": "196.168.50.41",
        "user": "gregniemeyer",
        "project": "/Users/gregniemeyer/Documents/watercouncil/code",
        "stages": (5, 6),
        "local": False,
    },
}
GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
SSH_TIMEOUT_SECONDS = 8
PROCESS_STOP_TIMEOUT_SECONDS = 6.0
FLOW_CONTROL_PORT = 5005
REGIME_TARGET = "*"
REGIME_ACK_PROTOCOL = "ink-flow/1-ack"
REGIME_ACK_ATTEMPTS = 12
REGIME_ACK_WAIT_SECONDS = 0.75
REGIME_STATE_PATH = os.path.expanduser("~/.water_council_regime_state.json")
REGIMES = (
    ("kinship", "Kinship"),
    ("ranch", "Agriculture"),
    ("gold_rush", "Gold Rush"),
    ("water_projects", "Water Projects"),
    ("hydropower", "Hydropower"),
    ("tech", "Tech"),
    ("watershed", "Watershed"),
)
STAGE_SCREEN_IDS = {
    1: "mount_shasta",
    2: "mccloud_pit",
    3: "cottonwood_creek",
    4: "mill_creek",
    5: "feather_river",
    6: "american_river",
    7: "delta",
}


def run_local(command: list[str], timeout: int = SSH_TIMEOUT_SECONDS) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(command, 124, "", "command timed out")


def ssh(computer: dict, remote_command: str) -> subprocess.CompletedProcess:
    return run_local(
        [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", f"ConnectTimeout={SSH_TIMEOUT_SECONDS}",
            f"{computer['user']}@{computer['ip']}",
            remote_command,
        ]
    )


def process_pattern(computer: dict) -> str:
    # The bracket prevents pgrep/pkill from matching their own command line.
    return f"[/]Applications/Godot.app/Contents/MacOS/Godot.*--path {computer['project']}"


def all_godot_process_pattern() -> str:
    # Fleet Macs are dedicated render nodes. A Godot process from another
    # checkout can still own UDP 5005, so clean launch must stop every Godot.
    return "[/]Applications/Godot.app/Contents/MacOS/Godot"


def stop_godot_processes(computer: dict) -> subprocess.CompletedProcess:
    """Stop every Godot process on one fleet Mac and wait for exit."""
    pattern = all_godot_process_pattern()
    if computer["local"]:
        terminate = run_local(["pkill", "-TERM", "-f", pattern])
        if terminate.returncode not in {0, 1}:
            return terminate
        deadline = time.monotonic() + PROCESS_STOP_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            status = run_local(["pgrep", "-f", pattern])
            if status.returncode == 1:
                return subprocess.CompletedProcess(status.args, 0, "", "")
            if status.returncode not in {0, 1}:
                return status
            time.sleep(0.1)
        force = run_local(["pkill", "-KILL", "-f", pattern])
        if force.returncode not in {0, 1}:
            return force
        force_deadline = time.monotonic() + 1.0
        while time.monotonic() < force_deadline:
            status = run_local(["pgrep", "-f", pattern])
            if status.returncode == 1:
                return subprocess.CompletedProcess(status.args, 0, "", "")
            if status.returncode not in {0, 1}:
                return status
            time.sleep(0.05)
        return subprocess.CompletedProcess(
            status.args,
            14,
            status.stdout,
            "Godot process did not exit after TERM and KILL",
        )

    poll_count = max(int(PROCESS_STOP_TIMEOUT_SECONDS * 10), 1)
    polls = " ".join(str(index) for index in range(poll_count))
    remote_command = (
        f"pkill -TERM -f {shlex.quote(pattern)}; _stop_status=$?; "
        "if test $_stop_status -ne 0 && test $_stop_status -ne 1; then "
        "exit $_stop_status; fi; "
        f"for _poll in {polls}; do "
        f"if ! pgrep -f {shlex.quote(pattern)} >/dev/null; then exit 0; fi; "
        "sleep 0.1; done; "
        f"pkill -KILL -f {shlex.quote(pattern)}; _kill_status=$?; "
        "if test $_kill_status -ne 0 && test $_kill_status -ne 1; then "
        "exit $_kill_status; fi; "
        f"if pgrep -f {shlex.quote(pattern)} >/dev/null; then "
        "echo 'Godot process did not exit after TERM and KILL'; exit 14; fi"
    )
    return ssh(computer, remote_command)


def perform(target: str, action: str) -> tuple[str, bool, str]:
    computer = COMPUTERS[target]
    ip_address = computer["ip"]
    project_dir = computer["project"]
    log_file = f"{project_dir}/godot-remote.log"

    if action == "ping":
        if computer["local"]:
            return ip_address, True, "local master"
        result = run_local(["ping", "-c", "1", ip_address], timeout=4)
        return ip_address, result.returncode == 0, "reachable" if result.returncode == 0 else "unreachable"

    if action == "check":
        required_files = [
            "project.godot",
            "startup_selector.gd",
            "startup_selector.tscn",
            "dual_stage_host.gd",
            "dual_stage_host.tscn",
            "regime_feature_profiles.txt",
            "flow/flow_control_bus.gd",
            "flow/model_regimes.gd",
            "flow/model_timeline.gd",
            "flow/data/regimes/kinship.txt",
            "flow/data/regimes/ranch.txt",
            "flow/data/regimes/gold_rush.txt",
            "flow/data/regimes/water_projects.txt",
            "flow/data/regimes/hydropower.txt",
            "flow/data/regimes/tech.txt",
            "flow/data/water_pipeline/water_temperature_kwk_freeport_720.txt",
            *(f"scene_{stage}.tscn" for stage in computer["stages"]),
        ]
        if computer["local"]:
            missing = []
            if not os.access(GODOT_BIN, os.X_OK):
                missing.append(f"Godot executable not found: {GODOT_BIN}")
            if not os.path.isdir(project_dir):
                missing.append(f"Project directory not found: {project_dir}")
            else:
                for relative_path in required_files:
                    if not os.path.isfile(f"{project_dir}/{relative_path}"):
                        missing.append(f"Required project file not found: {relative_path}")
            return ip_address, not missing, "; ".join(missing) or "Godot and project found"
        command = (
            f"if test ! -x {shlex.quote(GODOT_BIN)}; then "
            f"echo {shlex.quote('Godot executable not found: ' + GODOT_BIN)}; exit 10; fi; "
            f"if test ! -d {shlex.quote(project_dir)}; then "
            f"echo {shlex.quote('Project directory not found: ' + project_dir)}; exit 11; fi; "
        )
        for relative_path in required_files:
            full_path = f"{project_dir}/{relative_path}"
            command += (
                f"if test ! -f {shlex.quote(full_path)}; then "
                f"echo {shlex.quote('Required project file not found: ' + relative_path)}; "
                f"exit 12; fi; "
            )
        command += (
            f"if ! grep -q -- {shlex.quote('--stages=')} "
            f"{shlex.quote(project_dir + '/startup_selector.gd')}; then "
            f"echo {shlex.quote('startup_selector.gd needs the fleet-launch update')}; exit 13; fi"
        )
        result = ssh(computer, command)
        message = "Godot and project found" if result.returncode == 0 else error_message(result)
        return ip_address, result.returncode == 0, message

    if action == "status":
        status_command = ["pgrep", "-fal", process_pattern(computer)]
        result = (
            run_local(status_command)
            if computer["local"]
            else ssh(computer, f"pgrep -fal {shlex.quote(process_pattern(computer))}")
        )
        if result.returncode == 0:
            return ip_address, True, f"running: {result.stdout.strip()}"
        if result.returncode == 1:
            return ip_address, True, "stopped"
        return ip_address, False, error_message(result)

    if action == "stop":
        result = stop_godot_processes(computer)
        return ip_address, result.returncode == 0, "stopped" if result.returncode == 0 else error_message(result)

    if action in {"start", "editor"}:
        # A clean launch is mandatory: duplicate project processes compete for UDP
        # 5005, so the controller can update a hidden copy while the visible screens
        # remain unchanged. Stop and reap every matching process before launching.
        stop_result = stop_godot_processes(computer)
        if stop_result.returncode != 0:
            return ip_address, False, error_message(stop_result)
        editor_flag = " --editor" if action == "editor" else ""
        stage_argument = "--stages=" + ",".join(str(stage) for stage in computer["stages"])
        if computer["local"]:
            if not os.access(GODOT_BIN, os.X_OK):
                return ip_address, False, f"Godot executable not found: {GODOT_BIN}"
            if not os.path.isfile(f"{project_dir}/project.godot"):
                return ip_address, False, f"project.godot not found in: {project_dir}"
            log_handle = open(log_file, "w", encoding="utf-8")
            command = [GODOT_BIN, "--path", project_dir]
            if action == "editor":
                command.append("--editor")
            else:
                command.extend(["--", stage_argument])
            subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            log_handle.close()
            return ip_address, True, f"launch requested for stages {computer['stages']}"
        command = (
            f"test -x {shlex.quote(GODOT_BIN)} && "
            f"test -f {shlex.quote(project_dir + '/project.godot')} && "
            f"nohup {shlex.quote(GODOT_BIN)} --path {shlex.quote(project_dir)}"
            f"{editor_flag}"
            + ("" if action == "editor" else f" -- {shlex.quote(stage_argument)}")
            + f" > {shlex.quote(log_file)} 2>&1 < /dev/null &"
        )
        result = ssh(computer, command)
        message = (
            f"launch requested for stages {computer['stages']}"
            if result.returncode == 0
            else error_message(result)
        )
        return ip_address, result.returncode == 0, message

    raise ValueError(f"Unknown action: {action}")


def error_message(result: subprocess.CompletedProcess) -> str:
    return (result.stderr or result.stdout or f"exit code {result.returncode}").strip()


def regime_destination_specs(target_names=None) -> list[tuple[str, list[str]]]:
    """Return UDP destinations and the exact screens each process must host."""
    selected_names = list(COMPUTERS) if target_names is None else list(target_names)
    specifications: list[tuple[str, list[str]]] = []
    seen_destinations: set[str] = set()
    for target_name in selected_names:
        if target_name not in COMPUTERS:
            raise ValueError(f"unknown fleet target: {target_name}")
        computer = COMPUTERS[target_name]
        destination = "127.0.0.1" if computer["local"] else computer["ip"]
        if destination in seen_destinations:
            raise ValueError(f"duplicate regime destination: {destination}")
        expected_screens: list[str] = []
        for stage in computer["stages"]:
            if stage not in STAGE_SCREEN_IDS:
                raise ValueError(f"unknown configured stage number: {stage}")
            expected_screens.append(STAGE_SCREEN_IDS[stage])
        specifications.append((destination, sorted(expected_screens)))
        seen_destinations.add(destination)
    if not specifications:
        raise ValueError("no fleet computers are configured")
    return specifications


def regime_destinations() -> list[str]:
    return [destination for destination, _screens in regime_destination_specs()]


def regime_indices(regime_ids: list[str]) -> list[int]:
    if len(set(regime_ids)) != len(regime_ids):
        raise ValueError("duplicate --regime values are not allowed")
    known_ids = [regime_id for regime_id, _display_name in REGIMES]
    unknown = [regime_id for regime_id in regime_ids if regime_id not in known_ids]
    if unknown:
        raise ValueError(f"unknown regime(s): {', '.join(unknown)}")
    return sorted(known_ids.index(regime_id) for regime_id in regime_ids)


def cli_boolean(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise argparse.ArgumentTypeError("expected TRUE or FALSE")


def send_fleet_regimes(
    regime_ids: list[str],
    command: str,
    target_names=None,
    geometry_visible: Optional[bool] = None,
) -> list[tuple[str, int, int]]:
    indices = regime_indices(regime_ids)
    request_id = uuid.uuid4().hex
    changes = {"regimes.active_indices": indices}
    if geometry_visible is not None:
        changes["debug.geometry_visible"] = geometry_visible
    payload = {
        "protocol": "ink-flow/1",
        "target": REGIME_TARGET,
        "changes": changes,
        "geometry_ops": [],
        "actions": [],
        "metadata": {
            "source": "governator",
            "command": command,
            "request_id": request_id,
        },
    }
    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    destination_specs = regime_destination_specs(target_names)
    destinations = [destination for destination, _screens in destination_specs]
    expected_screens_by_destination = dict(destination_specs)
    pending = set(destinations)
    acknowledgements: dict[str, int] = {}
    last_seen_screens: dict[str, list[str]] = {}
    last_seen_geometry: dict[str, dict[str, bool]] = {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp_socket:
        udp_socket.bind(("", 0))
        for _attempt in range(REGIME_ACK_ATTEMPTS):
            for destination in list(pending):
                sent = udp_socket.sendto(encoded, (destination, FLOW_CONTROL_PORT))
                if sent != len(encoded):
                    raise OSError(
                        f"sent only {sent} of {len(encoded)} UDP bytes to {destination}"
                    )
            deadline = time.monotonic() + REGIME_ACK_WAIT_SECONDS
            while pending and time.monotonic() < deadline:
                udp_socket.settimeout(max(deadline - time.monotonic(), 0.01))
                try:
                    raw_ack, sender = udp_socket.recvfrom(4096)
                except socket.timeout:
                    break
                try:
                    acknowledgement = json.loads(raw_ack.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if not isinstance(acknowledgement, dict):
                    continue
                if acknowledgement.get("protocol") != REGIME_ACK_PROTOCOL:
                    continue
                if acknowledgement.get("request_id") != request_id:
                    continue
                sender_ip = sender[0]
                if sender_ip not in pending:
                    continue
                if acknowledgement.get("accepted") is not True:
                    raise OSError(f"Godot at {sender_ip} rejected the regime state")
                active_indices = acknowledgement.get("regime_active_indices")
                if active_indices != indices:
                    raise OSError(
                        f"Godot at {sender_ip} acknowledged active indices "
                        f"{active_indices!r}, expected {indices!r}"
                    )
                received_screens = sorted(
                    str(screen_id)
                    for screen_id in acknowledgement.get("recipient_screen_ids", [])
                )
                last_seen_screens[sender_ip] = received_screens
                raw_geometry = acknowledgement.get(
                    "recipient_debug_geometry_visible", {}
                )
                received_geometry = (
                    {
                        str(screen_id): visible
                        for screen_id, visible in raw_geometry.items()
                        if isinstance(visible, bool)
                    }
                    if isinstance(raw_geometry, dict)
                    else {}
                )
                last_seen_geometry[sender_ip] = received_geometry
                recipient_count = int(acknowledgement.get("recipient_count", 0))
                expected_geometry = (
                    {
                        screen_id: geometry_visible
                        for screen_id in expected_screens_by_destination[sender_ip]
                    }
                    if geometry_visible is not None
                    else None
                )
                if (
                    received_screens != expected_screens_by_destination[sender_ip]
                    or recipient_count != len(expected_screens_by_destination[sender_ip])
                    or (
                        expected_geometry is not None
                        and received_geometry != expected_geometry
                    )
                ):
                    # The process may still be loading its assigned stages. Leave
                    # it pending so the absolute packet is retried until ready.
                    continue
                acknowledgements[sender_ip] = recipient_count
                pending.remove(sender_ip)
            if not pending:
                break
    if pending:
        readiness = "; ".join(
            f"{destination} expected {expected_screens_by_destination[destination]!r}, "
            f"saw {last_seen_screens.get(destination, [])!r}"
            + (
                f", expected geo={geometry_visible}, "
                f"saw {last_seen_geometry.get(destination, {})!r}"
                if geometry_visible is not None
                else ""
            )
            for destination in sorted(pending)
        )
        raise OSError(
            "no ready control acknowledgement: "
            + readiness
            + "; verify exactly one updated Godot owns UDP 5005 per fleet Mac"
        )
    return [
        (destination, len(encoded), acknowledgements[destination])
        for destination in destinations
    ]


def format_regime_send(results: list[tuple[str, int, int]]) -> str:
    return ", ".join(
        f"{destination}:{FLOW_CONTROL_PORT} "
        f"({sent} bytes, {recipient_count} stage(s))"
        for destination, sent, recipient_count in results
    )


def load_controller_state() -> tuple[set[str], Optional[bool]]:
    if not os.path.isfile(REGIME_STATE_PATH):
        return set(), None
    try:
        with open(REGIME_STATE_PATH, "r", encoding="utf-8") as state_file:
            document = json.load(state_file)
        if not isinstance(document, dict):
            raise ValueError("controller state must be a JSON object")
        regime_ids = document.get("active_regime_ids", [])
        if not isinstance(regime_ids, list) or not all(
            isinstance(regime_id, str) for regime_id in regime_ids
        ):
            raise ValueError("active_regime_ids must be a string list")
        regime_indices(regime_ids)
        geometry_visible = document.get("debug_geometry_visible")
        if geometry_visible is not None and not isinstance(geometry_visible, bool):
            raise ValueError("debug_geometry_visible must be true or false")
        return set(regime_ids), geometry_visible
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise ValueError(
            f"invalid controller state {REGIME_STATE_PATH}: {error}"
        ) from error


def load_controller_regime_state() -> set[str]:
    regime_ids, _geometry_visible = load_controller_state()
    return regime_ids


def save_controller_state(
    regime_ids: list[str],
    geometry_visible: Optional[bool],
) -> None:
    regime_indices(regime_ids)
    requested_ids = set(regime_ids)
    ordered_ids = [
        regime_id
        for regime_id, _display_name in REGIMES
        if regime_id in requested_ids
    ]
    state_directory = os.path.dirname(REGIME_STATE_PATH) or "."
    os.makedirs(state_directory, exist_ok=True)
    file_descriptor, temporary_path = tempfile.mkstemp(
        prefix=".water_council_regime_state.",
        suffix=".tmp",
        dir=state_directory,
        text=True,
    )
    try:
        document = {"active_regime_ids": ordered_ids}
        if geometry_visible is not None:
            document["debug_geometry_visible"] = geometry_visible
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as state_file:
            json.dump(
                document,
                state_file,
                sort_keys=True,
                separators=(",", ":"),
            )
            state_file.write("\n")
        os.replace(temporary_path, REGIME_STATE_PATH)
    except BaseException:
        try:
            os.unlink(temporary_path)
        except OSError:
            pass
        raise


def save_controller_regime_state(regime_ids: list[str]) -> None:
    _active_ids, geometry_visible = load_controller_state()
    save_controller_state(regime_ids, geometry_visible)


def print_regime_catalog() -> None:
    for index, (regime_id, display_name) in enumerate(REGIMES, start=1):
        print(f"{index}: {regime_id:<16} {display_name}")


def run_regime_console() -> None:
    if not sys.stdin.isatty():
        raise ValueError("regime-console requires an interactive terminal")
    import termios
    import tty

    active_ids, geometry_visible = load_controller_state()
    file_descriptor = sys.stdin.fileno()
    original_terminal = termios.tcgetattr(file_descriptor)
    print("Regime console: 1-7 toggle, c clears, q or Esc quits.")
    print_regime_catalog()
    ordered_start = [
        regime_id for regime_id, _name in REGIMES if regime_id in active_ids
    ]
    sends = send_fleet_regimes(
        ordered_start,
        "regime-console-sync",
        geometry_visible=geometry_visible,
    )
    initial_state = ", ".join(ordered_start) if ordered_start else "none"
    print(f"APPLIED to {format_regime_send(sends)}: active={initial_state}")
    try:
        tty.setcbreak(file_descriptor)
        while True:
            character = os.read(file_descriptor, 1).decode("utf-8", errors="ignore")
            if not character:
                print("\nRegime console input closed.")
                return
            if character in {"q", "Q", "\x1b"}:
                print("\nRegime console stopped.")
                return
            if character in {"c", "C"}:
                active_ids.clear()
                sends = send_fleet_regimes(
                    [],
                    "regime-clear",
                    geometry_visible=geometry_visible,
                )
            elif character and character in "1234567":
                regime_id = REGIMES[int(character) - 1][0]
                if regime_id in active_ids:
                    active_ids.remove(regime_id)
                else:
                    active_ids.add(regime_id)
                sends = send_fleet_regimes(
                    list(active_ids),
                    "regime-console",
                    geometry_visible=geometry_visible,
                )
            else:
                continue
            ordered = [regime_id for regime_id, _name in REGIMES if regime_id in active_ids]
            save_controller_state(ordered, geometry_visible)
            state = ", ".join(ordered) if ordered else "none"
            print(f"\rAPPLIED to {format_regime_send(sends)}: active={state}          ")
    finally:
        termios.tcsetattr(file_descriptor, termios.TCSADRAIN, original_terminal)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=[
            "ping",
            "check",
            "status",
            "start",
            "editor",
            "stop",
            "restart",
            "list",
            "set",
            "regime-clear",
            "regime-console",
        ],
    )
    parser.add_argument(
        "targets",
        nargs="*",
        default=None,
        metavar="TARGET",
        help="last IP octets to control (default: all)",
    )
    parser.add_argument(
        "--regime",
        action="append",
        default=[],
        choices=[regime_id for regime_id, _display_name in REGIMES],
        help="regime ID for set; repeat to activate several regimes",
    )
    parser.add_argument(
        "--geo",
        type=cli_boolean,
        default=None,
        metavar="TRUE/FALSE",
        help="absolute obstacle/debug geometry visibility for set",
    )
    args = parser.parse_args()

    regime_actions = {"list", "set", "regime-clear", "regime-console"}
    if args.action in regime_actions:
        if args.targets:
            parser.error(f"{args.action} does not accept machine targets")
        if args.action == "list":
            if args.regime:
                parser.error("list does not accept --regime")
            if args.geo is not None:
                parser.error("list does not accept --geo")
            print_regime_catalog()
            return
        if args.action == "set" and not args.regime and args.geo is None:
            parser.error("set requires at least one --regime or --geo TRUE/FALSE")
        if args.action != "set" and args.regime:
            parser.error(f"{args.action} does not accept --regime")
        if args.action != "set" and args.geo is not None:
            parser.error(f"{args.action} does not accept --geo")
        try:
            if args.action == "regime-console":
                run_regime_console()
                return
            saved_regime_ids, saved_geometry_visible = load_controller_state()
            if args.action == "set":
                regime_ids = (
                    args.regime
                    if args.regime
                    else [
                        regime_id
                        for regime_id, _name in REGIMES
                        if regime_id in saved_regime_ids
                    ]
                )
                geometry_visible = (
                    args.geo if args.geo is not None else saved_geometry_visible
                )
                command = "set"
            else:
                regime_ids = []
                geometry_visible = saved_geometry_visible
                command = "regime-clear"
            sends = send_fleet_regimes(
                regime_ids,
                command,
                geometry_visible=geometry_visible,
            )
            save_controller_state(regime_ids, geometry_visible)
            active = ", ".join(regime_ids) if regime_ids else "none"
            geometry_state = (
                str(geometry_visible).lower()
                if geometry_visible is not None
                else "unchanged"
            )
            print(
                f"APPLIED  {format_regime_send(sends)}; "
                f"active={active}; geo={geometry_state}"
            )
            return
        except (OSError, ValueError) as error:
            parser.error(str(error))

    if args.regime:
        parser.error(f"{args.action} does not accept --regime")
    if args.geo is not None:
        parser.error(f"{args.action} does not accept --geo")

    selected_targets = args.targets or list(COMPUTERS)
    invalid_targets = [name for name in selected_targets if name not in COMPUTERS]
    if invalid_targets:
        parser.error(
            f"unknown target(s): {', '.join(invalid_targets)}; choose from: "
            f"{', '.join(COMPUTERS)}"
        )
    targets = selected_targets

    if args.action == "restart":
        with ThreadPoolExecutor(max_workers=len(targets)) as pool:
            stop_results = list(pool.map(lambda target: perform(target, "stop"), targets))
        failed_ips = {ip for ip, ok, _ in stop_results if not ok}
        restart_targets = [target for target in targets if COMPUTERS[target]["ip"] not in failed_ips]
        with ThreadPoolExecutor(max_workers=len(targets)) as pool:
            start_results = list(pool.map(lambda target: perform(target, "start"), restart_targets))
        results = [result for result in stop_results if not result[1]] + start_results
    else:
        with ThreadPoolExecutor(max_workers=len(targets)) as pool:
            results = list(pool.map(lambda target: perform(target, args.action), targets))

    failed = False
    for ip_address, ok, message in results:
        print(f"{'OK' if ok else 'ERROR':5} {ip_address}: {message}")
        failed = failed or not ok
    if args.action in {"start", "restart"}:
        successful_ips = {ip_address for ip_address, ok, _message in results if ok}
        successful_targets = [
            target
            for target in targets
            if COMPUTERS[target]["ip"] in successful_ips
        ]
        if successful_targets:
            try:
                active_ids, geometry_visible = load_controller_state()
                ordered_active = [
                    regime_id
                    for regime_id, _name in REGIMES
                    if regime_id in active_ids
                ]
                sends = send_fleet_regimes(
                    ordered_active,
                    "startup-sync",
                    successful_targets,
                    geometry_visible=geometry_visible,
                )
                active = ", ".join(ordered_active) if ordered_active else "none"
                geometry_state = (
                    str(geometry_visible).lower()
                    if geometry_visible is not None
                    else "unchanged"
                )
                print(
                    f"APPLIED  {format_regime_send(sends)}; "
                    f"startup active={active}; geo={geometry_state}"
                )
            except (OSError, ValueError) as error:
                print(f"ERROR startup regime verification: {error}")
                failed = True
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
