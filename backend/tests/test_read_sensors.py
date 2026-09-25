import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "read-sensors.py"
SPEC = importlib.util.spec_from_file_location("read_sensors", SCRIPT)
read_sensors = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(read_sensors)


class FakeClock:
    def __init__(self):
        self.now_ns = 0

    def monotonic_ns(self):
        return self.now_ns

    def sleep(self, seconds):
        self.now_ns += int(seconds * 1_000_000_000)


def add_domain(root: Path, index: int, name: str, energy: int) -> Path:
    domain = root / f"intel-rapl:{index}"
    domain.mkdir()
    (domain / "name").write_text(name)
    (domain / "energy_uj").write_text(str(energy))
    (domain / "max_energy_range_uj").write_text("1000000000")
    return domain


class RaplSamplingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.clock = FakeClock()
        self.suspend_ns = 0

    def tearDown(self):
        self.temp.cleanup()

    def sample(self, interval=1.0, update=None):
        def sleep(seconds):
            self.clock.sleep(seconds)
            if update:
                update()

        return read_sensors.sample_cpu(
            self.root,
            interval,
            sleep=sleep,
            monotonic_ns=self.clock.monotonic_ns,
            suspend_offset_ns=lambda: self.suspend_ns,
            wall_time=lambda: 1234.0,
        )

    def test_uses_actual_elapsed_time_when_sampling_is_delayed(self):
        package = add_domain(self.root, 0, "package-0", 1_000_000)

        def update():
            (package / "energy_uj").write_text("41000000")

        power, sampled_at = self.sample(2.0, update)
        self.assertAlmostEqual(power, 20.0)
        self.assertEqual(sampled_at, 1234.0)

    def test_ignores_psys_and_sums_multiple_packages(self):
        first = add_domain(self.root, 0, "package-0", 0)
        add_domain(self.root, 1, "psys", 0)
        second = add_domain(self.root, 2, "package-1", 0)

        def update():
            (first / "energy_uj").write_text("20000000")
            (self.root / "intel-rapl:1" / "energy_uj").write_text("80000000")
            (second / "energy_uj").write_text("30000000")

        power, _ = self.sample(1.0, update)
        self.assertAlmostEqual(power, 50.0)

    def test_zero_is_available_but_partial_or_invalid_samples_are_not(self):
        package = add_domain(self.root, 0, "package-0", 100)
        power, _ = self.sample(1.0)
        self.assertEqual(power, 0.0)

        (package / "energy_uj").write_text("invalid")
        power, _ = self.sample(1.0)
        self.assertIsNone(power)

    def test_failure_during_second_read_is_unavailable(self):
        package = add_domain(self.root, 0, "package-0", 100)
        original = read_sensors.read_integer
        energy_reads = 0

        def fail_second_energy_read(path):
            nonlocal energy_reads
            if path == package / "energy_uj":
                energy_reads += 1
                if energy_reads == 2:
                    return None
            return original(path)

        with mock.patch.object(read_sensors, "read_integer", side_effect=fail_second_energy_read):
            power, _ = self.sample(1.0)
        self.assertIsNone(power)

    def test_counter_decrease_is_unavailable_instead_of_wrapped(self):
        package = add_domain(self.root, 0, "package-0", 1000)

        def update():
            (package / "energy_uj").write_text("10")

        power, _ = self.sample(1.0, update)
        self.assertIsNone(power)

    def test_suspend_during_sample_discards_the_ambiguous_window(self):
        package = add_domain(self.root, 0, "package-0", 0)

        def update():
            self.suspend_ns += 1_000_000_000
            (package / "energy_uj").write_text("20000000")

        power, sampled_at = self.sample(1.0, update)
        self.assertIsNone(power)
        self.assertIsNone(sampled_at)

    def test_all_expected_packages_must_be_readable(self):
        add_domain(self.root, 0, "package-0", 0)
        second = add_domain(self.root, 1, "package-1", 0)
        (second / "max_energy_range_uj").write_text("invalid")
        power, _ = self.sample(1.0)
        self.assertIsNone(power)

    def test_gpu_values_must_be_complete(self):
        result = mock.Mock(returncode=0, stdout="120.0\nN/A\n")
        with mock.patch.object(read_sensors.subprocess, "run", return_value=result):
            power, sampled_at = read_sensors.read_gpu()
        self.assertIsNone(power)
        self.assertIsNone(sampled_at)


if __name__ == "__main__":
    unittest.main()
