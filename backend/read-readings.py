#!/usr/bin/env python3
"""Collect all widget readings in one cycle for a synchronized panel update."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
from pathlib import Path
from typing import Any


def read_json(command: list[str], timeout: float = 7.0) -> dict[str, Any]:
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # The sensor shell can have children such as nvidia-smi and awk.
            # Kill the whole process group so a hung driver query cannot leave
            # one orphan behind on every Plasma polling cycle.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            return {}
        if not stdout or not stdout.strip():
            return {}
        value = json.loads(stdout)
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def main() -> int:
    bin_dir = Path.home() / ".local" / "bin"
    sensors = read_json([str(bin_dir / "mi-power-monitor-sensors")])
    total = read_json([str(bin_dir / "xiaomi-power"), "--json"])

    total_power = total.get("power") if total.get("available") is True else None
    output = {
        "total_power": total_power,
        "cpu_power": sensors.get("cpu_power"),
        "gpu_power": sensors.get("gpu_power"),
    }
    json.dump(output, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
