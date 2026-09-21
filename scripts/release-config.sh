#!/usr/bin/env bash
# Public release identity. Never put Apple IDs, passwords or API keys here.
readonly RELEASE_NOTARY_PROFILE="virt-connector-notary"
readonly RELEASE_TEAM_ID="23889H77KX"
readonly RELEASE_APPLICATION_IDENTITY="Developer ID Application: Ryo Fujita (${RELEASE_TEAM_ID})"
readonly RELEASE_INSTALLER_IDENTITY="Developer ID Installer: Ryo Fujita (${RELEASE_TEAM_ID})"
readonly RELEASE_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
