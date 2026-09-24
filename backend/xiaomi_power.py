#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Xiaomi Power Monitor contributors
"""Read live power from a Xiaomi MIoT smart plug over the local network."""

from __future__ import annotations

import argparse
import getpass
import json
import math
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

MODEL = "cuco.plug.v3"
POWER_SIID = 11
POWER_PIID = 2
ENERGY_SIID = 11
ENERGY_PIID = 1


def _ensure_miio_available() -> None:
    """Use the project venv when invoked with the system `python` command."""
    local_venv = Path(__file__).resolve().parent / ".venv"
    local_python = local_venv / "bin" / "python"
    # Arch's venv Python is a symlink to the same system binary, so comparing
    # resolved executable paths misses that it has a different site-packages.
    if local_python.is_file() and Path(sys.prefix).resolve() != local_venv.resolve():
        os.execv(str(local_python), [str(local_python), str(Path(__file__).resolve()), *sys.argv[1:]])

    try:
        import miio  # noqa: F401
    except ImportError:
        pass


_ensure_miio_available()

try:
    from miio import MiotDevice
except ImportError:
    MiotDevice = None  # type: ignore[assignment,misc]


def config_path() -> Path:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return config_home / "xiaomi-power" / "config.json"


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(
            f"Missing config: {path}\n"
            "Copy config.example.json to that path, then fill in the device IP and token."
        )

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot read JSON config at {path}: {exc.__class__.__name__}") from None

    if not isinstance(data, dict):
        raise ValueError("Config must be a JSON object")
    if data.get("model", MODEL) != MODEL:
        raise ValueError(f"Config model must be {MODEL}")
    for required in ("ip", "token"):
        if not isinstance(data.get(required), str) or not data[required].strip():
            raise ValueError(f"Config is missing a non-empty '{required}' field")
    token = data["token"].strip()
    if token.startswith("REPLACE_") or token.lower() in {"your_token", "token"}:
        raise ValueError("Replace the example token with this device's 32-character token")
    data["token"] = token
    return data


def _property_value(response: Any) -> Any:
    """Extract a MIoT property value from python-miio's response representation."""
    if isinstance(response, dict):
        if response.get("code", 0) not in (0, None):
            raise RuntimeError(f"device returned MIoT error code {response['code']}")
        if "value" in response:
            return response["value"]
        if "result" in response:
            return _property_value(response["result"])
    if isinstance(response, (list, tuple)):
        if not response:
            raise RuntimeError("device returned an empty MIoT response")
        return _property_value(response[0])
    if isinstance(response, (int, float)) and not isinstance(response, bool):
        return response
    raise RuntimeError("device returned no numeric MIoT value")


def _read_optional(device: Any, siid: int, piid: int) -> Any | None:
    try:
        return _property_value(device.get_property_by(siid, piid))
    except Exception:
        return None


def setup_from_cloud(path: Path) -> int:
    """Fetch the account device list without displaying any device tokens."""
    try:
        from miio.cloud import CloudInterface
    except ImportError:
        print("python-miio cloud support is unavailable", file=sys.stderr)
        return 1

    preferred_ip = ""
    if path.exists():
        try:
            saved = json.loads(path.read_text(encoding="utf-8"))
            preferred_ip = str(saved.get("ip", "")) if isinstance(saved, dict) else ""
        except (OSError, json.JSONDecodeError):
            pass

    try:
        username = input("Xiaomi account username: ").strip()
        password = getpass.getpass("Xiaomi account password (hidden): ")
    except EOFError:
        print("Cloud setup needs an interactive terminal", file=sys.stderr)
        return 1
    try:
        devices = CloudInterface(username=username, password=password).get_devices()
    except Exception as exc:
        if exc.__class__.__name__ == "CloudException":
            print(
                "Xiaomi's legacy password login did not return a device list. "
                "This may be a rejected login or a Xiaomi CAPTCHA/security-verification "
                "challenge that python-miio's micloud flow cannot complete. The password "
                "was not saved. Use a local Mi Home token export instead of repeatedly "
                "retrying the login.",
                file=sys.stderr,
            )
        else:
            print(f"Cloud device lookup failed ({exc.__class__.__name__})", file=sys.stderr)
        return 1

    matches = [d for d in devices.values() if d.model == MODEL and not d.is_child]
    if preferred_ip:
        matches = [d for d in matches if d.ip == preferred_ip]
    if len(matches) != 1:
        print(
            f"Expected one {MODEL} matching IP {preferred_ip or '(any)'}, found {len(matches)}.",
            file=sys.stderr,
        )
        if matches:
            print("Matching device IPs: " + ", ".join(d.ip or "unknown" for d in matches), file=sys.stderr)
        return 1

    dev = matches[0]
    extra = dev.raw_data.get("extra") or {}
    config = {
        "model": MODEL,
        "ip": dev.ip,
        "token": dev.token,
        "did": dev.did,
        "firmware": extra.get("fw_version"),
        "timeout": 5,
    }
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)
    password = ""
    print(f"Saved {MODEL} config for {dev.ip}; token was stored locally and not displayed.")
    return 0


def setup_from_local_export(path: Path, source: Path) -> int:
    """Import a matching token from a Mi Home SQLite export or Android .ab backup."""
    try:
        from miio.extract_tokens import BackupDatabaseReader

        preferred_ip = ""
        if path.exists():
            try:
                saved = json.loads(path.read_text(encoding="utf-8"))
                preferred_ip = str(saved.get("ip", "")) if isinstance(saved, dict) else ""
            except (OSError, json.JSONDecodeError):
                pass

        if source.suffix.lower() == ".ab":
            from android_backup import AndroidBackup

            backup_password = getpass.getpass("Android backup password (hidden; Enter if none): ")
            with AndroidBackup(str(source), stream=False) as backup:
                archive = backup.read_data(backup_password or None)
                database = archive.extractfile("apps/com.xiaomi.smarthome/db/miio2.db")
                if database is None:
                    raise ValueError("Mi Home database is missing from the Android backup")
                with tempfile.NamedTemporaryFile(suffix=".sqlite") as db_file:
                    db_file.write(database.read())
                    db_file.flush()
                    devices = list(BackupDatabaseReader().read_tokens(db_file.name))
        else:
            devices = list(BackupDatabaseReader().read_tokens(str(source)))

        matches = [d for d in devices if d.model == MODEL and (not preferred_ip or d.ip == preferred_ip)]
        if len(matches) != 1:
            print(
                f"Expected one {MODEL} matching IP {preferred_ip or '(any)'}, found {len(matches)}.",
                file=sys.stderr,
            )
            if matches:
                print("Matching device IPs: " + ", ".join(d.ip or "unknown" for d in matches), file=sys.stderr)
            return 1

        dev = matches[0]
        config = {"model": MODEL, "ip": dev.ip, "token": dev.token, "timeout": 5}
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)
        print(f"Saved {MODEL} config for {dev.ip}; token was stored locally and not displayed.")
        return 0
    except Exception as exc:
        print(f"Local token import failed ({exc.__class__.__name__})", file=sys.stderr)
        return 1


def setup_from_qr_extractor(path: Path) -> int:
    """Use the QR-capable open-source extractor, redact token output, save match."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    if not shutil.which("git"):
        print("git is required for the QR token setup", file=sys.stderr)
        return 1
    try:
        import colorama  # noqa: F401
        import PIL  # noqa: F401
    except ImportError:
        print(
            "QR setup dependencies are missing; run: .venv/bin/python -m pip install colorama Pillow",
            file=sys.stderr,
        )
        return 1

    preferred_ip = ""
    if path.exists():
        try:
            saved = json.loads(path.read_text(encoding="utf-8"))
            preferred_ip = str(saved.get("ip", "")) if isinstance(saved, dict) else ""
        except (OSError, json.JSONDecodeError):
            pass

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route_sock:
            # UDP connect selects the route without sending a packet. Use a
            # documentation-safe address when no plug IP has been configured.
            route_sock.connect((preferred_ip or "192.0.2.1", 54321))
            host_ip = route_sock.getsockname()[0]
    except OSError:
        host_ip = "127.0.0.1"

    repo_url = "https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor.git"
    pinned_commit = "c4db715dace9806e905153c2977608873e8ab7c9"
    ansi_re = re.compile(r"\x1b\[[0-9;]*m")

    try:
        with tempfile.TemporaryDirectory(prefix="xiaomi-power-qr-", dir=path.parent) as workdir:
            repo = Path(workdir) / "extractor"
            clone = subprocess.run(
                ["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", repo_url, str(repo)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if clone.returncode:
                raise RuntimeError("could not fetch the QR extractor")
            fetch = subprocess.run(
                ["git", "-C", str(repo), "fetch", "--quiet", "--depth", "1", "origin", pinned_commit],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if fetch.returncode:
                raise RuntimeError("could not fetch the pinned QR extractor revision")
            checkout = subprocess.run(
                ["git", "-C", str(repo), "checkout", "--quiet", "--detach", pinned_commit],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if checkout.returncode:
                raise RuntimeError("could not select the pinned QR extractor revision")

            output_file = Path(workdir) / "devices.json"
            command = [
                sys.executable,
                "-u",
                str(repo / "token_extractor.py"),
                "--host",
                host_ip,
                "--output",
                str(output_file),
            ]
            print("Starting Xiaomi QR login. Choose 'q' at the login method prompt.")
            print("Open the displayed local URL in a browser on this PC; scan it with Mi Home on Android and approve.")
            child = subprocess.Popen(
                command,
                stdin=sys.stdin,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert child.stdout is not None
            for line in child.stdout:
                plain = ansi_re.sub("", line)
                if re.search(r"\bTOKEN\s*:", plain, flags=re.IGNORECASE):
                    continue
                if re.search(r"\b(BLE KEY|MAC|ID|NAME|IP|MODEL)\s*:", plain, flags=re.IGNORECASE):
                    continue
                if "Devices found for server" in plain or "No devices found for server" in plain:
                    continue
                if "longPolling/login?" in plain or "ticket=" in plain:
                    continue
                sys.stdout.write(line)
                sys.stdout.flush()
            if child.wait() != 0 or not output_file.exists():
                print("QR login did not produce a device list", file=sys.stderr)
                return 1

            listing = json.loads(output_file.read_text(encoding="utf-8"))
            devices = [
                device
                for home in listing
                for section in home.get("homes", [])
                for device in section.get("devices", [])
                if device.get("model") == MODEL
                and (not preferred_ip or device.get("localip") == preferred_ip)
            ]
            unique = {str(d.get("did")): d for d in devices}
            matches = list(unique.values())
            if len(matches) != 1:
                print(
                    f"Expected one {MODEL} matching IP {preferred_ip or '(any)'}, found {len(matches)}.",
                    file=sys.stderr,
                )
                if matches:
                    print("Matching IPs: " + ", ".join(str(d.get("localip") or "unknown") for d in matches), file=sys.stderr)
                return 1

            device = matches[0]
            config = {
                "model": MODEL,
                "ip": device.get("localip") or preferred_ip,
                "token": device["token"],
                "did": str(device.get("did", "")),
                "firmware": (device.get("extra") or {}).get("fw_version"),
                "timeout": 5,
            }
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            path.chmod(stat.S_IRUSR | stat.S_IWUSR)
            print(f"Saved {MODEL} config for {config['ip']}; token was not displayed.")
            return 0
    except Exception as exc:
        print(f"QR token setup failed ({exc.__class__.__name__})", file=sys.stderr)
        return 1


def read_power(
    config: dict[str, Any], include_details: bool = False, include_energy: bool = False
) -> dict[str, Any]:
    if MiotDevice is None:
        raise RuntimeError("python-miio is unavailable; install it in the project .venv")

    device = MiotDevice(
        ip=config["ip"],
        token=config["token"],
        model=MODEL,
        timeout=int(config.get("timeout", 5)),
        lazy_discover=False,
    )
    try:
        raw_power = device.get_property_by(POWER_SIID, POWER_PIID)
    except Exception as exc:
        raise RuntimeError(
            f"LAN MIoT read failed ({exc.__class__.__name__}); check device IP, token, "
            "and whether LAN access is enabled"
        ) from None

    try:
        power = float(_property_value(raw_power))
    except (TypeError, ValueError, RuntimeError) as exc:
        raise RuntimeError(f"Invalid electric-power response: {exc}") from None
    if not math.isfinite(power) or power < 0:
        raise RuntimeError("Device returned an invalid power value")

    result: dict[str, Any] = {
        "model": MODEL,
        "power": power,
        "unit": "W",
        "available": True,
    }

    # MIoT service 11 / property 1 is accumulated energy in 0.01 kWh steps.
    if include_energy:
        energy_raw = _read_optional(device, ENERGY_SIID, ENERGY_PIID)
        if energy_raw is not None:
            result["energy_kwh"] = float(energy_raw) * 0.01

    if include_details:
        try:
            info = device.info(skip_cache=True)
            result["device_info"] = {
                "ip": config["ip"],
                "model": getattr(info, "model", None) or MODEL,
                "firmware": getattr(info, "firmware_version", None),
                "device_id": config.get("did") or getattr(info, "device_id", None),
            }
        except Exception:
            result["device_info"] = {
                "ip": config["ip"],
                "model": MODEL,
                "firmware": config.get("firmware"),
                "device_id": config.get("did"),
            }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Read cuco.plug.v3 live power over LAN")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    parser.add_argument("--info", action="store_true", help="also query device id and firmware")
    parser.add_argument("--energy", action="store_true", help="also query accumulated energy")
    parser.add_argument(
        "--setup-cloud",
        action="store_true",
        help="securely fetch this device's token from your Xiaomi account and save it locally",
    )
    parser.add_argument(
        "--import-token-source",
        type=Path,
        metavar="FILE",
        help="import the device token from a Mi Home SQLite export or Android .ab backup",
    )
    parser.add_argument(
        "--setup-cloud-qr",
        action="store_true",
        help="get the device token via Xiaomi QR login without printing tokens",
    )
    args = parser.parse_args()

    path = config_path()
    if args.import_token_source:
        return setup_from_local_export(path, args.import_token_source)
    if args.setup_cloud_qr:
        return setup_from_qr_extractor(path)
    if args.setup_cloud:
        return setup_from_cloud(path)

    try:
        if path.exists():
            # Keep stored credentials private even if the file was created too openly.
            path.chmod(stat.S_IRUSR | stat.S_IWUSR)
        config = load_config(path)
        result = read_power(config, include_details=args.info, include_energy=args.energy)
    except Exception as exc:
        if args.json:
            print(json.dumps({"model": MODEL, "power": None, "unit": "W", "available": False,
                              "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"xiaomi_power: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(f"Device: {MODEL}")
        print(f"Power: {result['power']:.1f} W")
        if "energy_kwh" in result:
            print(f"Energy: {result['energy_kwh']:.2f} kWh")
        if args.info and result.get("device_info"):
            info = result["device_info"]
            print(f"IP: {info.get('ip') or config['ip']}")
            print(f"Firmware: {info.get('firmware') or 'unknown'}")
            print(f"Device ID: {info.get('device_id') or 'unknown'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
