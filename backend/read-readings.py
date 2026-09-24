#!/usr/bin/env python3
"""Collect all widget readings in one cycle for a synchronized panel update."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any


def read_json(command: list[str], timeout: float = 7.0) -> dict[str, Any]:
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if not result.stdout.strip():
            return {}
        value = json.loads(result.stdout)
        return value if isinstance(value, dict) else {}
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
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
