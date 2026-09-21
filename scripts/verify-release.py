#!/usr/bin/env python3
"""Verify a signed, stapled release package without installing it."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def run(*args):
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout + result.stderr


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(package, root, team):
    version = (root / "VERSION").read_text().strip()
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Invalid VERSION")
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    recorded = Path(str(package) + ".sha256").read_text().split()[0]
    require(digest == recorded, "Package checksum changed")
    signature = run("pkgutil", "--check-signature", str(package))
    require(f"({team})" in signature and "Developer ID Installer:" in signature,
            "Unexpected package signing identity")
    run("xcrun", "stapler", "validate", str(package))
    run("spctl", "--assess", "--type", "install", "--verbose=2", str(package))
    base = root / ".build"
    require(not base.is_symlink(), "Refusing a symlinked .build directory")
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-verify-", dir=base) as temporary:
        expanded = Path(temporary) / "expanded"
        run("pkgutil", "--expand-full", str(package), str(expanded))
        info = ET.parse(expanded / "PackageInfo").getroot()
        for key, expected in {"version": version, "identifier": "st.rio.virt-connector.pkg",
                              "install-location": "/"}.items():
            require(info.get(key) == expected, f"Package {key} mismatch")
        payload = expanded / "Payload/Library/VirtConnector"
        app = payload / "VirtConnectorAgent.app"
        plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        require(plist["CFBundleShortVersionString"] == version
                and plist["CFBundleVersion"] == version, "App version mismatch")
        require(plist["LSMinimumSystemVersion"] == "13.0", "App minimum OS mismatch")
        for signed in [app, payload / "bin/virt-connector"]:
            run("codesign", "--verify", "--deep", "--strict", str(signed))
            details = run("codesign", "--display", "--verbose=4", str(signed))
            require(f"TeamIdentifier={team}" in details and "runtime" in details,
                    "Unexpected code signing team or missing hardened runtime")
        for binary in [app / "Contents/MacOS/virt-connectord", payload / "bin/virt-connector"]:
            require(run("xcrun", "lipo", "-archs", str(binary)).strip() == "arm64", "Architecture mismatch")
            metadata = run("xcrun", "vtool", "-show-build", str(binary))
            require(re.search(r"(?m)^\s*minos 13\.0\s*$", metadata), "Deployment target mismatch")
            require(binary.stat().st_mode & 0o777 == 0o755, "Executable permissions mismatch")
        for script in ("preinstall", "postinstall"):
            extracted = expanded / "Scripts" / script
            require(extracted.read_bytes() == (root / "packaging/pkg-scripts" / script).read_bytes(),
                    f"Packaged {script} differs from source")
            require(extracted.stat().st_mode & 0o777 == 0o755, "Installer script permissions mismatch")
        require((payload / "share/README.md").read_bytes() == (root / "README.md").read_bytes(),
                "Packaged README differs from source; rebuild before publishing")
    require(hashlib.sha256(package.read_bytes()).hexdigest() == digest, "Package changed during verification")
    print(json.dumps({"version": version, "package": package.name, "sha256": digest,
                      "team": team, "signature": "verified", "staple": "valid", "gatekeeper": "accepted"}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--team-id", required=True)
    arguments = parser.parse_args()
    try:
        verify(arguments.package.resolve(), Path(__file__).resolve().parents[1], arguments.team_id)
    except (OSError, ValueError, KeyError, IndexError, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release verification failed: {error}\n")
