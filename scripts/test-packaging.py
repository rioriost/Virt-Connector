#!/usr/bin/env python3
"""Validate packaging contracts using project-local fixtures, never real installs."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / "VERSION").read_text().strip()

# Every package/build/metadata command is mocked, including signing commands.
MOCK_TOOL = r'''
import json
import os
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_CALLS"], "a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")

def option(key):
    return args[args.index(key) + 1]

if name == "pkgutil":
    assert args[0] == "--expand"
    if os.environ.get("TEST_EXPAND_FAIL"):
        sys.exit(1)
    package = Path(args[1])
    metadata = json.loads(package.read_text())
    expanded = Path(args[2])
    expanded.mkdir()
    if metadata.get("layout") != "missing":
        info = ET.Element("pkg-info", {k: metadata[k] for k in
                          ("identifier", "version", "install-location") if k in metadata})
        ET.ElementTree(info).write(expanded / "PackageInfo")
    if metadata.get("layout") == "malformed":
        (expanded / "PackageInfo").write_text("<broken")
    elif metadata.get("layout") == "wrong-root":
        (expanded / "PackageInfo").write_text("<unrelated/>")
    elif metadata.get("layout") == "distribution":
        (expanded / "Distribution").write_text("<installer-gui-script/>")
    elif metadata.get("layout") == "multiple":
        (expanded / "nested.pkg").mkdir()
        (expanded / "nested.pkg/PackageInfo").write_text("<pkg-info/>")
    if os.environ.get("TEST_CHANGE_PACKAGE"):
        package.write_text(package.read_text() + " ")
elif name == "swift":
    assert args[0] == "build"
    assert os.environ["MACOSX_DEPLOYMENT_TARGET"] == "13.0"
    output = Path(option("--scratch-path")) / "actual-bin-path"
    if "--show-bin-path" in args:
        print(output)
    else:
        if os.environ.get("TEST_BUILD_FAIL"):
            sys.exit(1)
        output.mkdir(parents=True)
        for binary in ("virt-connector", "virt-connectord"):
            (output / binary).write_text("fixture-" + binary)
elif name == "xcrun":
    if args == ["--sdk", "macosx", "--show-sdk-path"]:
        print("/Fixture SDK/MacOSX.sdk")
    elif args == ["--sdk", "macosx", "--show-sdk-version"]:
        print("27.0")
    elif args[:2] == ["lipo", "-archs"]:
        assert Path(args[2]).is_file()
        print(os.environ.get("TEST_ARCH", "arm64"))
    elif args[:2] == ["vtool", "-show-build"]:
        assert Path(args[2]).is_file()
        print("Load command 1\n      cmd LC_BUILD_VERSION")
        print(" platform " + os.environ.get("TEST_PLATFORM", "MACOS"))
        print("    minos " + os.environ.get("TEST_MIN_OS", "13.0"))
        print("      sdk " + os.environ.get("TEST_SDK_VERSION", "27.0"))
    elif args[:2] == ["notarytool", "submit"] and os.environ.get("TEST_SIGNED"):
        assert option("--keychain-profile") == "fixture-notary"
        assert option("--keychain") == "/fixture/login.keychain-db"
        assert option("--output-format") == "json"
        print(json.dumps({"id": "fixture-submission", "status": os.environ.get("TEST_NOTARY_STATUS", "Accepted")}))
    elif args[:2] == ["stapler", "staple"] and os.environ.get("TEST_SIGNED"):
        package = Path(args[2])
        package.write_bytes(package.read_bytes() + b"\n")
    elif args[:2] == ["stapler", "validate"] and os.environ.get("TEST_SIGNED"):
        assert Path(args[2]).read_bytes().endswith(b"\n")
    else:
        sys.exit("unexpected xcrun operation")
elif name == "pkgbuild":
    assert ("--sign" in args) == bool(os.environ.get("TEST_SIGNED"))
    root = Path(option("--root"))
    scripts = Path(option("--scripts"))
    assert (root / "Library/VirtConnector/bin/virt-connector").read_text() == "fixture-virt-connector"
    assert (root / "Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord").read_text() == "fixture-virt-connectord"
    assert (scripts / "preinstall").stat().st_mode & 0o111
    assert (scripts / "postinstall").stat().st_mode & 0o111
    assert scripts != Path(os.environ["TEST_PROJECT"]) / "packaging/pkg-scripts"
    with (root / "Library/VirtConnector/VirtConnectorAgent.app/Contents/Info.plist").open("rb") as stream:
        plist = plistlib.load(stream)
    assert plist["LSMinimumSystemVersion"] == "13.0"
    assert plist["CFBundleVersion"] == option("--version")
    assert plist["CFBundleShortVersionString"] == option("--version")
    Path(args[-1]).write_text(json.dumps({
        "identifier": option("--identifier"), "version": option("--version"),
        "install-location": option("--install-location")}))
elif name == "xattr":
    assert args[0] == "-cr"
elif name in ("codesign", "productsign", "installer", "launchctl"):
    if name == "codesign" and os.environ.get("TEST_SIGNED"):
        assert "--sign" in args and "--timestamp" in args
        sys.exit(0)
    sys.exit("forbidden live operation: " + name)
else:
    sys.exit("unexpected mock tool: " + name)
'''


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / f".packaging-tests-{uuid.uuid4().hex}"
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, self.root)
        for relative in ("scripts/build-pkg.sh", "scripts/update-cask.sh",
                         "packaging/pkg-scripts/preinstall", "packaging/pkg-scripts/postinstall",
                         "Casks/virt-connector.rb", "VERSION"):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        (self.root / "LICENSE").write_text("fixture license")
        (self.root / "README.md").write_text("fixture readme")
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("swift", "xcrun", "pkgbuild", "pkgutil", "xattr",
                     "codesign", "productsign", "installer", "launchctl"):
            tool = tools / name
            tool.write_text(f"#!{sys.executable}\n" + MOCK_TOOL)
            tool.chmod(0o755)
        self.calls_path = self.root / "calls.jsonl"
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("VERSION", "CONFIGURATION", "DIST_DIR", "PKG_IDENTIFIER",
                                   "SWIFT_BUILD_SYSTEM", "DEVELOPER_ID_APPLICATION",
                                   "DEVELOPER_ID_INSTALLER", "NOTARYTOOL_PROFILE", "NOTARYTOOL_KEYCHAIN")
                    and not key.startswith("TEST_")}
        self.env.update(PATH=f"{tools}:{os.environ['PATH']}",
                        TEST_CALLS=str(self.calls_path), TEST_PROJECT=str(self.root))
        self.cask = self.root / "Casks/virt-connector.rb"
        self.original_cask = self.cask.read_bytes()

    def run_script(self, script, *args, **env):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / script), *map(str, args)],
                              cwd=self.root, env={**self.env, **env}, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()] if self.calls_path.exists() else []

    def package(self, filename="unrelated-name.pkg", **metadata):
        path = self.root / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"identifier": "st.rio.virt-connector.pkg",
                                    "version": VERSION, "install-location": "/", **metadata}))
        return path

    def assert_work_cleaned(self):
        self.assertEqual(list((self.root / ".build").glob("pkg-*")), [])
        self.assertEqual(list((self.root / ".build").glob("cask-*")), [])
        self.assertEqual(list(self.cask.parent.glob(".virt-connector.rb.*")), [])

    def assert_cask_matches(self, package, version):
        text = self.cask.read_text()
        self.assertIn(f'  version "{version}"', text)
        self.assertIn(f'  sha256 "{hashlib.sha256(package.read_bytes()).hexdigest()}"', text)
        untouched = re.sub(rb'(?m)^  (version|sha256) "[^"]+"$', b'', self.original_cask)
        self.assertEqual(re.sub(rb'(?m)^  (version|sha256) "[^"]+"$', b'', self.cask.read_bytes()), untouched)
        self.assert_work_cleaned()

    def test_default_update_uses_shared_version_and_package_metadata_not_filename(self):
        package = self.package()
        result = self.run_script("update-cask.sh", package)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_cask_matches(package, VERSION)

    def test_default_artifact_path_and_explicit_version_override(self):
        for version, env in ((VERSION, {}), ("9.8.7", {"VERSION": "9.8.7"})):
            with self.subTest(version=version):
                package = self.package(f"dist/VirtConnector-{version}-signed.pkg", version=version)
                result = self.run_script("update-cask.sh", **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_cask_matches(package, version)

    def test_mismatched_metadata_preserves_cask_even_when_filename_matches(self):
        for metadata in ({"version": "0.1.2"}, {"identifier": "other.pkg"}, {"install-location": "/Volumes/Other"}):
            with self.subTest(metadata=metadata):
                package = self.package(f"VirtConnector-{VERSION}-signed.pkg", **metadata)
                result = self.run_script("update-cask.sh", package)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("metadata mismatch", result.stderr)
                self.assertEqual(self.cask.read_bytes(), self.original_cask)
                self.assert_work_cleaned()

    def test_explicit_mismatched_version_preserves_cask(self):
        result = self.run_script("update-cask.sh", self.package(), VERSION="9.8.7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version", result.stderr)
        self.assertEqual(self.cask.read_bytes(), self.original_cask)
        self.assert_work_cleaned()

    def test_invalid_or_unsupported_package_metadata_preserves_cask(self):
        for layout in ("missing", "malformed", "wrong-root", "multiple", "distribution"):
            with self.subTest(layout=layout):
                result = self.run_script("update-cask.sh", self.package(layout=layout))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.cask.read_bytes(), self.original_cask)
                self.assert_work_cleaned()

    def test_extraction_failure_and_changed_artifact_preserve_cask(self):
        for env in ({"TEST_EXPAND_FAIL": "1"}, {"TEST_CHANGE_PACKAGE": "1"}):
            with self.subTest(env=env):
                result = self.run_script("update-cask.sh", self.package(), **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.cask.read_bytes(), self.original_cask)
                self.assert_work_cleaned()

    def test_missing_artifact_and_invalid_versions_fail_without_mutation(self):
        result = self.run_script("update-cask.sh", self.root / "missing.pkg")
        self.assertNotEqual(result.returncode, 0)
        for script in ("update-cask.sh", "build-pkg.sh"):
            for version in ("1.2", "1.2.3\n4.5.6", "../../elsewhere"):
                with self.subTest(script=script, version=version):
                    args = (self.package(),) if script == "update-cask.sh" else ("--unsigned",)
                    result = self.run_script(script, *args, VERSION=version)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("invalid package version", result.stderr)
                    self.assertEqual(self.cask.read_bytes(), self.original_cask)
        self.assertEqual(self.calls(), [])

    def test_malformed_cask_is_never_partially_updated(self):
        self.cask.write_bytes(self.original_cask + b'  sha256 "duplicate"\n')
        before = self.cask.read_bytes()
        result = self.run_script("update-cask.sh", self.package())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.cask.read_bytes(), before)
        self.assert_work_cleaned()

    def test_unsigned_build_contract_and_round_trip_update(self):
        result = self.run_script("build-pkg.sh", "--unsigned")
        self.assertEqual(result.returncode, 0, result.stderr)
        package = self.root / f"dist/VirtConnector-{VERSION}.pkg"
        self.assertTrue(package.is_file())
        self.assertIn(hashlib.sha256(package.read_bytes()).hexdigest(),
                      package.with_suffix(".pkg.sha256").read_text())
        calls = self.calls()
        swift = [call for call in calls if call[0] == "swift"]
        self.assertEqual(len(swift), 2)
        self.assertEqual(swift[1], [*swift[0], "--show-bin-path"])
        for flag, expected in (("--triple", "arm64-apple-macosx13.0"),
                               ("--sdk", "/Fixture SDK/MacOSX.sdk"), ("--build-system", "native")):
            self.assertEqual(swift[0][swift[0].index(flag) + 1], expected)
        self.assertEqual(len([call for call in calls if call[:3] == ["xcrun", "lipo", "-archs"]]), 2)
        self.assertEqual(len([call for call in calls if call[:3] == ["xcrun", "vtool", "-show-build"]]), 2)
        self.assertFalse(any(call[0] in ("codesign", "productsign", "installer", "launchctl") for call in calls))
        self.assert_work_cleaned()
        result = self.run_script("update-cask.sh", package)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_cask_matches(package, VERSION)

    def test_build_backend_and_version_override_are_consistent(self):
        result = self.run_script("build-pkg.sh", "--unsigned", VERSION="9.8.7", SWIFT_BUILD_SYSTEM="swiftbuild")
        self.assertEqual(result.returncode, 0, result.stderr)
        package = self.root / "dist/VirtConnector-9.8.7.pkg"
        self.assertEqual(json.loads(package.read_text())["version"], "9.8.7")
        swift = [call for call in self.calls() if call[0] == "swift"]
        self.assertEqual(swift[1], [*swift[0], "--show-bin-path"])
        self.assertEqual(swift[0][swift[0].index("--build-system") + 1], "swiftbuild")
        self.assert_work_cleaned()

    def test_notarized_build_records_acceptance_and_hashes_stapled_artifact(self):
        result = self.run_script("build-pkg.sh", "--notarize", TEST_SIGNED="1",
            DEVELOPER_ID_APPLICATION="fixture-application", DEVELOPER_ID_INSTALLER="fixture-installer",
            NOTARYTOOL_PROFILE="fixture-notary", NOTARYTOOL_KEYCHAIN="/fixture/login.keychain-db")
        self.assertEqual(result.returncode, 0, result.stderr)
        package = self.root / f"dist/VirtConnector-{VERSION}-signed.pkg"
        self.assertEqual(json.loads(Path(str(package) + ".notary.json").read_text())["status"], "Accepted")
        self.assertTrue(package.read_bytes().endswith(b"\n"))
        self.assertIn(hashlib.sha256(package.read_bytes()).hexdigest(), Path(str(package) + ".sha256").read_text())
        self.assert_work_cleaned()

    def test_rejected_notarization_never_staples_or_produces_final_checksum(self):
        result = self.run_script("build-pkg.sh", "--notarize", TEST_SIGNED="1", TEST_NOTARY_STATUS="Invalid",
            DEVELOPER_ID_APPLICATION="fixture-application", DEVELOPER_ID_INSTALLER="fixture-installer",
            NOTARYTOOL_PROFILE="fixture-notary", NOTARYTOOL_KEYCHAIN="/fixture/login.keychain-db")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not accepted", result.stderr)
        self.assertFalse(any(call[:2] == ["xcrun", "stapler"] for call in self.calls()))
        self.assertFalse((self.root / f"dist/VirtConnector-{VERSION}-signed.pkg.sha256").exists())
        self.assert_work_cleaned()

    def test_invalid_binary_metadata_prevents_packaging(self):
        for env in ({"TEST_ARCH": "x86_64"}, {"TEST_ARCH": "x86_64 arm64"},
                    {"TEST_MIN_OS": "14.0"}, {"TEST_MIN_OS": "12.0"},
                    {"TEST_SDK_VERSION": "13.0"}, {"TEST_PLATFORM": "IOS"}):
            with self.subTest(env=env):
                self.calls_path.unlink(missing_ok=True)
                result = self.run_script("build-pkg.sh", "--unsigned", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == "pkgbuild" for call in self.calls()))
                self.assert_work_cleaned()

    def test_failed_build_cleanup_preserves_unowned_work(self):
        sentinel = self.root / ".build/pkg/keep"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text("unowned")
        result = self.run_script("build-pkg.sh", "--unsigned", TEST_BUILD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), "unowned")
        self.assert_work_cleaned()

    def test_help_and_argument_errors_do_not_invoke_build_or_package_tools(self):
        for script in ("build-pkg.sh", "update-cask.sh"):
            result = self.run_script(script, "--help")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("VERSION", result.stdout)
        for script, args in (("build-pkg.sh", ("--unsigned", "--notarize")),
                             ("build-pkg.sh", ("--unknown",)),
                             ("update-cask.sh", ("one.pkg", "two.pkg"))):
            result = self.run_script(script, *args)
            self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.cask.read_bytes(), self.original_cask)

    def test_symlinked_work_base_rejected_without_changes_to_target(self):
        target = self.root / "unowned"
        target.mkdir()
        sentinel = target / "keep"
        sentinel.write_text("unowned")
        (self.root / ".build").symlink_to(target, target_is_directory=True)
        for script, args in (("build-pkg.sh", ("--unsigned",)),
                             ("update-cask.sh", (self.package(),))):
            result = self.run_script(script, *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlinked .build", result.stderr)
        self.assertEqual(list(target.iterdir()), [sentinel])
        self.assertEqual(self.cask.read_bytes(), self.original_cask)

    def test_distribution_definitions_match_supported_install_routes(self):
        cask = (ROOT / "Casks/virt-connector.rb").read_text()
        self.assertIn("depends_on arch: :arm64", cask)
        self.assertIn("depends_on macos: :ventura", cask)
        self.assertRegex(cask, r'(?m)^  sha256 "[a-f0-9]{64}"$')
        formula = (ROOT / "Formula/virt-connector.rb").read_text()
        self.assertRegex(formula, r'(?m)^  head "https://[^"]+\.git", branch: "main"$')
        self.assertNotRegex(formula, r"(?m)^  (url|sha256|version) ")
        self.assertNotIn("PUT_SHA256_HERE", formula)


if __name__ == "__main__":
    unittest.main()
