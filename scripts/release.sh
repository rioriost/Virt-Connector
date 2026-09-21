#!/usr/bin/env bash
# Fixed release preparation. Publishing steps live in docs/releases/RELEASING.md.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release-config.sh"
cd "$ROOT_DIR"

usage() {
  echo "Usage: scripts/release.sh check|prepare|verify"
  echo "check: validate tools, signing identities, GitHub access and the dedicated notary profile"
  echo "prepare: check, test, build, sign, notarize, staple, verify, then update the Cask"
  echo "verify: recheck the final package and its checksum without rebuilding or uploading"
}
if [[ $# -ne 1 ]]; then usage >&2; exit 2; fi
case "$1" in
  --help|-h) usage; exit 0 ;;
  check|prepare|verify) ;;
  *) usage >&2; exit 2 ;;
esac

release_version="$(cat VERSION)"
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain major.minor.patch." >&2
  exit 2
fi
for override in VERSION DIST_DIR CONFIGURATION PKG_IDENTIFIER SWIFT_BUILD_SYSTEM \
                DEVELOPER_ID_APPLICATION DEVELOPER_ID_INSTALLER NOTARYTOOL_PROFILE NOTARYTOOL_KEYCHAIN; do
  if [[ -n "${!override:-}" ]]; then
    echo "Unset ${override}; release.sh uses VERSION and scripts/release-config.sh." >&2
    exit 2
  fi
done
package="$ROOT_DIR/dist/VirtConnector-${release_version}-signed.pkg"

check() {
  for tool in swift xcrun codesign pkgbuild pkgutil spctl security python3 gh git; do
    command -v "$tool" >/dev/null
  done
  xcrun --sdk macosx --show-sdk-version
  security find-identity -v -p codesigning | /usr/bin/grep -F "$RELEASE_APPLICATION_IDENTITY" >/dev/null
  security find-certificate -c "$RELEASE_INSTALLER_IDENTITY" "$RELEASE_KEYCHAIN" >/dev/null
  gh api repos/rioriost/Virt-Connector --jq '.permissions.push' | /usr/bin/grep -x true >/dev/null
  if ! xcrun notarytool history --keychain-profile "$RELEASE_NOTARY_PROFILE" \
      --keychain "$RELEASE_KEYCHAIN" --output-format json >/dev/null; then
    echo "Register the dedicated profile in Terminal: scripts/notarytool-store-credentials.sh" >&2
    return 1
  fi
  echo "Release preflight passed for ${release_version}."
}

verify() {
  python3 "$ROOT_DIR/scripts/verify-release.py" "$package" --team-id "$RELEASE_TEAM_ID"
}

case "$1" in
  check) check ;;
  verify) verify ;;
  prepare)
    # Authentication fails before tests, builds, artifacts or Cask changes.
    check
    published="$(gh api --paginate repos/rioriost/Virt-Connector/releases \
      --jq ".[] | select(.tag_name == \"v${release_version}\" and .draft == false) | .id")"
    if [[ -n "$published" ]]; then
      echo "Version ${release_version} is already published; increment VERSION instead of rebuilding its assets." >&2
      exit 1
    fi
    swift test --build-system native --quiet
    python3 -B -m unittest scripts/test-postinstall.py scripts/test-packaging.py scripts/test-release.py
    mkdir -p .build/release-ui
    swiftc -parse-as-library Sources/VirtConnectorDaemon/AgentInterface.swift \
      Sources/VirtConnectorDaemon/AgentLocalizer.swift scripts/preview-ui.swift \
      -o .build/release-ui/preview
    .build/release-ui/preview --check
    DEVELOPER_ID_APPLICATION="$RELEASE_APPLICATION_IDENTITY" \
      DEVELOPER_ID_INSTALLER="$RELEASE_INSTALLER_IDENTITY" \
      NOTARYTOOL_PROFILE="$RELEASE_NOTARY_PROFILE" \
      NOTARYTOOL_KEYCHAIN="$RELEASE_KEYCHAIN" \
      "$ROOT_DIR/scripts/build-pkg.sh" --notarize
    verify
    "$ROOT_DIR/scripts/update-cask.sh" "$package"
    echo "Verified package and Cask ready. Follow docs/releases/RELEASING.md to publish."
    ;;
esac
