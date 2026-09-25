import importlib.util
import json
import fcntl
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "read-readings.py"
SPEC = importlib.util.spec_from_file_location("read_readings", SCRIPT)
read_readings = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(read_readings)


class SnapshotContractTests(unittest.TestCase):
    def test_unavailable_sources_are_null_and_have_a_stable_schema(self):
        result = read_readings.create_snapshot({}, {}, None, None, None)
        encoded = json.dumps(result, allow_nan=False)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["status"], "backend-missing")
        self.assertIsNone(decoded["total_power"])
        self.assertIsNone(decoded["cpu_power"])
        self.assertIsNone(decoded["gpu_power"])
        for key in (
            "total_power",
            "cpu_power",
            "gpu_power",
            "total_sampled_at",
            "cpu_sampled_at",
            "gpu_sampled_at",
            "status",
            "snapshot_at",
            "snapshot_sequence",
        ):
            self.assertIn(key, decoded)

    def test_invalid_numeric_values_do_not_become_partial_readings(self):
        result = read_readings.create_snapshot(
            {"cpu_power": float("nan"), "gpu_power": 30.0},
            {"available": False, "error": "invalid JSON config"},
            1.0,
            None,
            "/usr/bin/xiaomi-power",
        )
        self.assertEqual(result["status"], "unconfigured")
        self.assertIsNone(result["cpu_power"])
        self.assertEqual(result["gpu_power"], 30.0)
        self.assertIsNone(result["total_power"])

    def test_overlapping_poll_cycles_return_without_starting_more_workers(self):
        with tempfile.TemporaryDirectory() as runtime_dir:
            with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime_dir}):
                first = read_readings.acquire_cycle_lock()
                self.assertIsNotNone(first)
                self.assertIsNone(read_readings.acquire_cycle_lock())
                fcntl.flock(first, fcntl.LOCK_UN)
                os.close(first)
                second = read_readings.acquire_cycle_lock()
                self.assertIsNotNone(second)
                fcntl.flock(second, fcntl.LOCK_UN)
                os.close(second)


if __name__ == "__main__":
    unittest.main()
