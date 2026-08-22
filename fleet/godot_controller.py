#!/usr/bin/env python3
"""Control and deploy the Water Council Godot project across the four-Mac fleet."""

import argparse
import importlib.util
import json
import os
import posixpath
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional


COMPUTERS = {
    # Change only the stages tuples to alter the screen assignment.
    # Stage numbers correspond to scene_1.tscn through scene_7.tscn.
    "11": {
        "ip": "196.168.50.11",
        "user": "francescospagnolo",
        "project": "/Users/francescospagnolo/Documents/watercouncil/code",
        "stages": (7,),
        "local": False,
        "dedicated": True,
    },
    "21": {
        "ip": "196.168.50.21",
        "user": "gregniemeyer",
        "project": "/Users/gregniemeyer/Documents/watercouncil/code",
        "stages": (1, 2),
        "local": False,
        "dedicated": True,
    },
    "31": {
        "ip": "196.168.50.31",
        "user": "gregniemeyer",
        "project": "/Users/gregniemeyer/Documents/watercouncil/code",
        "stages": (3, 4),
        "local": False,
        "dedicated": True,
    },
    "41": {
        "ip": "196.168.50.41",
        "user": "gregniemeyer",
        "project": "/Users/gregniemeyer/Documents/watercouncil/code",
        "stages": (5, 6),
        "local": False,
        "dedicated": True,
    },
}
OPERATORS = {
    "196.168.50.11": {"name": "governator", "local_target": "11"},
    "196.168.50.51": {"name": "studio", "local_target": None},
}
GODOT_BIN = "/Applications/Godot.app/Contents/MacOS/Godot"
CAFFEINATE_BIN = "/usr/bin/caffeinate"
CAFFEINATE_FLAGS = ("-d", "-i", "-s")
SSH_TIMEOUT_SECONDS = 15
DEPLOY_TIMEOUT_SECONDS = 300
PROCESS_STOP_TIMEOUT_SECONDS = 6.0
SSH_IDENTITY_PATH = os.path.expanduser(
    os.environ.get("WATER_COUNCIL_SSH_IDENTITY", "~/.ssh/water_council_fleet_ed25519")
)
SSH_OPTIONS = (
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", f"ConnectTimeout={SSH_TIMEOUT_SECONDS}",
    "-o", "ConnectionAttempts=1",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=1",
    "-o", "IdentitiesOnly=yes",
    "-i", SSH_IDENTITY_PATH,
)
FLOW_CONTROL_PORT = 5005
REGIME_TARGET = "*"
REGIME_ACK_PROTOCOL = "ink-flow/1-ack"
REGIME_ACK_ATTEMPTS = 24
REGIME_ACK_WAIT_SECONDS = 0.75
REGIME_STATE_PATH = "/Users/francescospagnolo/.water_council_regime_state.json"
GLOBAL_CLASS_CACHE_RELATIVE_PATH = ".godot/global_script_class_cache.cfg"
FONT_CACHE_RELATIVE_PATH = (
    ".godot/imported/"
    "BarlowCondensed-Medium.ttf-55fe546e141a6200e28c93d92a23a9e8.fontdata"
)
REQUIRED_GLOBAL_CLASSES = (
    "FlowMath",
    "FlowReservoir",
    "GPUFlowInteractionPolygon",
    "GPUFlowStage2D",
    "GPULeaf2D",
    "GPUSalmon2D",
)
PROJECT_SOURCE_DIR = Path(__file__).resolve().parents[1] / "godot_experiments"
FLEET_SOURCE_DIR = Path(__file__).resolve().parent
TELEMETRY_DIR = Path(__file__).resolve().parents[1] / "telemetry"
CHAIR_SENSOR_MODULE_PATH = TELEMETRY_DIR / "controller.py"
CHAIR_POLL_SECONDS = 0.05
PROJECT_DEPLOY_EXCLUDES = (
    # fleet/ is synchronized and verified independently. Excluding it here
    # lets the project-root --delete remove every other retired file.
    "fleet/",
    # Hardware telemetry is installed and updated independently on .11.
    "telemetry/",
    ".godot/",
    ".DS_Store",
    "godot-remote.log",
    "__pycache__/",
    "*.pyc",
    "*.pyo",
)
FLEET_DEPLOY_EXCLUDES = (
    ".DS_Store",
    "__pycache__/",
    "*.pyc",
    "*.pyo",
)

CURRENT_OPERATOR: Optional[dict] = None
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


def run_local(
    command: list[str],
    timeout: float = SSH_TIMEOUT_SECONDS,
) -> subprocess.CompletedProcess:
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


def ssh(
    computer: dict,
    remote_command: str,
    timeout: float = SSH_TIMEOUT_SECONDS,
) -> subprocess.CompletedProcess:
    return run_local(
        [
            "ssh",
            *SSH_OPTIONS,
            f"{computer['user']}@{computer['ip']}",
            remote_command,
        ],
        timeout=timeout,
    )


def rsync_ssh_transport() -> str:
    return " ".join(shlex.quote(part) for part in ("ssh", *SSH_OPTIONS))


def configure_operator(ifconfig_output: Optional[str] = None) -> dict:
    """Detect the only two supported operator modes and set target locality."""
    global CURRENT_OPERATOR
    if ifconfig_output is None:
        result = run_local(["/sbin/ifconfig"], timeout=4)
        if result.returncode != 0:
            raise ValueError(f"could not inspect local network addresses: {error_message(result)}")
        ifconfig_output = result.stdout
    addresses = set(
        re.findall(
            r"(?m)^\s*inet\s+(\d+\.\d+\.\d+\.\d+)\b",
            ifconfig_output,
        )
    )
    matches = [(ip_address, OPERATORS[ip_address]) for ip_address in addresses if ip_address in OPERATORS]
    if len(matches) != 1:
        visible = ", ".join(sorted(addresses)) or "none"
        raise ValueError(
            "fleet controller requires exactly one operator address "
            "(196.168.50.11 or 196.168.50.51); found: "
            + visible
        )
    operator_ip, configured = matches[0]
    profile = dict(configured)
    profile["ip"] = operator_ip
    local_target = profile["local_target"]
    for target_name, computer in COMPUTERS.items():
        computer["local"] = target_name == local_target
    CURRENT_OPERATOR = profile
    return profile


def current_operator() -> dict:
    if CURRENT_OPERATOR is None:
        raise ValueError("operator mode has not been configured")
    return CURRENT_OPERATOR


def all_godot_process_pattern() -> str:
    # Godot is launched as a caffeinate child. Anchor the executable so pgrep
    # sees the child only, never the caffeinate parent whose arguments also
    # contain GODOT_BIN.
    return "^/Applications/Godot[.]app/Contents/MacOS/Godot( |$)"


def godot_launch_command(
    project_dir: str,
    stage_argument: Optional[str] = None,
    editor: bool = False,
) -> list[str]:
    """Build a lifetime-scoped macOS sleep guard around one Godot process."""
    command = [
        CAFFEINATE_BIN,
        *CAFFEINATE_FLAGS,
        GODOT_BIN,
        "--path",
        project_dir,
    ]
    if editor:
        command.append("--editor")
    elif stage_argument is not None:
        command.extend(["--", stage_argument])
    return command


def stop_godot_processes(computer: dict) -> subprocess.CompletedProcess:
    """Stop every Godot process on one explicitly dedicated fleet Mac."""
    if computer.get("dedicated") is not True:
        return subprocess.CompletedProcess(
            ["stop-godot"],
            15,
            "",
            "refusing broad Godot cleanup on a non-dedicated computer",
        )
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
    return ssh(
        computer,
        remote_command,
        timeout=SSH_TIMEOUT_SECONDS + PROCESS_STOP_TIMEOUT_SECONDS + 2,
    )


def required_project_files(computer: dict) -> list[str]:
    return [
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
        "flow/data/water_pipeline/water_temperature_all_rivers_720.txt",
        *(f"scene_{stage}.tscn" for stage in computer["stages"]),
    ]


def cache_validation_command(project_dir: str) -> str:
    class_cache = posixpath.join(project_dir, GLOBAL_CLASS_CACHE_RELATIVE_PATH)
    font_cache = posixpath.join(project_dir, FONT_CACHE_RELATIVE_PATH)
    command = (
        f"test -s {shlex.quote(class_cache)} || "
        f"{{ echo {shlex.quote('Godot global script-class cache is missing')}; exit 14; }}; "
        f"test -s {shlex.quote(font_cache)} || "
        f"{{ echo {shlex.quote('Godot Barlow font import cache is missing')}; exit 15; }}; "
    )
    for class_name in REQUIRED_GLOBAL_CLASSES:
        class_marker = f'\"class\": &\"{class_name}\"'
        command += (
            f"grep -Fq -- {shlex.quote(class_marker)} {shlex.quote(class_cache)} || "
            f"{{ echo {shlex.quote('Godot global class is missing: ' + class_name)}; "
            "exit 16; }; "
        )
    return command.rstrip("; ")


def check_computer(computer: dict) -> tuple[bool, str]:
    project_dir = computer["project"]
    required_files = required_project_files(computer)
    if computer["local"]:
        missing = []
        if not os.access(GODOT_BIN, os.X_OK):
            missing.append(f"Godot executable not found: {GODOT_BIN}")
        if not os.access(CAFFEINATE_BIN, os.X_OK):
            missing.append(f"caffeinate executable not found: {CAFFEINATE_BIN}")
        if not os.path.isdir(project_dir):
            missing.append(f"Project directory not found: {project_dir}")
        else:
            for relative_path in required_files:
                if not os.path.isfile(os.path.join(project_dir, relative_path)):
                    missing.append(f"Required project file not found: {relative_path}")
            selector_path = os.path.join(project_dir, "startup_selector.gd")
            if os.path.isfile(selector_path):
                try:
                    with open(selector_path, "r", encoding="utf-8") as selector_file:
                        if "--stages=" not in selector_file.read():
                            missing.append("startup_selector.gd needs the fleet-launch update")
                except OSError as error:
                    missing.append(f"Could not read startup_selector.gd: {error}")
            class_cache = Path(project_dir) / GLOBAL_CLASS_CACHE_RELATIVE_PATH
            if not class_cache.is_file() or class_cache.stat().st_size <= 0:
                missing.append("Godot global script-class cache is missing")
            else:
                try:
                    class_cache_text = class_cache.read_text(encoding="utf-8")
                except OSError as error:
                    missing.append(f"Could not read Godot global class cache: {error}")
                else:
                    for class_name in REQUIRED_GLOBAL_CLASSES:
                        if f'\"class\": &\"{class_name}\"' not in class_cache_text:
                            missing.append(f"Godot global class is missing: {class_name}")
            font_cache = Path(project_dir) / FONT_CACHE_RELATIVE_PATH
            if not font_cache.is_file() or font_cache.stat().st_size <= 0:
                missing.append("Godot Barlow font import cache is missing")
        return (
            not missing,
            "; ".join(missing)
            or "Godot, caffeinate, project, and import cache found",
        )

    command = (
        f"if test ! -x {shlex.quote(GODOT_BIN)}; then "
        f"echo {shlex.quote('Godot executable not found: ' + GODOT_BIN)}; exit 10; fi; "
        f"if test ! -x {shlex.quote(CAFFEINATE_BIN)}; then "
        f"echo {shlex.quote('caffeinate executable not found: ' + CAFFEINATE_BIN)}; exit 17; fi; "
        f"if test ! -d {shlex.quote(project_dir)}; then "
        f"echo {shlex.quote('Project directory not found: ' + project_dir)}; exit 11; fi; "
    )
    for relative_path in required_files:
        full_path = f"{project_dir}/{relative_path}"
        command += (
            f"if test ! -f {shlex.quote(full_path)}; then "
            f"echo {shlex.quote('Required project file not found: ' + relative_path)}; "
            "exit 12; fi; "
        )
    command += (
        f"if ! grep -q -- {shlex.quote('--stages=')} "
        f"{shlex.quote(project_dir + '/startup_selector.gd')}; then "
        f"echo {shlex.quote('startup_selector.gd needs the fleet-launch update')}; exit 13; fi; "
        + cache_validation_command(project_dir)
    )
    result = ssh(computer, command)
    return (
        result.returncode == 0,
        "Godot, caffeinate, project, and import cache found"
        if result.returncode == 0
        else error_message(result),
    )


def all_godot_status(computer: dict) -> tuple[bool, str]:
    pattern = all_godot_process_pattern()
    result = (
        run_local(["pgrep", "-fal", pattern])
        if computer["local"]
        else ssh(computer, f"pgrep -fal {shlex.quote(pattern)}")
    )
    if result.returncode == 1:
        return True, "stopped"
    if result.returncode != 0:
        return False, error_message(result)
    processes = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    stage_argument = "--stages=" + ",".join(str(stage) for stage in computer["stages"])
    expected_command = [
        GODOT_BIN,
        "--path",
        computer["project"],
        "--",
        stage_argument,
    ]
    parsed_commands = []
    for process in processes:
        try:
            command = shlex.split(process)
        except ValueError:
            command = []
        if command and command[0].isdigit():
            command = command[1:]
        parsed_commands.append(command)
    if len(processes) == 1 and parsed_commands == [expected_command]:
        return True, f"running: {processes[0]}"
    detail = " | ".join(processes) or "(no process details)"
    return (
        False,
        "unexpected Godot process layout "
        f"(expected exactly: {' '.join(expected_command)}): {detail}",
    )


def perform(target: str, action: str) -> tuple[str, bool, str]:
    computer = COMPUTERS[target]
    ip_address = computer["ip"]
    project_dir = computer["project"]
    log_file = f"{project_dir}/godot-remote.log"

    if action == "ping":
        if computer["local"]:
            return ip_address, True, "local operator"
        result = run_local(["ping", "-c", "1", ip_address], timeout=4)
        return (
            ip_address,
            result.returncode == 0,
            "reachable" if result.returncode == 0 else "unreachable",
        )

    if action == "check":
        ok, message = check_computer(computer)
        return ip_address, ok, message

    if action == "status":
        ok, message = all_godot_status(computer)
        return ip_address, ok, message

    if action == "stop":
        result = stop_godot_processes(computer)
        return (
            ip_address,
            result.returncode == 0,
            "stopped" if result.returncode == 0 else error_message(result),
        )

    if action in {"start", "editor"}:
        # Never stop a working display until the replacement launch is known to
        # have an executable and a complete project tree.
        ready, readiness_message = check_computer(computer)
        if not ready:
            return ip_address, False, f"preflight failed; left running processes untouched: {readiness_message}"
        stop_result = stop_godot_processes(computer)
        if stop_result.returncode != 0:
            return ip_address, False, error_message(stop_result)
        stage_argument = "--stages=" + ",".join(str(stage) for stage in computer["stages"])
        if computer["local"]:
            try:
                log_handle = open(log_file, "w", encoding="utf-8")
            except OSError as error:
                return ip_address, False, f"could not open launch log: {error}"
            command = godot_launch_command(
                project_dir,
                stage_argument=stage_argument,
                editor=action == "editor",
            )
            try:
                subprocess.Popen(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=log_handle,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            except OSError as error:
                return ip_address, False, f"launch failed: {error}"
            finally:
                log_handle.close()
            return ip_address, True, f"launch requested for stages {computer['stages']}"

        launch_command = godot_launch_command(
            project_dir,
            stage_argument=stage_argument,
            editor=action == "editor",
        )
        command = (
            f"nohup {shlex.join(launch_command)} "
            f"> {shlex.quote(log_file)} 2>&1 < /dev/null &"
        )
        result = ssh(computer, command)
        return (
            ip_address,
            result.returncode == 0,
            (
                f"launch requested for stages {computer['stages']}"
                if result.returncode == 0
                else error_message(result)
            ),
        )

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
    source_name = CURRENT_OPERATOR["name"] if CURRENT_OPERATOR else "fleet-controller"
    payload = {
        "protocol": "ink-flow/1",
        "target": REGIME_TARGET,
        "changes": changes,
        "geometry_ops": [],
        "actions": [],
        "metadata": {
            "source": source_name,
            "command": command,
            "request_id": request_id,
        },
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
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
                    raise OSError(f"sent only {sent} of {len(encoded)} UDP bytes to {destination}")
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
                raw_geometry = acknowledgement.get("recipient_debug_geometry_visible", {})
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
                    or (expected_geometry is not None and received_geometry != expected_geometry)
                ):
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
        f"{destination}:{FLOW_CONTROL_PORT} ({sent} bytes, {recipient_count} stage(s))"
        for destination, sent, recipient_count in results
    )


def _read_controller_state_text() -> Optional[str]:
    authority = COMPUTERS["11"]
    if authority["local"]:
        if not os.path.isfile(REGIME_STATE_PATH):
            return None
        with open(REGIME_STATE_PATH, "r", encoding="utf-8") as state_file:
            return state_file.read()
    command = (
        f"if test -f {shlex.quote(REGIME_STATE_PATH)}; then "
        f"cat {shlex.quote(REGIME_STATE_PATH)}; else exit 3; fi"
    )
    result = ssh(authority, command)
    if result.returncode == 3:
        return None
    if result.returncode != 0:
        raise OSError(f"could not read authoritative state on {authority['ip']}: {error_message(result)}")
    return result.stdout


def _state_document(
    regime_ids: list[str],
    geometry_visible: Optional[bool],
) -> dict:
    regime_indices(regime_ids)
    requested_ids = set(regime_ids)
    ordered_ids = [
        regime_id
        for regime_id, _display_name in REGIMES
        if regime_id in requested_ids
    ]
    document = {"active_regime_ids": ordered_ids}
    if geometry_visible is not None:
        document["debug_geometry_visible"] = geometry_visible
    return document


def load_controller_state(
    require_exists: bool = False,
) -> tuple[set[str], Optional[bool]]:
    try:
        raw_document = _read_controller_state_text()
        if raw_document is None:
            if require_exists:
                raise ValueError(
                    "authoritative controller state does not exist on 196.168.50.11"
                )
            return set(), None
        document = json.loads(raw_document)
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
        raise ValueError(f"invalid controller state {REGIME_STATE_PATH}: {error}") from error


def load_controller_regime_state() -> set[str]:
    regime_ids, _geometry_visible = load_controller_state()
    return regime_ids


def save_controller_state(
    regime_ids: list[str],
    geometry_visible: Optional[bool],
) -> None:
    document = _state_document(regime_ids, geometry_visible)
    encoded = json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"
    authority = COMPUTERS["11"]
    if authority["local"]:
        state_directory = os.path.dirname(REGIME_STATE_PATH) or "."
        os.makedirs(state_directory, exist_ok=True)
        file_descriptor, temporary_path = tempfile.mkstemp(
            prefix=".water_council_regime_state.",
            suffix=".tmp",
            dir=state_directory,
            text=True,
        )
        try:
            with os.fdopen(file_descriptor, "w", encoding="utf-8") as state_file:
                state_file.write(encoded)
            os.replace(temporary_path, REGIME_STATE_PATH)
        except BaseException:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass
            raise
        return

    temporary_path = f"{REGIME_STATE_PATH}.tmp.{uuid.uuid4().hex}"
    command = (
        "umask 077; "
        f"_state_tmp={shlex.quote(temporary_path)}; "
        "trap 'rm -f \"$_state_tmp\"' EXIT HUP INT TERM; "
        f"printf '%s\\n' {shlex.quote(encoded.rstrip())} > \"$_state_tmp\" && "
        f"mv \"$_state_tmp\" {shlex.quote(REGIME_STATE_PATH)}; "
        "_state_status=$?; trap - EXIT HUP INT TERM; exit $_state_status"
    )
    result = ssh(authority, command)
    if result.returncode != 0:
        raise OSError(f"could not save authoritative state on {authority['ip']}: {error_message(result)}")


def save_controller_regime_state(regime_ids: list[str]) -> None:
    _active_ids, geometry_visible = load_controller_state()
    save_controller_state(regime_ids, geometry_visible)


def print_regime_catalog() -> None:
    for index, (regime_id, display_name) in enumerate(REGIMES, start=1):
        print(f"{index}: {regime_id:<16} {display_name}")


def load_chair_sensor_module(module_path: Path = CHAIR_SENSOR_MODULE_PATH):
    """Load the validated occupancy model without starting its UDP publisher."""
    if not module_path.is_file():
        raise ValueError(
            f"chair telemetry module not found: {module_path}; "
            "install telemetry on the Governator first"
        )
    specification = importlib.util.spec_from_file_location(
        "water_council_chair_sensor",
        module_path,
    )
    if specification is None or specification.loader is None:
        raise ValueError(f"could not load chair telemetry module: {module_path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    if getattr(module, "NUM_CHAIRS", None) != len(REGIMES):
        raise ValueError(
            f"chair telemetry defines {getattr(module, 'NUM_CHAIRS', None)!r} chairs; "
            f"expected {len(REGIMES)}"
        )
    if not callable(getattr(module, "SensorSource", None)):
        raise ValueError(f"chair telemetry has no SensorSource: {module_path}")
    return module


def chair_regime_ids(chairs) -> list[str]:
    """Map absolute chair occupancy flags to the fixed artwork regime order."""
    if not isinstance(chairs, (list, tuple)) or len(chairs) != len(REGIMES):
        raise ValueError(f"chair state must contain exactly {len(REGIMES)} flags")
    normalized = []
    for index, occupied in enumerate(chairs, start=1):
        if not isinstance(occupied, (bool, int)) or int(occupied) not in {0, 1}:
            raise ValueError(f"chair {index} state must be 0 or 1, got {occupied!r}")
        normalized.append(bool(occupied))
    return [
        regime_id
        for occupied, (regime_id, _display_name) in zip(normalized, REGIMES)
        if occupied
    ]


def run_chair_control() -> None:
    """Continuously apply the Governator's raw chair telemetry to Godot."""
    if current_operator()["name"] != "governator":
        raise ValueError(
            "chairs must run on the Governator at 196.168.50.11, "
            "where the USB telemetry log is written"
        )
    telemetry = load_chair_sensor_module()
    source = telemetry.SensorSource()
    print(
        "Chair control: "
        + ", ".join(
            f"{index}={display_name}"
            for index, (_regime_id, display_name) in enumerate(REGIMES, start=1)
        ),
        flush=True,
    )
    print(f"Reading raw telemetry from {telemetry.LOG}", flush=True)

    applied_state = None
    waiting_announced = False
    try:
        while True:
            source.poll()
            last_seen = getattr(source, "last_seen", {})
            has_live_history = isinstance(last_seen, dict) and any(
                seen_at is not None for seen_at in last_seen.values()
            )
            if not has_live_history:
                if not waiting_announced:
                    print("Waiting for the first chair telemetry packet...", flush=True)
                    waiting_announced = True
                time.sleep(CHAIR_POLL_SECONDS)
                continue

            chair_state = tuple(int(bool(value)) for value in source.chairs)
            if chair_state == applied_state:
                time.sleep(CHAIR_POLL_SECONDS)
                continue

            regime_ids = chair_regime_ids(chair_state)
            try:
                _saved_regimes, geometry_visible = load_controller_state()
                sends = send_fleet_regimes(
                    regime_ids,
                    "chairs",
                    geometry_visible=geometry_visible,
                )
                save_controller_state(regime_ids, geometry_visible)
            except (OSError, ValueError) as error:
                print(f"ERROR chair state not applied: {error}", file=sys.stderr, flush=True)
                time.sleep(1.0)
                continue

            applied_state = chair_state
            waiting_announced = False
            active = ", ".join(regime_ids) if regime_ids else "none"
            stale = ",".join(str(chair) for chair in source.stale) or "none"
            print(
                f"APPLIED  chairs={''.join(str(value) for value in chair_state)}; "
                f"active={active}; stale={stale}; {format_regime_send(sends)}",
                flush=True,
            )
    except KeyboardInterrupt:
        print("Chair control stopped.", flush=True)


def run_regime_console() -> None:
    if not sys.stdin.isatty():
        raise ValueError("regime-console requires an interactive terminal")
    import termios
    import tty

    active_ids, geometry_visible = load_controller_state(require_exists=True)
    file_descriptor = sys.stdin.fileno()
    original_terminal = termios.tcgetattr(file_descriptor)
    print("Regime console: 1-7 toggle, c clears, q or Esc quits.")
    print_regime_catalog()
    ordered_start = [regime_id for regime_id, _name in REGIMES if regime_id in active_ids]
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
            elif character in "1234567":
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


def deployment_paths(computer: dict, deployment_id: str) -> tuple[str, str]:
    project = computer["project"]
    normalized = posixpath.normpath(project)
    parent = posixpath.dirname(normalized)
    basename = posixpath.basename(normalized)
    if (
        not posixpath.isabs(project)
        or normalized != project
        or not parent.startswith("/Users/")
        or basename != "code"
        or any(character in project for character in "\r\n")
    ):
        raise ValueError(f"unsafe configured project path: {project!r}")
    if not re.fullmatch(r"[0-9a-f]{12}", deployment_id):
        raise ValueError(f"unsafe deployment ID: {deployment_id!r}")
    return (
        posixpath.join(parent, f".{basename}.deploy-{deployment_id}"),
        posixpath.join(parent, f".{basename}.backup-{deployment_id}"),
    )


def validate_deploy_source(targets: list[str]) -> Path:
    source = PROJECT_SOURCE_DIR.resolve()
    if not source.is_dir():
        raise ValueError(f"authoritative project directory not found: {source}")
    source_requirements = set(
        required_project_files({"stages": tuple(STAGE_SCREEN_IDS)})
    )
    missing = sorted(path for path in source_requirements if not (source / path).is_file())
    if missing:
        raise ValueError("authoritative project is incomplete: " + ", ".join(missing))
    fleet_source = FLEET_SOURCE_DIR.resolve()
    fleet_requirements = ("godot_controller.py", "README.md", "test_godot_controller.py")
    missing_fleet = sorted(
        path for path in fleet_requirements if not (fleet_source / path).is_file()
    )
    if missing_fleet:
        raise ValueError("authoritative fleet tools are incomplete: " + ", ".join(missing_fleet))
    for target in targets:
        computer = COMPUTERS[target]
        deployment_paths(computer, "0" * 12)
        if computer["local"]:
            destination = Path(computer["project"]).resolve()
            if (
                source == destination
                or source in destination.parents
                or destination in source.parents
            ):
                raise ValueError(
                    f"refusing overlapping deployment paths: source={source}, "
                    f"destination={destination}"
                )
    return source


def _rsync_command(
    source: Path,
    computer: dict,
    destination: str,
    verify: bool,
    excludes: tuple[str, ...],
) -> list[str]:
    options = ["-rlcin", "--delete"] if verify else ["-a", "--delete"]
    command = ["rsync", *options]
    for pattern in excludes:
        command.extend(["--exclude", pattern])
    source_argument = str(source) + os.sep
    if computer["local"]:
        destination_argument = destination.rstrip("/") + "/"
    else:
        remote_path = shlex.quote(destination.rstrip("/") + "/")
        destination_argument = f"{computer['user']}@{computer['ip']}:{remote_path}"
        command.extend(["-e", rsync_ssh_transport()])
    command.extend([source_argument, destination_argument])
    return command


def _rsync_project(
    source: Path,
    computer: dict,
    destination: str,
    verify: bool,
    excludes: tuple[str, ...],
) -> subprocess.CompletedProcess:
    return run_local(
        _rsync_command(source, computer, destination, verify, excludes),
        timeout=DEPLOY_TIMEOUT_SECONDS,
    )


def _substantive_rsync_changes(output: str) -> str:
    """Return content/tree changes, excluding rsync metadata-only notices.

    The macOS rsync bundled on the fleet emits itemized ``.f..T....`` lines
    for identical file contents whose mtimes differ, even when verification
    uses checksums and does not request timestamp preservation.  An itemized
    line beginning with ``.`` means rsync would not transfer or recreate that
    entry.  Content changes, additions, link changes, and deletions begin with
    ``>``, ``<``, ``c``, ``h``, or ``*`` and remain deployment blockers.
    """
    return "\n".join(
        line
        for line in output.splitlines()
        if line.strip() and not line.startswith(".")
    )


def _compare_tree(
    source: Path,
    computer: dict,
    destination: str,
) -> tuple[bool, bool, str]:
    """Return (comparison_succeeded, trees_match, detail)."""
    project_result = _rsync_project(
        source,
        computer,
        destination,
        verify=True,
        excludes=PROJECT_DEPLOY_EXCLUDES,
    )
    if project_result.returncode != 0:
        return False, False, "project comparison failed: " + error_message(project_result)
    fleet_result = _rsync_project(
        FLEET_SOURCE_DIR.resolve(),
        computer,
        posixpath.join(destination, "fleet"),
        verify=True,
        excludes=FLEET_DEPLOY_EXCLUDES,
    )
    if fleet_result.returncode != 0:
        return False, False, "fleet comparison failed: " + error_message(fleet_result)
    changes = "\n".join(
        filtered
        for filtered in (
            _substantive_rsync_changes(project_result.stdout),
            _substantive_rsync_changes(fleet_result.stdout),
        )
        if filtered
    )
    if changes:
        return True, False, f"tree differs from authoritative source: {changes}"
    return True, True, "checksum match"


def _verify_tree(source: Path, computer: dict, destination: str) -> tuple[bool, str]:
    compared, matches, message = _compare_tree(source, computer, destination)
    return compared and matches, message


def _verify_deployed_tree(source: Path, target: str) -> tuple[bool, str]:
    computer = COMPUTERS[target]
    project_path = computer["project"]
    verified, verification_message = _verify_tree(source, computer, project_path)
    if not verified:
        return False, verification_message
    validated = ssh(
        computer,
        cache_validation_command(project_path),
        timeout=SSH_TIMEOUT_SECONDS,
    )
    if validated.returncode != 0:
        return False, "active Godot cache validation failed: " + error_message(validated)
    return True, "checksum match; Godot imports and global classes ready"


def _import_stage_cache(target: str, project_path: str) -> tuple[bool, str]:
    computer = COMPUTERS[target]
    command = (
        f"{shlex.quote(GODOT_BIN)} --headless --path "
        f"{shlex.quote(project_path)} --import"
    )
    imported = ssh(computer, command, timeout=DEPLOY_TIMEOUT_SECONDS)
    if imported.returncode != 0:
        return False, "Godot import failed: " + error_message(imported)
    validated = ssh(
        computer,
        cache_validation_command(project_path),
        timeout=SSH_TIMEOUT_SECONDS,
    )
    if validated.returncode != 0:
        return False, "Godot cache validation failed: " + error_message(validated)
    return True, "Godot imports and global classes ready"


def _prepare_stage(
    target: str,
    source: Path,
    stage_path: str,
    backup_path: str,
) -> tuple[bool, str]:
    computer = COMPUTERS[target]
    parent = posixpath.dirname(computer["project"])
    command = (
        f"test -x {shlex.quote(GODOT_BIN)} || "
        f"{{ echo {shlex.quote('Godot executable not found: ' + GODOT_BIN)}; exit 10; }}; "
        f"test -d {shlex.quote(parent)} && test -w {shlex.quote(parent)} || "
        f"{{ echo {shlex.quote('Deployment parent missing or not writable: ' + parent)}; exit 11; }}; "
        f"test -d {shlex.quote(computer['project'])} || "
        f"{{ echo {shlex.quote('Installed project missing: ' + computer['project'])}; exit 14; }}; "
        f"test ! -e {shlex.quote(stage_path)} || "
        f"{{ echo {shlex.quote('Stage path already exists: ' + stage_path)}; exit 12; }}; "
        f"test ! -e {shlex.quote(backup_path)} || "
        f"{{ echo {shlex.quote('Backup path already exists: ' + backup_path)}; exit 13; }}; "
        f"mkdir {shlex.quote(stage_path)}"
    )
    prepared = ssh(computer, command)
    if prepared.returncode != 0:
        return False, error_message(prepared)
    copied = _rsync_project(
        source,
        computer,
        stage_path,
        verify=False,
        excludes=PROJECT_DEPLOY_EXCLUDES,
    )
    if copied.returncode != 0:
        return False, error_message(copied)
    fleet_copy = _rsync_project(
        FLEET_SOURCE_DIR.resolve(),
        computer,
        posixpath.join(stage_path, "fleet"),
        verify=False,
        excludes=FLEET_DEPLOY_EXCLUDES,
    )
    if fleet_copy.returncode != 0:
        return False, error_message(fleet_copy)
    verified, verification_message = _verify_tree(source, computer, stage_path)
    if not verified:
        return False, verification_message
    imported, import_message = _import_stage_cache(target, stage_path)
    if not imported:
        return False, import_message
    verified, verification_message = _verify_tree(source, computer, stage_path)
    if not verified:
        return False, "post-import source verification failed: " + verification_message
    return True, "checksum match; " + import_message


def _promote_stage(
    target: str,
    stage_path: str,
    backup_path: str,
) -> tuple[bool, str]:
    computer = COMPUTERS[target]
    project = computer["project"]
    command = (
        f"test -d {shlex.quote(stage_path)} || "
        f"{{ echo {shlex.quote('Verified stage is missing: ' + stage_path)}; exit 20; }}; "
        f"test -e {shlex.quote(project)} || "
        f"{{ echo {shlex.quote('Installed project disappeared before promotion: ' + project)}; exit 23; }}; "
        f"test ! -e {shlex.quote(backup_path)} || "
        f"{{ echo {shlex.quote('Backup path appeared before promotion: ' + backup_path)}; exit 24; }}; "
        f"mv {shlex.quote(project)} {shlex.quote(backup_path)} || exit 21; "
        f"if mv {shlex.quote(stage_path)} {shlex.quote(project)}; then "
        f"echo {shlex.quote(backup_path)}; "
        "else "
        f"mv {shlex.quote(backup_path)} {shlex.quote(project)}; exit 22; "
        "fi"
    )
    result = ssh(computer, command)
    return (
        result.returncode == 0,
        result.stdout.strip() if result.returncode == 0 else error_message(result),
    )


def _rollback_target(
    target: str,
    stage_path: str,
    backup_path: str,
) -> tuple[bool, str]:
    computer = COMPUTERS[target]
    project = computer["project"]
    command = (
        f"if test -e {shlex.quote(backup_path)}; then "
        f"if test -e {shlex.quote(project)}; then "
        f"test ! -e {shlex.quote(stage_path)} || "
        f"{{ echo {shlex.quote('Cannot preserve failed tree; stage exists: ' + stage_path)}; exit 30; }}; "
        f"mv {shlex.quote(project)} {shlex.quote(stage_path)} || exit 31; "
        "fi; "
        f"mv {shlex.quote(backup_path)} {shlex.quote(project)} || exit 32; "
        "fi"
    )
    result = ssh(computer, command)
    return (
        result.returncode == 0,
        "rolled back" if result.returncode == 0 else error_message(result),
    )


def _cleanup_stage(target: str, stage_path: str) -> tuple[bool, str]:
    computer = COMPUTERS[target]
    parent = posixpath.dirname(computer["project"])
    prefix = f".{posixpath.basename(computer['project'])}.deploy-"
    stage_name = posixpath.basename(stage_path)
    if (
        posixpath.dirname(stage_path) != parent
        or re.fullmatch(re.escape(prefix) + r"[0-9a-f]{12}", stage_name) is None
    ):
        return False, f"refusing unsafe stage cleanup: {stage_path}"
    result = ssh(computer, f"rm -rf -- {shlex.quote(stage_path)}")
    return (
        result.returncode == 0,
        "stage cleaned" if result.returncode == 0 else error_message(result),
    )


def _cleanup_backup(target: str, backup_path: str) -> tuple[bool, str]:
    computer = COMPUTERS[target]
    parent = posixpath.dirname(computer["project"])
    prefix = f".{posixpath.basename(computer['project'])}.backup-"
    backup_name = posixpath.basename(backup_path)
    if (
        posixpath.dirname(backup_path) != parent
        or re.fullmatch(re.escape(prefix) + r"[0-9a-f]{12}", backup_name) is None
    ):
        return False, f"refusing unsafe backup cleanup: {backup_path}"
    result = ssh(computer, f"rm -rf -- {shlex.quote(backup_path)}")
    return (
        result.returncode == 0,
        "old backup removed" if result.returncode == 0 else error_message(result),
    )


def _parallel(targets: list[str], operation) -> dict[str, tuple[bool, str]]:
    with ThreadPoolExecutor(max_workers=len(targets)) as pool:
        values = list(pool.map(operation, targets))
    return dict(zip(targets, values))


def _deployment_failure_results(
    targets: list[str],
    phase: str,
    phase_results: dict[str, tuple[bool, str]],
    extra: str = "",
) -> list[tuple[str, bool, str]]:
    failures = "; ".join(
        f".{target}: {message}"
        for target, (ok, message) in phase_results.items()
        if not ok
    )
    message = f"{phase} failed; deployment aborted: {failures}"
    if extra:
        message += f"; {extra}"
    return [(COMPUTERS[target]["ip"], False, message) for target in targets]


def deploy_targets(
    targets: list[str],
    dry_run: bool = False,
) -> list[tuple[str, bool, str]]:
    if len(set(targets)) != len(targets):
        message = "duplicate deployment targets are not allowed"
        return [
            (COMPUTERS[target]["ip"], False, message)
            for target in dict.fromkeys(targets)
            if target in COMPUTERS
        ]
    if current_operator()["name"] != "studio":
        return [
            (
                COMPUTERS[target]["ip"],
                False,
                "deploy is permitted only from the studio controller at 196.168.50.51",
            )
            for target in targets
        ]
    try:
        source = validate_deploy_source(targets)
    except ValueError as error:
        return [(COMPUTERS[target]["ip"], False, str(error)) for target in targets]
    if not os.path.isfile(SSH_IDENTITY_PATH):
        message = (
            f"dedicated SSH identity not found: {SSH_IDENTITY_PATH}; "
            "create/install it before deployment"
        )
        return [(COMPUTERS[target]["ip"], False, message) for target in targets]
    if any(COMPUTERS[target]["local"] for target in targets):
        message = "studio deployment requires every selected fleet computer to be remote"
        return [(COMPUTERS[target]["ip"], False, message) for target in targets]

    if dry_run:
        def compare(target: str) -> tuple[bool, str]:
            computer = COMPUTERS[target]
            compared, matches, message = _compare_tree(
                source,
                computer,
                computer["project"],
            )
            if not compared:
                return False, message
            return True, "up to date" if matches else "changes required:\n" + message

        comparisons = _parallel(targets, compare)
        return [
            (COMPUTERS[target]["ip"], comparisons[target][0], comparisons[target][1])
            for target in targets
        ]

    deployment_id = uuid.uuid4().hex[:12]
    paths = {
        target: deployment_paths(COMPUTERS[target], deployment_id)
        for target in targets
    }
    staged = _parallel(
        targets,
        lambda target: _prepare_stage(target, source, *paths[target]),
    )
    if any(not ok for ok, _message in staged.values()):
        _parallel(targets, lambda target: _cleanup_stage(target, paths[target][0]))
        return _deployment_failure_results(targets, "staging", staged)

    stopped = _parallel(
        targets,
        lambda target: (
            lambda result: (
                result.returncode == 0,
                "stopped" if result.returncode == 0 else error_message(result),
            )
        )(stop_godot_processes(COMPUTERS[target])),
    )
    if any(not ok for ok, _message in stopped.values()):
        _parallel(targets, lambda target: _cleanup_stage(target, paths[target][0]))
        stopped_targets = [
            f".{target}"
            for target, (ok, _message) in stopped.items()
            if ok
        ]
        stopped_detail = ", ".join(stopped_targets) or "none"
        return _deployment_failure_results(
            targets,
            "stop",
            stopped,
            "no project directories were promoted; stop completed on "
            f"{stopped_detail}, which remain stopped; resolve the error, then run start",
        )

    promoted = _parallel(
        targets,
        lambda target: _promote_stage(target, *paths[target]),
    )
    if any(not ok for ok, _message in promoted.values()):
        rolled_back = _parallel(
            targets,
            lambda target: _rollback_target(target, *paths[target]),
        )
        _parallel(targets, lambda target: _cleanup_stage(target, paths[target][0]))
        rollback_failures = "; ".join(
            f".{target}: {message}"
            for target, (ok, message) in rolled_back.items()
            if not ok
        )
        extra = "all promoted targets rolled back"
        if rollback_failures:
            extra = "ROLLBACK ERROR: " + rollback_failures
        return _deployment_failure_results(targets, "promotion", promoted, extra)

    verified = _parallel(
        targets,
        lambda target: _verify_deployed_tree(source, target),
    )
    if any(not ok for ok, _message in verified.values()):
        rolled_back = _parallel(
            targets,
            lambda target: _rollback_target(target, *paths[target]),
        )
        _parallel(targets, lambda target: _cleanup_stage(target, paths[target][0]))
        rollback_failures = "; ".join(
            f".{target}: {message}"
            for target, (ok, message) in rolled_back.items()
            if not ok
        )
        extra = "all promoted targets rolled back"
        if rollback_failures:
            extra = "ROLLBACK ERROR: " + rollback_failures
        return _deployment_failure_results(targets, "verification", verified, extra)

    cleaned = _parallel(
        targets,
        lambda target: _cleanup_backup(target, promoted[target][1]),
    )
    results = []
    for target in targets:
        cleanup_ok, cleanup_message = cleaned[target]
        results.append(
            (
                COMPUTERS[target]["ip"],
                cleanup_ok,
                (
                    "deployed and checksum-verified; left stopped; old backup removed"
                    if cleanup_ok
                    else "deployed and checksum-verified; left stopped; "
                    f"OLD BACKUP CLEANUP FAILED: {cleanup_message}"
                ),
            )
        )
    return results


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
            "deploy",
            "list",
            "set",
            "regime-clear",
            "regime-console",
            "chairs",
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
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show exact deploy differences without writing or stopping Godot",
    )
    args = parser.parse_args()

    try:
        operator = configure_operator()
    except ValueError as error:
        parser.error(str(error))
    print(
        f"Controller: {operator['name']} at {operator['ip']} "
        f"({'target .11 local' if operator['local_target'] else 'all fleet targets over SSH'})"
    )

    if args.dry_run and args.action != "deploy":
        parser.error("--dry-run is accepted only by deploy")

    regime_actions = {"list", "set", "regime-clear", "regime-console", "chairs"}
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
            if args.action == "chairs":
                run_chair_control()
                return
            require_saved_state = args.action == "set" and not args.regime
            saved_regime_ids, saved_geometry_visible = load_controller_state(
                require_exists=require_saved_state,
            )
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
    if len(set(selected_targets)) != len(selected_targets):
        parser.error("duplicate machine targets are not allowed")
    targets = selected_targets

    if args.action == "deploy":
        results = deploy_targets(targets, dry_run=args.dry_run)
        failed = False
        for ip_address, ok, message in results:
            print(f"{'OK' if ok else 'ERROR':5} {ip_address}: {message}")
            failed = failed or not ok
        raise SystemExit(1 if failed else 0)

    startup_state = None
    if args.action in {"start", "restart"}:
        try:
            startup_state = load_controller_state(require_exists=True)
        except (OSError, ValueError) as error:
            parser.error(
                "could not load the authoritative regime state before launch; "
                f"left running processes untouched: {error}"
            )

    effective_action = "start" if args.action == "restart" else args.action
    with ThreadPoolExecutor(max_workers=len(targets)) as pool:
        results = list(pool.map(lambda target: perform(target, effective_action), targets))

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
                active_ids, geometry_visible = startup_state
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
