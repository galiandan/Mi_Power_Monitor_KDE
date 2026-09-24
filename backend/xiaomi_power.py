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
import webbrowser
from pathlib import Path
from typing import Any, Callable

MODEL = "cuco.plug.v3"
POWER_SIID = 11
POWER_PIID = 2
ENERGY_SIID = 11
ENERGY_PIID = 1


def _localized(chinese: str, english: str, stream: Any | None = None) -> str:
    """Prefer Chinese prompts when the active terminal encoding can display them."""
    stream = stream or sys.stdout
    encoding = getattr(stream, "encoding", None) or "utf-8"
    try:
        chinese.encode(encoding)
    except (LookupError, UnicodeEncodeError):
        return english
    return chinese


def _say(chinese: str, english: str, *, file: Any | None = None) -> None:
    print(_localized(chinese, english, file), file=file)


def _ask(chinese: str, english: str) -> str:
    return input(_localized(chinese, english))


def _open_login_url(url: str) -> bool:
    """Best-effort launch of the local QR login page in the desktop browser."""
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return False
    opener = shutil.which("xdg-open")
    try:
        if opener:
            subprocess.Popen(
                [opener, url],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return True
        return webbrowser.open(url, new=2)
    except (OSError, webbrowser.Error):
        return False


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
            _localized(f"找不到配置文件：{path}", f"Missing config: {path}")
            + "\n"
            + _localized(
                "请运行二维码扫码配置，或将 config.example.json 复制到该位置并填写插座 IP 和 token。",
                "Run QR setup, or copy config.example.json to that path and fill in the device IP and token.",
            )
        )

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(_localized(
            f"无法读取配置文件 {path}：{exc.__class__.__name__}。",
            f"Cannot read JSON config at {path}: {exc.__class__.__name__}.",
        )) from None

    if not isinstance(data, dict):
        raise ValueError(_localized("配置文件必须是 JSON 对象。", "Config must be a JSON object."))
    if data.get("model", MODEL) != MODEL:
        raise ValueError(_localized(f"配置中的 model 必须是 {MODEL}。", f"Config model must be {MODEL}."))
    for required in ("ip", "token"):
        if not isinstance(data.get(required), str) or not data[required].strip():
            raise ValueError(_localized(
                f"配置缺少非空字段“{required}”。",
                f"Config is missing a non-empty '{required}' field.",
            ))
    token = data["token"].strip()
    if token.startswith("REPLACE_") or token.lower() in {"your_token", "token"}:
        raise ValueError(_localized(
            "请将示例 token 替换为此插座的 32 位 token。",
            "Replace the example token with this device's 32-character token.",
        ))
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


def _device_label(device: Any, ip: str) -> str:
    if isinstance(device, dict):
        name = str(device.get("name") or "").strip()
        did = str(device.get("did") or "").strip()
    else:
        name = str(getattr(device, "name", "") or "").strip()
        did = str(getattr(device, "did", "") or "").strip()

    label = f"IP {ip or 'unknown'}"
    if name:
        label += f" — {name}"
    if did:
        label += f" (ID …{did[-4:]})"
    return label


def _select_device(matches: list[Any], get_ip: Callable[[Any], str]) -> Any | None:
    if not matches:
        _say(f"没有找到 {MODEL} 插座。", f"No {MODEL} devices were found.", file=sys.stderr)
        return None
    if len(matches) == 1:
        return matches[0]

    _say(f"找到 {len(matches)} 台 {MODEL} 插座，请选择要配置的设备：",
         f"Found {len(matches)} {MODEL} devices:")
    for index, device in enumerate(matches, start=1):
        print(f"  {index}. {_device_label(device, get_ip(device))}")

    while True:
        try:
            answer = input(_localized(
                f"请输入要配置的插座编号 [1-{len(matches)}；输入 q 取消]：",
                f"Select the plug to configure [1-{len(matches)}; q to cancel]: ",
            )).strip()
        except EOFError:
            answer = "q"
        if answer.lower() in {"q", "quit", "cancel"}:
            _say("已取消设备选择。", "Device selection cancelled.", file=sys.stderr)
            return None
        if answer.isdecimal() and 1 <= int(answer) <= len(matches):
            return matches[int(answer) - 1]
        _say(f"请输入 1 到 {len(matches)} 之间的编号，或输入 q 取消。",
             f"Enter a number from 1 to {len(matches)}, or q to cancel.", file=sys.stderr)


def setup_from_cloud(path: Path) -> int:
    """Fetch the account device list without displaying any device tokens."""
    try:
        from miio.cloud import CloudInterface
    except ImportError:
        _say("当前 Python 环境没有安装 python-miio 云端组件。",
             "python-miio cloud support is unavailable.", file=sys.stderr)
        return 1

    preferred_ip = ""
    if path.exists():
        try:
            saved = json.loads(path.read_text(encoding="utf-8"))
            preferred_ip = str(saved.get("ip", "")) if isinstance(saved, dict) else ""
        except (OSError, json.JSONDecodeError):
            pass

    try:
        username = _ask("小米账号：", "Xiaomi account username: ").strip()
        password = getpass.getpass(
            _localized(
                "小米账号密码（输入内容不会显示）：",
                "Xiaomi account password (hidden): ",
                sys.stderr,
            )
        )
    except EOFError:
        _say("账号配置需要交互式终端。", "Cloud setup needs an interactive terminal.", file=sys.stderr)
        return 1
    try:
        devices = CloudInterface(username=username, password=password).get_devices()
    except Exception as exc:
        if exc.__class__.__name__ == "CloudException":
            print(
                _localized(
                    "小米旧版密码登录未返回设备列表，可能是登录被拒绝或触发了验证码/安全验证；当前登录流程无法完成该验证。密码没有保存。建议改用二维码扫码登录，或导入本地米家 token 备份，不要反复尝试密码登录。",
                    "Xiaomi's legacy password login did not return a device list. This may be a rejected login or a CAPTCHA/security challenge that python-miio cannot complete. The password was not saved. Use QR sign-in or import a local Mi Home token backup instead of repeatedly retrying password login.",
                ),
                file=sys.stderr,
            )
        else:
            _say(f"查询小米云端设备失败（{exc.__class__.__name__}）。",
                 f"Cloud device lookup failed ({exc.__class__.__name__}).", file=sys.stderr)
        return 1

    matches = [d for d in devices.values() if d.model == MODEL and not d.is_child]
    if preferred_ip:
        matches = [d for d in matches if d.ip == preferred_ip]
    dev = _select_device(matches, lambda device: str(device.ip or ""))
    if dev is None:
        return 1
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
    _say(f"已保存 {MODEL} 配置（{dev.ip}）；token 仅保存在本机，不会显示。",
         f"Saved {MODEL} config for {dev.ip}; token was stored locally and not displayed.")
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

            backup_password = getpass.getpass(_localized(
                "Android 备份密码（输入内容不会显示；没有密码请直接回车）：",
                "Android backup password (hidden; Enter if none): ",
                sys.stderr,
            ))
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
        dev = _select_device(matches, lambda device: str(device.ip or ""))
        if dev is None:
            return 1
        config = {"model": MODEL, "ip": dev.ip, "token": dev.token, "timeout": 5}
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)
        _say(f"已保存 {MODEL} 配置（{dev.ip}）；token 仅保存在本机，不会显示。",
             f"Saved {MODEL} config for {dev.ip}; token was stored locally and not displayed.")
        return 0
    except Exception as exc:
        _say(f"导入本地 token 失败（{exc.__class__.__name__}）。",
             f"Local token import failed ({exc.__class__.__name__}).", file=sys.stderr)
        return 1


def setup_from_qr_extractor(path: Path) -> int:
    """Use the QR-capable open-source extractor, redact token output, save match."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    if not shutil.which("git"):
        _say("二维码扫码配置需要 git，请先安装 git。",
             "git is required for QR token setup; install git first.", file=sys.stderr)
        return 1
    try:
        import colorama  # noqa: F401
        import PIL  # noqa: F401
    except ImportError:
        print(
            _localized(
                "缺少二维码配置依赖，请运行：.venv/bin/python -m pip install colorama Pillow",
                "QR setup dependencies are missing; run: .venv/bin/python -m pip install colorama Pillow",
            ),
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
            _say(
                "即将开始米家登录。推荐使用二维码：出现登录方式时请输入 q；扫码后请在米家 App 中确认。",
                "Starting Xiaomi login. QR code sign-in is recommended: enter q when asked for a login method, then scan and approve in Mi Home.",
            )
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

                ending = "\n" if line.endswith("\n") else ""
                prompt = plain.strip()
                translations = {
                    "Xiaomi Cloud": ("小米云端登录", "Xiaomi Cloud"),
                    "Please select a way to log in:": ("请选择登录方式：", "Please select a way to log in:"),
                    "p - using password": ("p - 使用密码登录（不推荐）", "p - using password"),
                    "q - using QR code": ("q - 使用二维码登录（推荐）", "q - using QR code"),
                    "p/q:": ("请输入 p 或 q（推荐 q）：", "p/q:"),
                    "Please scan the following QR code to log in.": (
                        "请用米家 App 扫描下方二维码并确认登录。",
                        "Please scan the following QR code to log in.",
                    ),
                    "Alternatively you can visit the following URL:": (
                        "如果二维码无法使用，请在浏览器中打开上方本机网址：",
                        "Alternatively you can visit the following URL:",
                    ),
                    "Logged in.": ("登录成功，正在读取设备列表。", "Logged in."),
                    "Press ENTER to finish": ("按回车键完成配置。", "Press ENTER to finish"),
                }
                server_match = re.match(r"Select server \((.*)\):", prompt)
                url_match = re.search(r"QR code URL:\s*(https?://\S+)", plain)
                if url_match:
                    url = url_match.group(1).rstrip(".,)")
                    _say(f"二维码登录网址：{url}", f"QR code URL: {url}")
                    opened = _open_login_url(url)
                    if opened:
                        _say("已尝试在本机默认浏览器中打开登录页面；如果没有弹出，请手动访问上方网址。",
                             "Tried to open the login page in the default browser. If it did not open, visit the URL above manually.")
                    else:
                        _say("无法自动打开浏览器，请在本机浏览器中访问上方网址。",
                             "Could not open a browser automatically. Visit the URL above in a browser on this computer.")
                    _say("页面打开后，请用手机米家 App 扫描终端显示的二维码并确认登录。",
                         "After opening the page, scan the QR code shown in the terminal with Mi Home and approve the login.")
                    continue
                if server_match:
                    server_options = re.sub(r"^one of:\s*", "可选：", server_match.group(1))
                    translated = (
                        f"请选择小米服务器（{server_options}；留空自动检查）：",
                        f"Select server ({server_match.group(1)}):",
                    )
                else:
                    translated = translations.get(prompt)
                if translated:
                    sys.stdout.write(_localized(*translated) + ending)
                else:
                    sys.stdout.write(line)
                sys.stdout.flush()
            if child.wait() != 0 or not output_file.exists():
                _say("二维码登录未能获取设备列表。请确认已在手机上批准登录后重试。",
                     "QR login did not produce a device list. Make sure you approved the sign-in on your phone, then retry.",
                     file=sys.stderr)
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
            device = _select_device(matches, lambda item: str(item.get("localip") or ""))
            if device is None:
                return 1
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
            _say(f"已保存 {MODEL} 配置（{config['ip']}）；token 仅保存在本机，不会显示。",
                 f"Saved {MODEL} config for {config['ip']}; token was stored locally and not displayed.")
            return 0
    except Exception as exc:
        _say(f"二维码配置失败（{exc.__class__.__name__}）。",
             f"QR token setup failed ({exc.__class__.__name__}).", file=sys.stderr)
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
    parser = argparse.ArgumentParser(
        description=_localized(
            "通过局域网读取米家智能插座 3 的实时功率",
            "Read live power from a Xiaomi smart plug 3 over LAN",
        )
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help=_localized("输出机器可读的 JSON", "print machine-readable JSON"),
    )
    parser.add_argument(
        "--info",
        action="store_true",
        help=_localized("同时查询设备 ID 和固件版本", "also query device ID and firmware"),
    )
    parser.add_argument(
        "--energy",
        action="store_true",
        help=_localized("同时查询累计用电量", "also query accumulated energy"),
    )
    parser.add_argument(
        "--setup-cloud",
        action="store_true",
        help=_localized(
            "从小米账号获取此设备的 token 并安全保存在本机（推荐扫码方式）",
            "fetch this device's token from your Xiaomi account and save it locally (QR sign-in recommended)",
        ),
    )
    parser.add_argument(
        "--import-token-source",
        type=Path,
        metavar="FILE",
        help=_localized(
            "从米家 SQLite 导出文件或 Android .ab 备份导入设备 token",
            "import the device token from a Mi Home SQLite export or Android .ab backup",
        ),
    )
    parser.add_argument(
        "--setup-cloud-qr",
        action="store_true",
        help=_localized(
            "通过推荐的二维码登录获取设备 token；token 不会显示",
            "get the device token via recommended Xiaomi QR sign-in without printing tokens",
        ),
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
