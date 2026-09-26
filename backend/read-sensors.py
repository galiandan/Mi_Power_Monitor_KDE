#!/usr/bin/env python3
"""Read complete CPU Package RAPL and NVIDIA power samples."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import re
import subprocess
import time
from pathlib import Path
from typing import Callable

PACKAGE_NAME = re.compile(r"^package(?:[-_ ]\d+)?$", re.IGNORECASE)
MAX_SAMPLE_SECONDS = 5.0
MAX_POWER_W = 100_000.0


def _boottime_ns() -> int:
    # CLOCK_BOOTTIME is monotonic and includes time spent suspended. Fall back
    # to CLOCK_MONOTONIC on systems that do not expose it.
    boottime = getattr(time, "CLOCK_BOOTTIME", None)
    if boottime is not None:
        return time.clock_gettime_ns(boottime)
    return time.monotonic_ns()


def _suspend_offset_ns() -> int | None:
    """Return accumulated suspend time when the kernel exposes both clocks."""
    boottime = getattr(time, "CLOCK_BOOTTIME", None)
    monotonic = getattr(time, "CLOCK_MONOTONIC", None)
    if boottime is None or monotonic is None:
        return None
    return time.clock_gettime_ns(boottime) - time.clock_gettime_ns(monotonic)


def read_integer(path: Path) -> int | None:
    try:
        raw = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return None
    return int(raw) if raw.isdecimal() else None


def package_domains(root: Path) -> list[Path]:
    domains: list[Path] = []
    try:
        candidates = root.glob("*rapl:[0-9]*")
        for domain in candidates:
            if not domain.is_dir() or not re.search(r"rapl:\d+$", domain.name):
                continue
            try:
                name = (domain / "name").read_text(encoding="ascii").strip()
            except (OSError, UnicodeError):
                # A top-level domain with an unreadable name could be a
                # Package, so omitting it would silently undercount CPU power.
                return []
            if PACKAGE_NAME.fullmatch(name):
                domains.append(domain)
    except OSError:
        return []
    return sorted(domains)


def read_counters(domains: list[Path]) -> dict[Path, int | None]:
    paths = [domain / name for domain in domains
             for name in ("energy_uj", "max_energy_range_uj")]
    values = {path: read_integer(path) for path in paths}
    if all(value is not None for value in values.values()):
        return values
    if not Path("/usr/local/libexec/mi-power-monitor/read-rapl").is_file():
        return values
    try:
        result = subprocess.run(
            ["sudo", "-n", "--", "/usr/local/libexec/mi-power-monitor/read-rapl"],
            capture_output=True, text=True, timeout=0.3, check=True,
        )
        privileged = json.loads(result.stdout)
        if not isinstance(privileged, dict):
            return values
        for path, value in values.items():
            candidate = privileged.get(str(path.resolve()))
            if value is None and type(candidate) is int and candidate >= 0:
                values[path] = candidate
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return values


def sample_cpu(
    root: Path,
    interval: float = 1.0,
    *,
    sleep: Callable[[float], None] = time.sleep,
    monotonic_ns: Callable[[], int] = _boottime_ns,
    suspend_offset_ns: Callable[[], int | None] = _suspend_offset_ns,
    wall_time: Callable[[], float] = time.time,
) -> tuple[float | None, float | None]:
    """Return the sum of Package power and its approximate wall-clock sample time."""
    domains = package_domains(root)
    if not domains:
        return None, None

    suspend_before = suspend_offset_ns()
    before: list[tuple[int, int, int]] = []
    start = monotonic_ns()
    first = read_counters(domains)
    end = monotonic_ns()
    for domain in domains:
        energy = first[domain / "energy_uj"]
        maximum = first[domain / "max_energy_range_uj"]
        if energy is None or maximum is None or maximum <= 0:
            return None, None
        before.append((energy, maximum, (start + end) // 2))

    sleep(interval)

    watts: list[float] = []
    sample_times: list[float] = []
    start = monotonic_ns()
    second = read_counters(domains)
    end = monotonic_ns()
    for domain, (initial, maximum, initial_ns) in zip(domains, before, strict=True):
        final = second[domain / "energy_uj"]
        if final is None or final < initial:
            # A decrease can mean wraparound, reset, suspend or driver reload.
            # Reject it rather than turn an ambiguous event into a power spike.
            return None, None

        elapsed = ((start + end) // 2 - initial_ns) / 1_000_000_000
        delta_uj = final - initial
        if not math.isfinite(elapsed) or elapsed <= 0 or elapsed > MAX_SAMPLE_SECONDS:
            return None, None
        power = delta_uj / 1_000_000 / elapsed
        if not math.isfinite(power) or power < 0 or power > MAX_POWER_W:
            return None, None
        watts.append(power)
        sample_times.append(wall_time())

    suspend_after = suspend_offset_ns()
    if suspend_before is not None and suspend_after is not None:
        # RAPL may stop, continue, or reset while the machine is suspended.
        # Do not average across that unknown interval; wait for a clean sample.
        if suspend_after - suspend_before > 50_000_000:
            return None, None

    return sum(watts), sum(sample_times) / len(sample_times)


def nvidia_suspended(root: Path = Path("/sys/bus/pci/devices")) -> bool:
    # Reading sysfs runtime_status does not initialize NVML or wake the GPU.
    # Skip the all-GPU query if any NVIDIA display device is asleep.
    for device in root.glob("*"):
        try:
            if ((device / "vendor").read_text().strip() == "0x10de"
                    and (device / "class").read_text().strip().startswith("0x03")
                    and (device / "power/runtime_status").read_text().strip() != "active"):
                return True
        except OSError:
            continue
    return False


def read_gpu(timeout: float = 1.4) -> tuple[float | None, float | None]:
    if nvidia_suspended():
        return None, None
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=power.draw", "--format=csv,noheader,nounits"],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, None
    if result.returncode != 0:
        return None, None

    rows = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not rows:
        return None, None
    values: list[float] = []
    try:
        for row in rows:
            value = float(row)
            if not math.isfinite(value) or value < 0:
                return None, None
            values.append(value)
    except ValueError:
        return None, None
    return sum(values), time.time()


def collect(root: Path, interval: float, *, cpu: bool = True, gpu: bool = True) -> dict[str, float | None]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        cpu_future = pool.submit(sample_cpu, root, interval) if cpu else None
        gpu_future = pool.submit(read_gpu) if gpu else None
        cpu_power, cpu_time = cpu_future.result() if cpu_future else (None, None)
        gpu_power, gpu_time = gpu_future.result() if gpu_future else (None, None)
    return {
        "cpu_power": cpu_power,
        "gpu_power": gpu_power,
        "cpu_sampled_at": cpu_time,
        "gpu_sampled_at": gpu_time,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--powercap-root", type=Path, default=Path("/sys/class/powercap"))
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--no-cpu", action="store_true")
    parser.add_argument("--no-gpu", action="store_true")
    args = parser.parse_args()
    interval = min(max(args.interval, 0.05), 4.0)
    print(json.dumps(collect(args.powercap_root, interval, cpu=not args.no_cpu, gpu=not args.no_gpu), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
