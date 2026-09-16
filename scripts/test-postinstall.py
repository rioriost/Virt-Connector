#!/usr/bin/env python3
"""Exercise root-volume guards and restoration with project-local tool fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid


class PostinstallTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1] / f".packaging-hook-tests-{uuid.uuid4().hex}"
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, self.root)

    def run_hook(self, user="test-user", volume="/", failure=False, hook_name="postinstall",
                 existing_links=False, stat_failure=False, id_failure=False):
        source = Path(__file__).resolve().parents[1] / "packaging/pkg-scripts" / hook_name
        root = self.root / uuid.uuid4().hex
        root.mkdir()
        calls = root / "calls"
        fs_calls = root / "fs-calls"
        link_dir = root / "current-volume/usr/local/bin"
        if existing_links:
            link_dir.mkdir(parents=True)
            for name in ("virt-connector", "virt-connectord"):
                (link_dir / name).symlink_to(f"/previous/{name}")

        def snapshot():
            return {str(path.relative_to(root)): os.readlink(path) if path.is_symlink() else "directory"
                    for path in (root / "current-volume").rglob("*")}

        before = snapshot()
        stat = root / "stat"
        stat.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_CONSOLE_USER"\nexit "$TEST_STAT_EXIT"\n')
        identity = root / "id"
        identity.write_text('#!/bin/sh\necho 501\nexit "$TEST_ID_EXIT"\n')
        launchctl = root / "launchctl"
        launchctl.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TEST_CALLS"\nexit "$TEST_EXIT"\n')
        mkdir = root / "mkdir"
        mkdir.write_text('''#!/bin/sh
set -eu
for arg in "$@"; do
  case "$arg" in -p|"$TEST_ROOT"/*) ;; *) exit 99 ;; esac
done
echo mkdir >> "$TEST_FS_CALLS"
/bin/mkdir "$@"
''')
        ln = root / "ln"
        ln.write_text('''#!/bin/sh
set -eu
for destination in "$@"; do :; done
case "$destination" in "$TEST_ROOT"/*) ;; *) exit 99 ;; esac
echo ln >> "$TEST_FS_CALLS"
/bin/ln "$@"
''')
        for tool in (stat, identity, launchctl, mkdir, ln):
            tool.chmod(0o755)
        script = source.read_text().replace('/usr/local/bin', str(link_dir))
        for path, replacement in [('/usr/bin/stat', stat), ('/usr/bin/id', identity), ('/bin/launchctl', launchctl)]:
            script = script.replace(path, str(replacement))
        hook = root / hook_name
        hook.write_text(script)
        args = ["/bin/sh", str(hook), "package", "/"]
        if volume is not None:
            args.append(volume)
        result = subprocess.run(
            args, env={**os.environ, "PATH": f"{root}:/usr/bin:/bin",
                       "TEST_ROOT": str(root), "TEST_CONSOLE_USER": user,
                       "TEST_CALLS": str(calls), "TEST_FS_CALLS": str(fs_calls),
                       "TEST_EXIT": "5" if failure else "0",
                       "TEST_STAT_EXIT": "1" if stat_failure else "0",
                       "TEST_ID_EXIT": "1" if id_failure else "0"},
            capture_output=True, text=True,
        )
        self.fs_calls = fs_calls.read_text().splitlines() if fs_calls.exists() else []
        self.before, self.after = before, snapshot()
        self.link_dir = link_dir
        return result, calls.read_text().splitlines() if calls.exists() else []

    def test_console_user_restoration_drops_root_privileges(self):
        result, calls = self.run_hook()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls, ["asuser", "501", "/usr/bin/sudo", "-n", "-H", "-u", "test-user", "/Library/VirtConnector/bin/virt-connector", "restore-agent"])
        self.assertEqual(self.fs_calls, ["mkdir", "ln", "ln"])
        self.assertEqual(os.readlink(self.link_dir / "virt-connector"), "/Library/VirtConnector/bin/virt-connector")
        self.assertEqual(os.readlink(self.link_dir / "virt-connectord"),
                         "/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord")

    def test_no_restore_without_a_real_console_user(self):
        for user in ("", "root", "loginwindow", "_mbsetupuser"):
            with self.subTest(user=user):
                result, calls = self.run_hook(user=user)
                self.assertEqual((result.returncode, calls), (0, []))
    def test_both_hooks_reject_other_or_missing_volume_before_any_writes(self):
        for hook in ("preinstall", "postinstall"):
            for volume in ("/Volumes/External", "", None):
                for existing in (False, True):
                    with self.subTest(hook=hook, volume=volume, existing=existing):
                        result, calls = self.run_hook(volume=volume, hook_name=hook, existing_links=existing)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("startup volume", result.stderr)
                        self.assertEqual((calls, self.fs_calls), ([], []))
                        self.assertEqual(self.after, self.before)

    def test_preinstall_accepts_root_without_mutation(self):
        result, calls = self.run_hook(hook_name="preinstall")
        self.assertEqual((result.returncode, calls, self.fs_calls), (0, [], []))
        self.assertEqual(self.after, self.before)

    def test_registration_failure_keeps_installation_and_explains_retry(self):
        result, _ = self.run_hook(failure=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("virt-connector restore-agent", result.stderr)

    def test_session_lookup_failure_is_nonfatal_and_explains_retry(self):
        for failure in ("stat_failure", "id_failure"):
            with self.subTest(failure=failure):
                result, calls = self.run_hook(**{failure: True})
                self.assertEqual((result.returncode, calls), (0, []))
                self.assertEqual(len(self.fs_calls), 3)
                self.assertIn("virt-connector restore-agent", result.stderr)


if __name__ == "__main__":
    unittest.main()
