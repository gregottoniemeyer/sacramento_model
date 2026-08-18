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
from concurrent.futures import ThreadPoolExecutor


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
FLOW_CONTROL_PORT = 5005
REGIME_TARGET = "*"
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
        if computer["local"]:
            result = run_local(["pkill", "-TERM", "-f", process_pattern(computer)])
            if result.returncode == 1:
                result = subprocess.CompletedProcess(result.args, 0, result.stdout, result.stderr)
        else:
            command = f"pkill -TERM -f {shlex.quote(process_pattern(computer))} || test $? -eq 1"
            result = ssh(computer, command)
        return ip_address, result.returncode == 0, "stopped" if result.returncode == 0 else error_message(result)

    if action in {"start", "editor"}:
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


def regime_destinations() -> list[str]:
    """Return one UDP destination for every configured Godot process."""
    destinations: list[str] = []
    for computer in COMPUTERS.values():
        destination = "127.0.0.1" if computer["local"] else computer["ip"]
        if destination not in destinations:
            destinations.append(destination)
    if not destinations:
        raise ValueError("no fleet computers are configured")
    return destinations


def regime_indices(regime_ids: list[str]) -> list[int]:
    if len(set(regime_ids)) != len(regime_ids):
        raise ValueError("duplicate --regime values are not allowed")
    known_ids = [regime_id for regime_id, _display_name in REGIMES]
    unknown = [regime_id for regime_id in regime_ids if regime_id not in known_ids]
    if unknown:
        raise ValueError(f"unknown regime(s): {', '.join(unknown)}")
    return sorted(known_ids.index(regime_id) for regime_id in regime_ids)


def send_fleet_regimes(regime_ids: list[str], command: str) -> list[tuple[str, int]]:
    indices = regime_indices(regime_ids)
    payload = {
        "protocol": "ink-flow/1",
        "target": REGIME_TARGET,
        "changes": {"regimes.active_indices": indices},
        "geometry_ops": [],
        "actions": [],
        "metadata": {"source": "governator", "command": command},
    }
    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    results: list[tuple[str, int]] = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp_socket:
        for destination in regime_destinations():
            sent = udp_socket.sendto(encoded, (destination, FLOW_CONTROL_PORT))
            if sent != len(encoded):
                raise OSError(
                    f"sent only {sent} of {len(encoded)} UDP bytes to {destination}"
                )
            results.append((destination, sent))
    return results


def format_regime_send(results: list[tuple[str, int]]) -> str:
    return ", ".join(
        f"{destination}:{FLOW_CONTROL_PORT} ({sent} bytes)"
        for destination, sent in results
    )


def load_controller_regime_state() -> set[str]:
    if not os.path.isfile(REGIME_STATE_PATH):
        return set()
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
        return set(regime_ids)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise ValueError(
            f"invalid controller state {REGIME_STATE_PATH}: {error}"
        ) from error


def save_controller_regime_state(regime_ids: list[str]) -> None:
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
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as state_file:
            json.dump(
                {"active_regime_ids": ordered_ids},
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


def print_regime_catalog() -> None:
    for index, (regime_id, display_name) in enumerate(REGIMES, start=1):
        print(f"{index}: {regime_id:<16} {display_name}")


def run_regime_console() -> None:
    if not sys.stdin.isatty():
        raise ValueError("regime-console requires an interactive terminal")
    import termios
    import tty

    active_ids = load_controller_regime_state()
    file_descriptor = sys.stdin.fileno()
    original_terminal = termios.tcgetattr(file_descriptor)
    print("Regime console: 1-7 toggle, c clears, q or Esc quits.")
    print_regime_catalog()
    ordered_start = [
        regime_id for regime_id, _name in REGIMES if regime_id in active_ids
    ]
    sends = send_fleet_regimes(ordered_start, "regime-console-sync")
    initial_state = ", ".join(ordered_start) if ordered_start else "none"
    print(f"SENT to {format_regime_send(sends)}: active={initial_state}")
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
                sends = send_fleet_regimes([], "regime-clear")
            elif character and character in "1234567":
                regime_id = REGIMES[int(character) - 1][0]
                if regime_id in active_ids:
                    active_ids.remove(regime_id)
                else:
                    active_ids.add(regime_id)
                sends = send_fleet_regimes(
                    list(active_ids),
                    "regime-console",
                )
            else:
                continue
            ordered = [regime_id for regime_id, _name in REGIMES if regime_id in active_ids]
            save_controller_regime_state(ordered)
            state = ", ".join(ordered) if ordered else "none"
            print(f"\rSENT to {format_regime_send(sends)}: active={state}          ")
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
            "regime-set",
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
        help="regime ID for regime-set; repeat to activate several regimes",
    )
    args = parser.parse_args()

    regime_actions = {"list", "regime-set", "regime-clear", "regime-console"}
    if args.action in regime_actions:
        if args.targets:
            parser.error(f"{args.action} does not accept machine targets")
        if args.action == "list":
            if args.regime:
                parser.error("list does not accept --regime")
            print_regime_catalog()
            return
        if args.action == "regime-set" and not args.regime:
            parser.error("regime-set requires at least one --regime")
        if args.action != "regime-set" and args.regime:
            parser.error(f"{args.action} does not accept --regime")
        try:
            if args.action == "regime-console":
                run_regime_console()
                return
            regime_ids = args.regime if args.action == "regime-set" else []
            command = "regime-set" if regime_ids else "regime-clear"
            sends = send_fleet_regimes(regime_ids, command)
            save_controller_regime_state(regime_ids)
            active = ", ".join(regime_ids) if regime_ids else "none"
            print(f"SENT  {format_regime_send(sends)}; active={active}")
            return
        except (OSError, ValueError) as error:
            parser.error(str(error))

    if args.regime:
        parser.error(f"{args.action} does not accept --regime")

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
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
