#!/usr/bin/env bash

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release-config.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/notarytool-store-credentials.sh"
  echo "Interactively register ${RELEASE_NOTARY_PROFILE} in the login Keychain."
  echo "Enter your Apple ID, then enter the new app-specific password at Apple's secure prompt."
  echo "No password argument or environment variable is accepted."
  exit 0
fi
if [[ $# -ne 0 || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  echo "Use this script without arguments or APPLE_APP_SPECIFIC_PASSWORD; enter the password only at the secure prompt." >&2
  exit 2
fi
if [[ ! -t 0 ]]; then
  echo "Run this script yourself in an interactive Terminal; do not paste passwords into chat or a command." >&2
  exit 2
fi
read -r -p "Developer Apple ID: " release_apple_id
if [[ -z "$release_apple_id" ]]; then
  echo "Apple ID is required." >&2
  exit 2
fi

# notarytool owns the hidden password prompt. The shell never reads the password.
xcrun notarytool store-credentials "$RELEASE_NOTARY_PROFILE" \
  --keychain "$RELEASE_KEYCHAIN" \
  --apple-id "$release_apple_id" \
  --team-id "$RELEASE_TEAM_ID" \
  --validate
xcrun notarytool history --keychain-profile "$RELEASE_NOTARY_PROFILE" \
  --keychain "$RELEASE_KEYCHAIN" --output-format json >/dev/null
echo "Validated release profile: ${RELEASE_NOTARY_PROFILE}"
