#!/usr/bin/env python3
"""Control the Water Council Godot project on the master and three remote Macs."""

import argparse
import os
import shlex
import subprocess
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["ping", "check", "status", "start", "editor", "stop", "restart"])
    parser.add_argument(
        "targets",
        nargs="*",
        default=None,
        metavar="TARGET",
        help="last IP octets to control (default: all)",
    )
    args = parser.parse_args()

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
