#!/usr/bin/env python3
"""Exercise installer session selection without touching installed services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PostinstallTests(unittest.TestCase):
    def run_hook(self, user="test-user", volume="/", failure=False):
        source = Path(__file__).resolve().parents[1] / "packaging/pkg-scripts/postinstall"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls = root / "calls"
            stat = root / "stat"
            stat.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_CONSOLE_USER"\n')
            identity = root / "id"
            identity.write_text('#!/bin/sh\necho 501\n')
            launchctl = root / "launchctl"
            launchctl.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TEST_CALLS"\nexit "$TEST_EXIT"\n')
            for tool in (stat, identity, launchctl):
                tool.chmod(0o755)
            script = source.read_text().replace('/usr/local/bin', str(root / "bin"))
            for path, replacement in [('/usr/bin/stat', stat), ('/usr/bin/id', identity), ('/bin/launchctl', launchctl)]:
                script = script.replace(path, str(replacement))
            hook = root / "postinstall"
            hook.write_text(script)
            result = subprocess.run(
                ["/bin/sh", str(hook), "package", "/", volume],
                env={**os.environ, "TEST_CONSOLE_USER": user, "TEST_CALLS": str(calls), "TEST_EXIT": "5" if failure else "0"},
                capture_output=True, text=True,
            )
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_console_user_restoration_drops_root_privileges(self):
        result, calls = self.run_hook()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls, ["asuser", "501", "/usr/bin/sudo", "-n", "-H", "-u", "test-user", "/Library/VirtConnector/bin/virt-connector", "restore-agent"])

    def test_no_restore_without_a_real_console_user_or_on_other_volume(self):
        for user in ("", "root", "loginwindow", "_mbsetupuser"):
            with self.subTest(user=user):
                result, calls = self.run_hook(user=user)
                self.assertEqual((result.returncode, calls), (0, []))
        result, calls = self.run_hook(volume="/Volumes/External")
        self.assertEqual((result.returncode, calls), (0, []))

    def test_registration_failure_keeps_installation_and_explains_retry(self):
        result, _ = self.run_hook(failure=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("virt-connector restore-agent", result.stderr)


if __name__ == "__main__":
    unittest.main()
