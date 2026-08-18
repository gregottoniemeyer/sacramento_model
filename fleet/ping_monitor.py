import platform
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

TARGETS = [
    "196.168.50.41",
    "196.168.50.31",
    "196.168.50.21",
]

INTERVAL_SECONDS = 300
PING_TIMEOUT_SECONDS = 3


def ping(ip_address):
    if platform.system().lower() == "windows":
        command = ["ping", "-n", "1", ip_address]
    else:
        command = ["ping", "-c", "1", ip_address]

    try:
        result = subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=PING_TIMEOUT_SECONDS,
            check=False,
        )
        return ip_address, result.returncode == 0
    except subprocess.TimeoutExpired:
        return ip_address, False


def main():
    print(f"Monitoring from master computer 196.168.50.11")
    print("Press Ctrl+C to stop.\n")

    try:
        while True:
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

            with ThreadPoolExecutor(max_workers=len(TARGETS)) as executor:
                results = list(executor.map(ping, TARGETS))

            for ip_address, reachable in results:
                status = "ONLINE " if reachable else "OFFLINE"
                print(f"[{timestamp}] {ip_address:<15} {status}")

            print()
            time.sleep(INTERVAL_SECONDS)

    except KeyboardInterrupt:
        print("\nMonitoring stopped.")


if __name__ == "__main__":
    main()