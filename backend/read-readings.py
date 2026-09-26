#!/usr/bin/env python3
"""Collect one bounded, timestamped snapshot for the Plasma panel."""

from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import json
import math
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any

SOURCE_TIMEOUT = 2.0
PLUG_ATTEMPT_TIMEOUT = "500ms"


def read_json(command: list[str], timeout: float = SOURCE_TIMEOUT) -> tuple[dict[str, Any], float | None]:
    started_at = time.time()
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
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            return {}, None
        if not stdout or not stdout.strip():
            return {}, None
        value = json.loads(stdout)
        if not isinstance(value, dict):
            return {}, None
        return value, (started_at + time.time()) / 2
    except (OSError, json.JSONDecodeError):
        return {}, None


def backend_command() -> str | None:
    override = os.environ.get("MI_POWER_MONITOR_XIAOMI_POWER", "").strip()
    candidates = [Path(override)] if override else []
    candidates.append(Path(__file__).resolve().with_name("xiaomi-power"))
    candidates.append(Path.home() / ".local" / "bin" / "xiaomi-power")
    discovered = shutil.which("xiaomi-power")
    if discovered:
        candidates.append(Path(discovered))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def create_snapshot(
    sensor: dict[str, Any],
    total: dict[str, Any],
    sensor_at: float | None,
    total_at: float | None,
    plug: str | None,
) -> dict[str, Any]:
    def numeric(value: Any) -> float | None:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        value = float(value)
        return value if math.isfinite(value) and value >= 0 else None

    def sampled_at(value: Any, fallback: float | None) -> float | None:
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
            return float(value)
        if isinstance(value, str):
            try:
                return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
            except ValueError:
                pass
        return fallback

    total_power = numeric(total.get("power")) if total.get("available") is True else None
    error = str(total.get("error", "")).lower()
    if plug is None:
        status = "backend-missing"
    elif "config" in error and any(word in error for word in ("cannot load", "invalid", "missing")):
        status = "unconfigured"
    elif total_power is None:
        status = "unavailable"
    else:
        status = "ok"

    return {
        "total_power": total_power,
        "cpu_power": numeric(sensor.get("cpu_power")),
        "gpu_power": numeric(sensor.get("gpu_power")),
        "total_sampled_at": sampled_at(total.get("sampled_at"), total_at),
        "cpu_sampled_at": sampled_at(sensor.get("cpu_sampled_at"), sensor_at),
        "gpu_sampled_at": sampled_at(sensor.get("gpu_sampled_at"), sensor_at),
        "status": status,
        "snapshot_at": time.time(),
        "snapshot_sequence": time.monotonic_ns(),
    }


def collect(*, cpu: bool = True, gpu: bool = True) -> dict[str, Any]:
    sensor_script = Path(__file__).resolve().with_name("read-sensors.sh")
    plug = backend_command()
    commands: dict[str, list[str] | None] = {
        "sensors": ([str(sensor_script)] + ([] if cpu else ["--no-cpu"])
                    + ([] if gpu else ["--no-gpu"])) if sensor_script.is_file() and (cpu or gpu) else None,
        "total": [plug, "--json", "--timeout", PLUG_ATTEMPT_TIMEOUT] if plug else None,
    }

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = {
            name: pool.submit(read_json, command)
            for name, command in commands.items()
            if command is not None
        }
        sensor, sensor_at = futures["sensors"].result() if "sensors" in futures else ({}, None)
        total, total_at = futures["total"].result() if "total" in futures else ({}, None)

    return create_snapshot(sensor, total, sensor_at, total_at, plug)


def acquire_cycle_lock() -> int | None:
    """Allow at most one slow poll cycle; overlapping Plasma ticks return fast."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    lock_dir = Path(runtime_dir) if runtime_dir and Path(runtime_dir).is_dir() else Path(tempfile.gettempdir())
    lock_path = lock_dir / f"mi-power-monitor-readings-{os.getuid()}.lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = -1
    try:
        fd = os.open(lock_path, flags, 0o600)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            os.close(fd)
            return None
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (OSError, BlockingIOError):
        if fd >= 0:
            os.close(fd)
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-cpu", action="store_true")
    parser.add_argument("--no-gpu", action="store_true")
    args = parser.parse_args()
    lock_fd = acquire_cycle_lock()
    if lock_fd is None:
        snapshot = {"status": "busy", "snapshot_at": 0, "snapshot_sequence": 0}
    else:
        try:
            snapshot = collect(cpu=not args.no_cpu, gpu=not args.no_gpu)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
    json.dump(snapshot, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
