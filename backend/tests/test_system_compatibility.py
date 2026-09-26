"""Regression tests use temporary files, never real sudo grants or sysfs writes."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
HELPER = (ROOT / 'setup-rapl-access.sh').read_text()


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'backend' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sensors = load('compat_sensors', 'read-sensors.py')
readings = load('compat_readings', 'read-readings.py')


class CompatibilityTests(unittest.TestCase):
    def test_disabled_sensors_never_start_queries(self):
        with mock.patch.object(sensors, 'read_gpu') as gpu, mock.patch.object(sensors, 'sample_cpu') as cpu:
            result = sensors.collect(Path('/nonexistent'), 1, cpu=False, gpu=False)
        gpu.assert_not_called()
        cpu.assert_not_called()
        self.assertIsNone(result['gpu_power'])

    def test_sleeping_gpu_is_not_queried(self):
        with mock.patch.object(sensors, 'nvidia_suspended', return_value=True), mock.patch.object(sensors.subprocess, 'run') as run:
            self.assertEqual(sensors.read_gpu(), (None, None))
        run.assert_not_called()

    def test_runtime_pm_checks_only_nvidia_display_devices(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dev = root / '0000:01:00.0'
            (dev / 'power').mkdir(parents=True)
            (dev / 'vendor').write_text('0x10de\n')
            (dev / 'class').write_text('0x030200\n')
            (dev / 'power/runtime_status').write_text('suspended\n')
            self.assertTrue(sensors.nvidia_suspended(root))
            (dev / 'power/runtime_status').write_text('active\n')
            self.assertFalse(sensors.nvidia_suspended(root))

    def test_collector_skips_sensor_process_when_disabled(self):
        with mock.patch.object(readings, 'backend_command', return_value=None), mock.patch.object(readings, 'read_json') as read:
            result = readings.collect(cpu=False, gpu=False)
        read.assert_not_called()
        self.assertIsNone(result['cpu_power'])

    def test_shell_panel_command_passes_disable_flags(self):
        line = next(l for l in (ROOT / 'package/contents/ui/main.qml').read_text().splitlines() if 'readonly property string readingsCommand:' in l)
        command = json.loads(line.split(': ', 1)[1])
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / '.local/bin/mi-power-monitor-readings'
            exe.parent.mkdir(parents=True)
            exe.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            exe.chmod(0o755)
            result = subprocess.run(command + ' --no-cpu --no-gpu', shell=True, env={**os.environ, 'HOME': tmp}, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), ['--no-cpu', '--no-gpu'])

    def test_sudoers_grants_only_fixed_command_without_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            grant = Path(tmp) / 'grant'
            grant.write_text('# Managed test\n#1000 ALL=(root) NOPASSWD: NOSETENV: /usr/local/libexec/mi-power-monitor/read-rapl ""\nDefaults!/usr/local/libexec/mi-power-monitor/read-rapl !log_allowed, !pam_session, !pam_setcred\n')
            result = subprocess.run(['visudo', '-cf', str(grant)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_broker_rejects_arguments(self):
        source = HELPER.split("<<'READER'\n", 1)[1].split('\nREADER', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'reader'
            script.write_text(source)
            result = subprocess.run(['/usr/bin/python3', '-I', str(script), '/etc/shadow'], capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b'')

    def test_legacy_migration_preserves_drift_and_restores_owned_changes(self):
        source = HELPER.split("<<'MIGRATE'\n", 1)[1].split('\nMIGRATE', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            counter = root / 'energy_uj'
            counter.write_text('123')
            rule, state, owner = [root / n for n in ('rule', 'state', 'owner')]
            rule.write_text('legacy')
            state.write_text(f'644 {os.getuid()} {os.getgid()} {counter}\n')
            owner.write_text(f'{os.getuid()}:{os.getgid()}:desktop\n')
            source = source.replace("'/sys/devices/'", repr(str(root) + '/'))
            script = root / 'migrate.py'
            script.write_text(source)
            args = ['/usr/bin/python3', str(script), str(rule), str(state), str(owner), str(os.getuid())]
            counter.chmod(0o600)
            failed = subprocess.run(args, capture_output=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(counter.stat().st_mode & 0o777, 0o600)
            self.assertTrue(rule.exists())
            counter.chmod(0o400)
            ok = subprocess.run(args, capture_output=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertEqual(counter.stat().st_mode & 0o777, 0o644)
            self.assertFalse(rule.exists())
            self.assertFalse(state.exists())

    def test_kde_install_preserves_standalone_backend_and_shared_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            tools = home / 'tools'
            tools.mkdir()
            stubs = {
                'go': '''#!/bin/sh
case "$1" in
 env) echo go1.25.0 ;;
 version) echo 'go version go1.25.0' ;;
 build) printf '#!/bin/sh\\nexit 0\\n' > xiaomi-power; chmod +x xiaomi-power ;;
esac
''',
                'kpackagetool6': '#!/bin/sh\nexit 0\n',
                'qdbus6': '#!/bin/sh\nexit 0\n',
            }
            for name, source in stubs.items():
                exe = tools / name
                exe.write_text(source)
                exe.chmod(0o755)
            data = home / '.local/share'
            standalone = data / 'xiaomi-power/versions/v1'
            standalone.mkdir(parents=True)
            binary = standalone / 'xiaomi-power'
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
            bindir = home / '.local/bin'
            bindir.mkdir(parents=True)
            alias = bindir / 'xiaomi-power'
            alias.symlink_to(binary)
            config = home / '.config/xiaomi-power/config.json'
            config.parent.mkdir(parents=True)
            config.write_text(json.dumps({'ip': '192.0.2.1', 'token': 'a' * 32, 'model': 'cuco.plug.v3'}))
            # Copy installer with hardware discovery redirected to an empty fixture.
            # No mock runs against live Plasma or requests system authorization.
            script = home / 'source/install.sh'
            script.parent.mkdir()
            for child in ('backend', 'package'):
                (script.parent / child).symlink_to(ROOT / child)
            (script.parent / 'setup-rapl-access.sh').symlink_to(ROOT / 'setup-rapl-access.sh')
            script.write_text((ROOT / 'install.sh').read_text().replace('/sys/class/powercap', str(home / 'no-powercap')).replace('/etc/tmpfiles.d/mi-power-monitor-rapl.conf', str(home / 'no-rule')))
            env = {**os.environ, 'HOME': str(home), 'XDG_DATA_HOME': str(data), 'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_STATE_HOME': str(home / '.local/state'), 'XDG_RUNTIME_DIR': str(home), 'PATH': str(tools) + ':' + os.environ['PATH']}
            result = subprocess.run(['bash', str(script)], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(alias.resolve(), binary)
            self.assertTrue((bindir / 'mi-power-monitor-backend').is_file())
            uninstall = script.parent / 'uninstall.sh'
            uninstall.write_text((ROOT / 'uninstall.sh').read_text().replace('/etc/', str(home / 'etc') + '/').replace('/var/lib/', str(home / 'var-lib') + '/').replace('/usr/local/libexec/', str(home / 'libexec') + '/'))
            result = subprocess.run(['bash', str(uninstall), '--purge-config'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(config.exists())
            self.assertEqual(alias.resolve(), binary)
            self.assertFalse((bindir / 'mi-power-monitor-backend').is_symlink())

    def test_broker_reads_only_package_counters_and_ignores_pythonpath(self):
        source = HELPER.split("<<'READER'\n", 1)[1].split('\nREADER', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for index, name in enumerate(('package-0', 'psys')):
                domain = root / f'intel-rapl:{index}'
                domain.mkdir()
                (domain / 'name').write_text(name)
                (domain / 'energy_uj').write_text('123')
                (domain / 'max_energy_range_uj').write_text('456')
                (domain / 'constraint_0_power_limit_uw').write_text('789')
            (root / 'json.py').write_text('raise RuntimeError("user module loaded")')
            script = root / 'reader'
            script.write_text(source.replace("'/sys/class/powercap'", repr(str(root))).replace("'/sys/devices/'", repr(str(root) + '/')))
            result = subprocess.run(['/usr/bin/python3', '-I', str(script)], env={**os.environ, 'PYTHONPATH': tmp}, capture_output=True, text=True, check=True)
            values = json.loads(result.stdout)
            self.assertEqual(values, {str(root / 'intel-rapl:0/energy_uj'): 123, str(root / 'intel-rapl:0/max_energy_range_uj'): 456})
            self.assertEqual((root / 'intel-rapl:0/constraint_0_power_limit_uw').read_text(), '789')
