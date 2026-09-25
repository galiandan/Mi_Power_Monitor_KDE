import importlib.util
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "xiaomi_power.py"
SPEC = importlib.util.spec_from_file_location("xiaomi_power", SCRIPT)
xiaomi_power = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(xiaomi_power)


class ConfigStorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "xiaomi-power" / "config.json"
        self.config = {
            "model": "cuco.plug.v3",
            "ip": "192.168.10.100",
            "token": "0123456789abcdef0123456789abcdef",
            "timeout": 5,
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_save_creates_private_valid_config(self):
        xiaomi_power.save_config(self.path, self.config)
        self.assertEqual(xiaomi_power.load_config(self.path)["ip"], self.config["ip"])
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)

    def test_invalid_config_does_not_replace_previous_contents(self):
        xiaomi_power.save_config(self.path, self.config)
        original = self.path.read_bytes()
        invalid = dict(self.config, token="REPLACE_WITH_DEVICE_TOKEN")
        with self.assertRaises(ValueError):
            xiaomi_power.save_config(self.path, invalid)
        self.assertEqual(self.path.read_bytes(), original)

    def test_replace_failure_keeps_old_config_and_removes_temp_file(self):
        xiaomi_power.save_config(self.path, self.config)
        original = self.path.read_bytes()
        updated = dict(self.config, ip="192.168.10.101")
        with mock.patch.object(xiaomi_power.os, "replace", side_effect=OSError("simulated")):
            with self.assertRaises(OSError):
                xiaomi_power.save_config(self.path, updated)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(list(self.path.parent.glob(".config.json.*.tmp")), [])

    def test_serialization_and_file_sync_failures_keep_old_config(self):
        xiaomi_power.save_config(self.path, self.config)
        original = self.path.read_bytes()
        for operation, target in (("serialize", xiaomi_power.json), ("sync", xiaomi_power.os)):
            with self.subTest(operation=operation):
                function = "dump" if operation == "serialize" else "fsync"
                with mock.patch.object(target, function, side_effect=OSError("simulated")):
                    with self.assertRaises(OSError):
                        xiaomi_power.save_config(self.path, dict(self.config, ip="192.168.10.101"))
                self.assertEqual(self.path.read_bytes(), original)
                self.assertEqual(list(self.path.parent.glob(".config.json.*.tmp")), [])

    def test_loader_rejects_non_ip_and_out_of_range_timeout(self):
        self.path.parent.mkdir(mode=0o700)
        invalid = dict(self.config, ip="plug.local", timeout=61)
        self.path.write_text(json.dumps(invalid), encoding="utf-8")
        with self.assertRaises(ValueError):
            xiaomi_power.load_config(self.path)

    def test_save_replaces_config_symlink_without_touching_target(self):
        target = self.path.parent / "target.json"
        xiaomi_power.save_config(target, self.config)
        link = self.path.parent / "config.json"
        link.symlink_to(target)
        original = target.read_bytes()
        xiaomi_power.save_config(link, dict(self.config, ip="192.168.10.101"))
        self.assertFalse(link.is_symlink())
        self.assertEqual(xiaomi_power.load_config(link)["ip"], "192.168.10.101")
        self.assertEqual(target.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
