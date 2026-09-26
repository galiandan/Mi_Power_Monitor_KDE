import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('qr_setup', ROOT / 'backend/xiaomi_power.py')
qr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qr)


class QrSetupTests(unittest.TestCase):
    def test_git_timeout_kills_download_group_and_reaps_process(self):
        process = mock.Mock(pid=123456)
        process.wait.side_effect = [subprocess.TimeoutExpired('git', 0.1), -9]
        with mock.patch.object(qr.subprocess, 'Popen', return_value=process) as start, mock.patch.object(qr.os, 'killpg') as kill:
            with self.assertRaises(subprocess.TimeoutExpired):
                qr._run_qr_git(['fetch'], timeout=0.1)
        kill.assert_called_once_with(123456, signal.SIGKILL)
        self.assertEqual(process.wait.call_count, 2)
        self.assertTrue(start.call_args.kwargs['start_new_session'])
        self.assertEqual(start.call_args.kwargs['env']['GIT_TERMINAL_PROMPT'], '0')

    def test_git_failure_is_reported(self):
        process = mock.Mock()
        process.wait.return_value = 128
        with mock.patch.object(qr.subprocess, 'Popen', return_value=process):
            with self.assertRaises(RuntimeError):
                qr._run_qr_git(['fetch'])

    def test_dependency_timeout_is_visible_and_stops_before_login(self):
        source = (ROOT / 'install.sh').read_text()
        function = source.split('prepare_python_setup() {', 1)[1].split('\n}\n', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / '.venv/bin').mkdir(parents=True)
            python = root / '.venv/bin/python'
            python.write_text('#!/bin/sh\nexit 99\n')
            python.chmod(0o755)
            timeout = root / 'timeout'
            timeout.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 124\n')
            timeout.chmod(0o755)
            script = 'say() { printf "%s\\n" "$2"; }\nprepare_python_setup() {' + function + '\n}\nprepare_python_setup\n'
            result = subprocess.run(['bash', '-c', script], env={**os.environ, 'version_dir': tmp, 'PATH': tmp + ':' + os.environ['PATH']}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Downloading QR dependencies', result.stdout)
            self.assertIn('300s', result.stdout)
            self.assertIn('exceeded 5 minutes', result.stderr)
            self.assertNotIn('dependencies are ready', result.stdout)
            self.assertNotIn('--quiet', result.stdout)
            self.assertNotIn('requirements.txt', result.stdout)
            self.assertIn('pycryptodome', result.stdout)
