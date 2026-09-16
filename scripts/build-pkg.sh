#!/usr/bin/env bash

set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(cat "$ROOT_DIR/VERSION")}"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"
WORK_DIR="$ROOT_DIR/.build/pkg-$$"
PKG_ROOT="$WORK_DIR/root"
PKG_SCRIPTS="$WORK_DIR/scripts"
PKG_IDENTIFIER="${PKG_IDENTIFIER:-st.rio.virt-connector.pkg}"
TARGET_TRIPLE="arm64-apple-macosx13.0"
export MACOSX_DEPLOYMENT_TARGET=13.0
PKG_NAME="VirtConnector-${VERSION}.pkg"
PKG_PATH="$DIST_DIR/$PKG_NAME"
SIGNED_PKG_PATH="$DIST_DIR/VirtConnector-${VERSION}-signed.pkg"
FINAL_PKG_PATH="$PKG_PATH"

usage() {
  cat <<EOF
Usage: scripts/build-pkg.sh [--unsigned] [--notarize]

Environment:
  VERSION                         Package version. Default: repository VERSION file
  DEVELOPER_ID_APPLICATION         Developer ID Application certificate name
  DEVELOPER_ID_INSTALLER           Developer ID Installer certificate name
  NOTARYTOOL_PROFILE               xcrun notarytool keychain profile
  SWIFT_BUILD_SYSTEM               SwiftPM backend. Default: native

Artifacts target arm64 and macOS 13.0. Both binaries must report the selected
macOS SDK version, architecture, and deployment target before packaging.
Build intermediates use a private project-local work directory, removed on exit.

Examples:
  scripts/build-pkg.sh --unsigned
  DEVELOPER_ID_APPLICATION="Developer ID Application: ..." \\
  DEVELOPER_ID_INSTALLER="Developer ID Installer: ..." \\
  scripts/build-pkg.sh --notarize
EOF
}

unsigned=false
notarize=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned)
      unsigned=true
      shift
      ;;
    --notarize)
      notarize=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$unsigned" == true && "$notarize" == true ]]; then
  echo "--unsigned and --notarize cannot be used together" >&2
  exit 2
fi

if [[ "$unsigned" == false ]]; then
  : "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is required unless --unsigned is used}"
  : "${DEVELOPER_ID_INSTALLER:?DEVELOPER_ID_INSTALLER is required unless --unsigned is used}"
fi

if [[ "$notarize" == true ]]; then
  : "${NOTARYTOOL_PROFILE:?NOTARYTOOL_PROFILE is required for --notarize}"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid package version: expected major.minor.patch" >&2
  exit 2
fi

if [[ -L "$ROOT_DIR/.build" ]]; then
  echo "refusing a symlinked .build directory" >&2
  exit 1
fi
mkdir -p "$ROOT_DIR/.build"
mkdir -m 700 "$WORK_DIR"
cleanup() {
  if [[ "$WORK_DIR" == "$ROOT_DIR/.build/pkg-$$" && ! -L "$ROOT_DIR/.build" && ! -L "$WORK_DIR" ]]; then
    python3 - "$WORK_DIR" <<'PY'
import shutil
import sys

shutil.rmtree(sys.argv[1])
PY
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

AGENT_APP="$PKG_ROOT/Library/VirtConnector/VirtConnectorAgent.app"
AGENT_CONTENTS="$AGENT_APP/Contents"
AGENT_MACOS="$AGENT_CONTENTS/MacOS"
mkdir -p "$PKG_ROOT/Library/VirtConnector/bin" "$PKG_ROOT/Library/VirtConnector/share" "$AGENT_MACOS" "$PKG_SCRIPTS" "$DIST_DIR"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
swift_build_args=(
  -c "$CONFIGURATION"
  --package-path "$ROOT_DIR"
  --scratch-path "$WORK_DIR/swift"
  --triple "$TARGET_TRIPLE"
  --sdk "$SDK_PATH"
  --build-system "${SWIFT_BUILD_SYSTEM:-native}"
)
swift build "${swift_build_args[@]}"
BIN_PATH="$(swift build "${swift_build_args[@]}" --show-bin-path)"

verify_binary() {
  local binary="$1"
  if [[ "$(xcrun lipo -archs "$binary")" != "arm64" ]]; then
    echo "unsupported architecture in $binary: expected arm64 only" >&2
    return 1
  fi
  xcrun vtool -show-build "$binary" | python3 -c '
import re
import sys

def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))

text = sys.stdin.read()
expected = {"platform": "MACOS", "minos": "13.0", "sdk": sys.argv[1]}
for key, value in expected.items():
    actual = re.findall(r"^\s*" + key + r"\s+(\S+)\s*$", text, re.M)
    matches = len(actual) == 1
    if matches:
        matches = actual[0] == value if key == "platform" else version(actual[0]) == version(value)
    if not matches:
        sys.exit(f"invalid Mach-O {key} in {sys.argv[2]}: expected {value}, got {actual}")
' "$SDK_VERSION" "$binary"
}

verify_binary "$BIN_PATH/virt-connector"
verify_binary "$BIN_PATH/virt-connectord"
cp "$BIN_PATH/virt-connector" "$PKG_ROOT/Library/VirtConnector/bin/virt-connector"
cp "$BIN_PATH/virt-connectord" "$AGENT_MACOS/virt-connectord"
cp "$ROOT_DIR/LICENSE" "$PKG_ROOT/Library/VirtConnector/share/LICENSE"
cp "$ROOT_DIR/README.md" "$PKG_ROOT/Library/VirtConnector/share/README.md"
cp "$ROOT_DIR/packaging/pkg-scripts/preinstall" "$ROOT_DIR/packaging/pkg-scripts/postinstall" "$PKG_SCRIPTS/"

cat > "$AGENT_CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>virt-connectord</string>
  <key>CFBundleIdentifier</key>
  <string>st.rio.virt-connectord</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VirtConnectorAgent</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
EOF

chmod 0755 "$PKG_ROOT/Library/VirtConnector/bin/virt-connector"
chmod 0755 "$AGENT_MACOS/virt-connectord"
chmod 0644 "$AGENT_CONTENTS/Info.plist"
chmod 0644 "$PKG_ROOT/Library/VirtConnector/share/LICENSE"
chmod 0644 "$PKG_ROOT/Library/VirtConnector/share/README.md"
chmod 0755 "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"
find "$PKG_ROOT" -name '._*' -delete
xattr -cr "$PKG_ROOT" "$PKG_SCRIPTS" 2>/dev/null || true

if [[ "$unsigned" == false ]]; then
  codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
    "$PKG_ROOT/Library/VirtConnector/bin/virt-connector"
  codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
    "$AGENT_APP"
fi

pkgbuild_args=(
  --root "$PKG_ROOT"
  --scripts "$PKG_SCRIPTS"
  --identifier "$PKG_IDENTIFIER"
  --version "$VERSION"
  --install-location "/"
)

if [[ "$unsigned" == false ]]; then
  pkgbuild_args+=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp)
  FINAL_PKG_PATH="$SIGNED_PKG_PATH"
fi

pkgbuild "${pkgbuild_args[@]}" "$FINAL_PKG_PATH"

if [[ "$notarize" == true ]]; then
  xcrun notarytool submit "$FINAL_PKG_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  xcrun stapler staple "$FINAL_PKG_PATH"
  xcrun stapler validate "$FINAL_PKG_PATH"
fi

shasum -a 256 "$FINAL_PKG_PATH" | tee "$FINAL_PKG_PATH.sha256"
echo "$FINAL_PKG_PATH"
