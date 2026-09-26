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

    def test_installer_uses_native_qr_without_python_downloads(self):
        source = (ROOT / 'install.sh').read_text()
        function = source.split('prepare_native_setup() {', 1)[1].split('\n}\n', 1)[0]
        self.assertIn('"${version_dir}/xiaomi-power" --setup-cloud-qr', function)
        self.assertNotIn('pip install', function)
        self.assertNotIn('venv', function)
        self.assertNotIn('git ', function)
