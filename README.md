# VirtConnector

## Overview

VirtConnector links macOS display sleep/wake events and explicit shutdown actions to Shortcuts.

VirtConnector does not directly control Apple Home or Matter devices. Device selection and control stay in Shortcuts. VirtConnector handles the macOS-side resident agent, LaunchAgent registration, event detection, and event-based Shortcut execution.

## Quick Start

The signed package supports Apple Silicon (arm64), macOS 13 or later, and installation on the startup volume only.

### 1. Install with Homebrew Cask

```sh
brew tap rioriost/cask https://github.com/rioriost/homebrew-cask
brew install --cask rioriost/cask/virt-connector
```

For local development builds:

```sh
HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask rioriost/cask/virt-connector-local
```

### 2. Create Shortcuts

Create two Shortcuts in the macOS Shortcuts app for the Home/Matter device you want to control.

- `TurnOnLED`: turns on `LED Strip`
- `TurnOffLED`: turns off `LED Strip`

Verify them from Terminal:

```sh
shortcuts run TurnOnLED
shortcuts run TurnOffLED
```

### 3. Set Up VirtConnector

```sh
virt-connector setup --device "LED Strip" --on TurnOnLED --off TurnOffLED
```

This creates or updates:

- `~/.config/virt-connector/config.json`
- `~/Library/LaunchAgents/st.rio.virt-connectord.plist`
- the running user LaunchAgent for `VirtConnectorAgent`
- the VirtConnector power icon in the menu bar

After setup, display sleep/wake runs `TurnOffLED`/`TurnOnLED`.

To run LED-off actions before shutdown, use the VirtConnector menu bar item `Shut Down…` instead of the Apple menu shutdown item. VirtConnector asks macOS to shut down only after the configured `power_off` actions succeed. A successful Shortcut does not independently verify the physical device state.

Japanese documentation is available in [README-ja.md](README-ja.md).

## Components

- `virt-connector`
  - CLI for setup, device management, LaunchAgent management, manual tests, and shutdown.
- `VirtConnectorAgent.app`
  - Resident agent that contains `virt-connectord`.
  - Runs in the user's Aqua session as a LaunchAgent.
  - Provides the menu bar icon and `Shut Down…` menu item.
- `virt-connectord`
  - Executable inside `VirtConnectorAgent.app/Contents/MacOS/virt-connectord`.
  - `/usr/local/bin/virt-connectord` is a symlink to this executable.

`virt-connectord` runs outside the App Sandbox as a user LaunchAgent. Display sleep/wake is handled with AppKit `NSWorkspace` notifications, avoiding continuous `pmset` polling.

## Events

- `display_on`
  - Triggered by `NSWorkspace.screensDidWakeNotification` or `NSWorkspace.didWakeNotification`.
- `display_off`
  - Triggered by `NSWorkspace.screensDidSleepNotification` or `NSWorkspace.willSleepNotification`.
- `power_off`
  - Triggered when shutdown is explicitly started from the VirtConnector menu bar item or `virt-connector shutdown`.
  - Apple menu shutdown may be handled best-effort through `NSWorkspace.willPowerOffNotification`, but Shortcuts may already be unavailable by that phase.
  - LaunchAgent stop events such as Homebrew upgrades, `launchctl bootout`, or `SIGTERM` are not treated as `power_off`.

Each device can choose `on`, `off`, or `none` for each event.

Display events, manual CLI actions, and shutdown requests share one execution coordinator while the agent is running. Once shutdown preparation starts, queued display actions are skipped and new manual actions are rejected. Repeated shutdown notifications do not rerun the same power-off actions. An unloaded agent permits standalone CLI execution, protected against concurrent agent/CLI execution by a per-user ownership lock.

Default actions for the first configured device:

- `display_on`: `on`
- `display_off`: `off`
- `power_off`: `off`

## Installed Files

The Homebrew Cask installs a pkg that places:

```text
/Library/VirtConnector/bin/virt-connector
/Library/VirtConnector/VirtConnectorAgent.app
/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord
/usr/local/bin/virt-connector -> /Library/VirtConnector/bin/virt-connector
/usr/local/bin/virt-connectord -> /Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord
```

Installing the pkg does not register or start the LaunchAgent. The user explicitly enables the agent with:

```sh
virt-connector setup
```

When the Homebrew Cask is upgraded later, an existing enabled configuration is re-registered automatically so the LaunchAgent keeps running after the upgrade. Fresh installs without a configuration are not started automatically.

The signed package restores an enabled user's LaunchAgent from its installer script, outside Homebrew's flight-step sandbox. It runs `virt-connector restore-agent` as the console user. Missing, disabled, or invalid configurations are left untouched. If registration fails, installation is retained and a warning explains how to retry.

Do not run `sudo virt-connector setup`. The LaunchAgent must be registered for the logged-in user and Aqua session. The CLI rejects sudo execution.

## Shortcuts

VirtConnector delegates all device control to Shortcuts.

For example, to control `LED Strip`, create:

- `TurnOnLED`
  - Turns on `LED Strip` in Home.
- `TurnOffLED`
  - Turns off `LED Strip` in Home.

Shortcut names are arbitrary. Use the names you pass to `setup` or `device add`.

List available Shortcuts:

```sh
virt-connector shortcuts
```

## Setup

Default setup creates one device named `LED Strip` using `TurnOnLED` and `TurnOffLED`.

```sh
virt-connector setup
```

Explicit device and Shortcut names:

```sh
virt-connector setup --device "LED Strip" --on TurnOnLED --off TurnOffLED
```

Config file:

```text
~/.config/virt-connector/config.json
```

LaunchAgent plist:

```text
~/Library/LaunchAgents/st.rio.virt-connectord.plist
```

Logs:

```text
~/Library/Logs/virt-connectord.log
~/Library/Logs/virt-connectord.out.log
~/Library/Logs/virt-connectord.err.log
```

For tests and local development, override paths with:

```sh
export VIRT_CONNECTOR_CONFIG=/tmp/virt-connector/config.json
export VIRT_CONNECTOR_LOG_DIR=/tmp/virt-connector/logs
export VIRT_CONNECTOR_LAUNCH_AGENTS_DIR=/tmp/virt-connector/LaunchAgents
```

Agent registration records the resolved configuration and log paths in its plist. CLI actions reject a running agent that uses a different configuration; register the intended paths before using it. These overrides do not create a second independent agent for the same user.

Existing unreadable or invalid configurations cause an explicit error and are never replaced with empty defaults. Only initialization commands create a missing configuration. Legacy configurations may omit `enabled` (defaults to true), but must contain a valid `devices` array.

## Device Configuration

List devices:

```sh
virt-connector devices
```

Add a device:

```sh
virt-connector device add "LED Strip" \
  --on TurnOnLED \
  --off TurnOffLED \
  --display-on on \
  --display-off off \
  --power-off off
```

Change event actions:

```sh
virt-connector device set "LED Strip" \
  --display-on on \
  --display-off off \
  --power-off off
```

Valid actions:

- `on`
  - Runs the device's `--on` Shortcut.
- `off`
  - Runs the device's `--off` Shortcut.
- `none`
  - Does nothing for that event.

Remove a device:

```sh
virt-connector device remove "LED Strip"
```

Disable all automation:

```sh
virt-connector disable
```

Enable again:

```sh
virt-connector enable
```

`enable` also registers/starts the agent when needed, including after an upgrade performed while monitoring was disabled. `status` distinguishes configuration enablement from LaunchAgent registration and loading.

## Manual Testing

Run configured actions without waiting for macOS events:

```sh
virt-connector run display-on
virt-connector run display-off
virt-connector run power-off
```

Check status:

```sh
virt-connector status
```

## Shutdown

To complete `power_off` actions before requesting shutdown, use either:

- the VirtConnector menu bar item `Shut Down…`
- `virt-connector shutdown`

CLI:

```sh
virt-connector shutdown
```

This runs configured `power_off` actions, then asks macOS to shut down through System Events only if all required actions succeeded. Failures include the affected device and Shortcut; CLI commands return a nonzero exit status. When the agent is loaded, the CLI sends the request through the agent rather than starting competing Shortcuts. Connection errors and response timeouts never trigger an automatic standalone retry.

Apple menu shutdown remains best-effort: Shortcuts may already be unavailable and VirtConnector cannot cancel that external shutdown on a device-action failure.

If another application cancels macOS shutdown after VirtConnector has finished its actions, use the agent menu `Resume Monitoring…` or:

```sh
virt-connector resume
```

Only resume after canceling the OS shutdown. This command re-enables event handling; it does **not** cancel a pending macOS shutdown request or change a disabled configuration. Failed VirtConnector shutdown requests automatically return to normal event handling.

Shortcuts have a 30-second per-process deadline and a 120-second total action budget per event. A timeout is a failure, not a successful device action.

The menu shows monitoring status and the number of enabled devices. It distinguishes disabled automation, unavailable configuration, shutdown preparation, and a completed shutdown request. `Resume Monitoring…` becomes available after the shutdown request completes. Shutdown and resume confirmations have no default button and support Escape to cancel.

The menu bar UI switches between English and Japanese using `AppleLanguages`, via `Locale.preferredLanguages`.

## LaunchAgent Management

Restart the LaunchAgent:

```sh
virt-connector restart-agent
```

Remove the LaunchAgent:

```sh
virt-connector uninstall-agent
```

Install with an explicit daemon path:

```sh
virt-connector install-agent --daemon /path/to/virt-connectord
```

For normal Cask installs, `setup` automatically detects `/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord`.

## Homebrew Cask Distribution

The public release artifact is expected to be a signed, notarized, and stapled pkg:

```text
VirtConnector-<version>-signed.pkg
```

Cask definition:

```text
Casks/virt-connector.rb
```

The Cask URL assumes GitHub Releases:

```text
https://github.com/rioriost/Virt-Connector/releases/download/v#{version}/VirtConnector-#{version}-signed.pkg
```

The Cask is published in the `rioriost/homebrew-cask` tap.

## Packaging

Unsigned pkg for local testing:

```sh
scripts/build-pkg.sh --unsigned
```

Signed pkg requires these certificates in the login keychain:

- `Developer ID Application`
- `Developer ID Installer`

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" \
scripts/build-pkg.sh
```

Follow the [canonical release procedure](docs/releases/RELEASING.md) for public releases. The dedicated notary profile and signing identities are defined in `scripts/release-config.sh`.

Register credentials once in an interactive Terminal. Enter your Apple ID, then enter the app-specific password only at notarytool's hidden prompt:

```sh
scripts/notarytool-store-credentials.sh
```

Run preflight, then sign, notarize, staple, verify and update the Cask:

```sh
scripts/release.sh check
scripts/release.sh prepare
```

Update the Cask SHA256:

```sh
scripts/update-cask.sh dist/VirtConnector-0.1.7-signed.pkg
```

The repository's `VERSION` file is shared by the build and Cask updater. The updater checks the package's identifier and version before changing the Cask; a mismatched package is rejected. Always update the Cask from the final notarized and stapled artifact.

## Homebrew Formula

`Formula/virt-connector.rb` is a HEAD-only development definition, requiring explicit `--HEAD`. It does not provide a stable Formula release; use the Cask for supported packaged releases or the Swift build commands below for local development.

The intended distribution path for users is the Cask. The Cask can install `VirtConnectorAgent.app` through a pkg and is the right shape for a notarized macOS app-like tool.

## Build

```sh
swift build
swift build -c release
```

Regression tests use temporary configurations and substitute OS operations; they do not shut down the Mac or control real devices:

```sh
swift test
python3 -B -m unittest scripts/test-postinstall.py scripts/test-packaging.py
```

## License

MIT. See `LICENSE`.
