#!/usr/bin/env python3
"""Release gates use mocks only; no credentials, signing, uploads or installs."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_release", ROOT / "scripts/verify-release.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

MOCK = r'''
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["RELEASE_TEST_CALLS"], "a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
if name == "xcrun":
    if args == ["--sdk", "macosx", "--show-sdk-version"]: print("27.0")
    elif args[:2] == ["notarytool", "history"]:
        sys.exit(1 if os.environ.get("RELEASE_TEST_NO_PROFILE") else 0)
    else: sys.exit("Unexpected xcrun call")
elif name == "security":
    if args[0] == "find-identity":
        print('Developer ID Application: Ryo Fujita (23889H77KX)')
    elif args[0] != "find-certificate": sys.exit("Unexpected security call")
elif name == "gh":
    if "repos/rioriost/Virt-Connector/releases" in args:
        if os.environ.get("RELEASE_TEST_PUBLISHED"): print("1234")
    else: print("true")
else: sys.exit("Forbidden release side effect: " + name)
'''


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="virt-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        for name in ["release.sh", "release-config.sh", "notarytool-store-credentials.sh"]:
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / "VERSION").write_text("0.1.7\n")
        self.calls = self.root / "calls.jsonl"
        tools = self.root / "tools"
        tools.mkdir()
        for name in ["swift", "xcrun", "codesign", "pkgbuild", "pkgutil", "spctl", "security", "gh", "git"]:
            tool = tools / name
            tool.write_text(f"#!{sys.executable}\n" + MOCK)
            tool.chmod(0o755)
        excluded = {"VERSION", "DIST_DIR", "CONFIGURATION", "PKG_IDENTIFIER", "SWIFT_BUILD_SYSTEM",
                    "DEVELOPER_ID_APPLICATION", "DEVELOPER_ID_INSTALLER", "NOTARYTOOL_PROFILE",
                    "NOTARYTOOL_KEYCHAIN", "APPLE_APP_SPECIFIC_PASSWORD"}
        self.env = {k: v for k, v in os.environ.items() if k not in excluded and not k.startswith("RELEASE_TEST_")}
        self.env.update(PATH=f"{tools}:{os.environ['PATH']}", RELEASE_TEST_CALLS=str(self.calls))

    def script(self, name, *args, **environment):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *args],
                              env={**self.env, **environment}, input="", capture_output=True, text=True)

    def recorded(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_missing_profile_stops_before_build_or_artifact_changes(self):
        sentinel = self.root / "dist/keep.pkg"
        sentinel.parent.mkdir()
        sentinel.write_bytes(b"previous release")
        result = self.script("release.sh", "prepare", RELEASE_TEST_NO_PROFILE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notarytool-store-credentials.sh", result.stderr)
        self.assertFalse(any(call[0] in ["swift", "pkgbuild", "codesign", "pkgutil"] for call in self.recorded()))
        self.assertEqual(sentinel.read_bytes(), b"previous release")
        self.assertFalse((self.root / ".build").exists())

    def test_preflight_uses_fixed_profile_and_explicit_login_keychain(self):
        result = self.script("release.sh", "check")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.recorded() if c[:3] == ["xcrun", "notarytool", "history"])
        self.assertEqual(call[call.index("--keychain-profile") + 1], "virt-connector-notary")
        self.assertEqual(call[call.index("--keychain") + 1], str(Path.home() / "Library/Keychains/login.keychain-db"))

    def test_published_version_cannot_be_rebuilt(self):
        result = self.script("release.sh", "prepare", RELEASE_TEST_PUBLISHED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already published", result.stderr)
        self.assertFalse(any(call[0] in ["swift", "pkgbuild", "codesign", "pkgutil"] for call in self.recorded()))

    def test_ambient_release_overrides_are_rejected_before_external_calls(self):
        for env in [{"VERSION": "9.9.9"}, {"NOTARYTOOL_PROFILE": "another-app"}, {"DIST_DIR": "/tmp/elsewhere"}]:
            result = self.script("release.sh", "prepare", **env)
            self.assertEqual(result.returncode, 2)
        self.assertEqual(self.recorded(), [])

    def test_credentials_reject_noninteractive_input_and_password_environment(self):
        result = self.script("notarytool-store-credentials.sh")
        self.assertEqual(result.returncode, 2)
        self.assertIn("interactive Terminal", result.stderr)
        result = self.script("notarytool-store-credentials.sh", APPLE_APP_SPECIFIC_PASSWORD="dummy-secret")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("dummy-secret", result.stderr + result.stdout)
        self.assertEqual(self.recorded(), [])

    def test_help_and_invalid_command_do_not_contact_services(self):
        for script in ["release.sh", "notarytool-store-credentials.sh"]:
            self.assertEqual(self.script(script, "--help").returncode, 0)
        self.assertEqual(self.script("release.sh", "publish-without-verification").returncode, 2)
        self.assertEqual(self.recorded(), [])

    def fixture_package(self):
        package = self.root / "release.pkg"
        package.write_bytes(b"signed fixture")
        Path(str(package) + ".sha256").write_text(hashlib.sha256(package.read_bytes()).hexdigest())
        return package

    def test_checksum_mismatch_stops_before_trust_checks(self):
        package = self.fixture_package()
        package.write_bytes(b"changed artifact")
        with patch.object(verifier, "run") as run:
            with self.assertRaisesRegex(ValueError, "checksum changed"):
                verifier.verify(package, self.root, "23889H77KX")
            run.assert_not_called()

    def test_missing_staple_stops_before_expansion(self):
        package = self.fixture_package()
        with patch.object(verifier, "run", side_effect=[
            "Developer ID Installer: Fixture (23889H77KX)",
            subprocess.CalledProcessError(65, ["xcrun", "stapler", "validate"])
        ]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                verifier.verify(package, self.root, "23889H77KX")
            self.assertEqual(run.call_count, 2)
        self.assertFalse((self.root / ".build").exists())

    def test_valid_package_requires_matching_payload_and_cleans_extraction(self):
        package = self.fixture_package()
        (self.root / "README.md").write_text("fixture readme")
        (self.root / "packaging/pkg-scripts").mkdir(parents=True)
        for name in ["preinstall", "postinstall"]:
            (self.root / "packaging/pkg-scripts" / name).write_text("fixture script")

        def mocked(*args):
            if args[:2] == ("pkgutil", "--check-signature"):
                return "Developer ID Installer: Fixture (23889H77KX)"
            if args[:2] == ("pkgutil", "--expand-full"):
                expanded = Path(args[3])
                app = expanded / "Payload/Library/VirtConnector/VirtConnectorAgent.app"
                (app / "Contents/MacOS").mkdir(parents=True)
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleVersion": "0.1.7", "CFBundleShortVersionString": "0.1.7", "LSMinimumSystemVersion": "13.0"}))
                (expanded / "PackageInfo").write_text('<pkg-info version="0.1.7" identifier="st.rio.virt-connector.pkg" install-location="/"/>')
                for relative in ["Scripts/preinstall", "Scripts/postinstall",
                                 "Payload/Library/VirtConnector/bin/virt-connector",
                                 "Payload/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord"]:
                    target = expanded / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text("fixture script")
                    target.chmod(0o755)
                readme = expanded / "Payload/Library/VirtConnector/share/README.md"
                readme.parent.mkdir()
                readme.write_text("fixture readme")
            if args[:2] == ("codesign", "--display"):
                return "TeamIdentifier=23889H77KX\nflags=runtime"
            if args[:3] == ("xcrun", "lipo", "-archs"): return "arm64"
            if args[:3] == ("xcrun", "vtool", "-show-build"): return "    minos 13.0\n"
            return ""

        with patch.object(verifier, "run", side_effect=mocked), patch("builtins.print"):
            verifier.verify(package, self.root, "23889H77KX")
        self.assertEqual(list((self.root / ".build").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
