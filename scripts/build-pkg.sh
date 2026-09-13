#!/usr/bin/env bash

set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.4}"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"
WORK_DIR="$ROOT_DIR/.build/pkg"
PKG_ROOT="$WORK_DIR/root"
PKG_IDENTIFIER="${PKG_IDENTIFIER:-st.rio.virt-connector.pkg}"
PKG_NAME="VirtConnector-${VERSION}.pkg"
PKG_PATH="$DIST_DIR/$PKG_NAME"
SIGNED_PKG_PATH="$DIST_DIR/VirtConnector-${VERSION}-signed.pkg"
FINAL_PKG_PATH="$PKG_PATH"

usage() {
  cat <<EOF
Usage: scripts/build-pkg.sh [--unsigned] [--notarize]

Environment:
  VERSION                         Package version. Default: 0.1.4
  DEVELOPER_ID_APPLICATION         Developer ID Application certificate name
  DEVELOPER_ID_INSTALLER           Developer ID Installer certificate name
  NOTARYTOOL_PROFILE               xcrun notarytool keychain profile
  SWIFT_BUILD_SYSTEM               Optional SwiftPM build-system override

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

rm -rf "$WORK_DIR"
AGENT_APP="$PKG_ROOT/Library/VirtConnector/VirtConnectorAgent.app"
AGENT_CONTENTS="$AGENT_APP/Contents"
AGENT_MACOS="$AGENT_CONTENTS/MacOS"
mkdir -p "$PKG_ROOT/Library/VirtConnector/bin" "$PKG_ROOT/Library/VirtConnector/share" "$AGENT_MACOS" "$DIST_DIR"

swift_build_args=(-c "$CONFIGURATION" --package-path "$ROOT_DIR" --sdk "$(xcrun --sdk macosx --show-sdk-path)")
if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then
  swift_build_args+=(--build-system "$SWIFT_BUILD_SYSTEM")
fi
swift build "${swift_build_args[@]}"

cp "$ROOT_DIR/.build/$CONFIGURATION/virt-connector" "$PKG_ROOT/Library/VirtConnector/bin/virt-connector"
cp "$ROOT_DIR/.build/$CONFIGURATION/virt-connectord" "$AGENT_MACOS/virt-connectord"
cp "$ROOT_DIR/LICENSE" "$PKG_ROOT/Library/VirtConnector/share/LICENSE"
cp "$ROOT_DIR/README.md" "$PKG_ROOT/Library/VirtConnector/share/README.md"

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
chmod 0755 "$ROOT_DIR/packaging/pkg-scripts/preinstall" "$ROOT_DIR/packaging/pkg-scripts/postinstall"
find "$PKG_ROOT" -name '._*' -delete
xattr -cr "$PKG_ROOT" "$ROOT_DIR/packaging/pkg-scripts" 2>/dev/null || true

if [[ "$unsigned" == false ]]; then
  codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
    "$PKG_ROOT/Library/VirtConnector/bin/virt-connector"
  codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
    "$AGENT_APP"
fi

pkgbuild_args=(
  --root "$PKG_ROOT"
  --scripts "$ROOT_DIR/packaging/pkg-scripts"
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
