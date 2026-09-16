#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(cat "$ROOT_DIR/VERSION")}"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: [VERSION=major.minor.patch] scripts/update-cask.sh [package.pkg]"
  echo "Default version: repository VERSION file; default artifact: dist/VirtConnector-\${VERSION}-signed.pkg"
  echo "Requires a single component pkg with matching PackageInfo version, identifier, and install location."
  echo "Only updates the Cask version/checksum after metadata verification; does not verify signing/notarization."
  exit 0
fi
if [[ $# -gt 1 ]]; then
  echo "expected at most one package path" >&2
  exit 2
fi
PKG_PATH="${1:-"$ROOT_DIR/dist/VirtConnector-${VERSION}-signed.pkg"}"
CASK_PATH="$ROOT_DIR/Casks/virt-connector.rb"

python3 - "$ROOT_DIR" "$PKG_PATH" "$CASK_PATH" "$VERSION" <<'PY'
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

root, package, cask = map(pathlib.Path, sys.argv[1:4])
version = sys.argv[4]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    sys.exit("invalid package version: expected major.minor.patch")
package = package.resolve()
if not package.is_file():
    sys.exit(f"package not found: {package}")

def checksum():
    digest = hashlib.sha256()
    with package.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

base = root / ".build"
if base.is_symlink():
    sys.exit("refusing a symlinked .build directory")
base.mkdir(exist_ok=True)
work = base / f"cask-{uuid.uuid4().hex}"
work.mkdir(mode=0o700)
replacement = cask.with_name(f".{cask.name}.{uuid.uuid4().hex}")
try:
    sha256 = checksum()
    expanded = work / "expanded"
    subprocess.run(["pkgutil", "--expand", str(package), str(expanded)],
                   check=True, capture_output=True, text=True)
    info_path = expanded / "PackageInfo"
    if (not info_path.is_file() or info_path.is_symlink()
            or (expanded / "Distribution").exists()
            or list(expanded.rglob("PackageInfo")) != [info_path]):
        sys.exit("expected one component package with a root PackageInfo")
    info = ET.parse(info_path).getroot()
    if info.tag != "pkg-info":
        sys.exit("invalid package metadata: expected pkg-info")
    expected = {"identifier": "st.rio.virt-connector.pkg",
                "version": version, "install-location": "/"}
    for key, value in expected.items():
        if info.get(key) != value:
            sys.exit(f"package metadata mismatch for {key}: expected {value!r}, got {info.get(key)!r}")
    if checksum() != sha256:
        sys.exit("package changed during metadata verification")

    text = cask.read_text()
    for key, value in (("version", version), ("sha256", sha256)):
        text, count = re.subn(r'(?m)^  ' + key + r' "[^"\n]*"$',
                             f'  {key} "{value}"', text)
        if count != 1:
            sys.exit(f"expected exactly one Cask {key} declaration")
    with replacement.open("x") as stream:
        stream.write(text)
    shutil.copymode(cask, replacement)
    os.replace(replacement, cask)
except subprocess.CalledProcessError:
    sys.exit("package metadata extraction failed; Cask was not changed")
except (OSError, ET.ParseError) as error:
    sys.exit(f"cannot update Cask: {error}")
finally:
    replacement.unlink(missing_ok=True)
    shutil.rmtree(work)
PY

echo "Updated $CASK_PATH for version $VERSION"
