# macOS GUI update — 2026-09-21

## Scope and design contract

Improve the existing AppKit menu bar utility: expose monitoring state first, keep recovery discoverable, and separate recovery from system shutdown. Retain native menus, alerts, SF Symbols, system typography and appearance. Support pointer and keyboard input, Japanese and English, and meaningful accessibility labels. No new configuration UI, device access, animation, or changes to the Shortcuts/coordinator/LaunchAgent architecture. Deployment target remains macOS 13.

Baseline: `a724ca2`, clean working tree. The original UI consisted of two commands without monitoring status, a manually rasterized menu icon, and a shutdown confirmation with a Return default. The resume error used the shutdown failure title. Baseline observations are from source; a pre-change screenshot was not obtained because computer-use access to the installed accessory app timed out.

## Changes

| ID | Finding and change | Evidence / scope |
| --- | --- | --- |
| GUI-01 | Show monitoring and enabled-device count, no enabled devices, automation off, unreadable configuration, shutdown preparation, or shutdown requested. Refresh on opening the menu and coordinator transitions. | OBSERVATION: existing states were invisible. Text communicates state without depending on color. |
| GUI-02 | Keep both commands visible, disable them when unavailable, shorten the resume label, and separate system shutdown with a divider. Explain recovery eligibility in the status area and confirmation. | APPLE-HIG: stable menus and familiar native behavior; grouping and wording are product judgments. |
| GUI-03 | Remove the default action from both confirmations, focus Cancel initially, and explicitly support Escape. Retain action-first response mapping and specific action titles. | APPLE-HIG permits no default when reading consequences matters. This is a deliberate safety choice, not a claim that HIG forbids Return defaults for intentional shutdown. Cancel is not assigned as the default button. |
| GUI-04 | Use native SF Symbol configuration and standard square status-item sizing instead of drawing into a fixed bitmap. Include monitoring state in the tooltip and accessibility name. | APPLE-HIG: symbol/template support and meaningful, non-color state information. No assertion of universal icon dimensions. |
| GUI-05 | Use a resume-specific failure title; reserve warning presentation for failures, with informational confirmation and a relevant symbol. | OBSERVATION: resume failures previously appeared as shutdown failures. |

Presentation lives in `AgentInterface.swift` and `AgentLocalizer.swift`, shared with a side-effect-free preview. The entry file was renamed to `VirtConnectorDaemon.swift`: after splitting the source, the packaging build's native SwiftPM backend requires avoiding a `main.swift` filename alongside `@main`. The daemon entry point itself is unchanged.

## Current source ledger

Retrieved 2026-09-21. HIG pages were read through Apple's official DocC data using the skill's reader because HTML required JavaScript. These are scoped guidance references, not a complete HIG audit or distribution review.

| Kind | Primary source | Applied guidance |
| --- | --- | --- |
| APPLE-HIG | [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | Familiar menu and keyboard interaction. |
| APPLE-HIG | [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) | Prefer a menu for a simple menu bar extra; use a template symbol; retain unavailable commands as disabled. |
| APPLE-HIG | [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) | Clear action names, cancellation, no default when deliberate reading matters, restrained caution styling. Intentional destructive actions do not automatically require destructive styling. |
| APPLE-HIG / ACCESSIBILITY | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Native semantics, meaningful labels, keyboard access, and text rather than color alone. |
| APPLE-SDK | [NSAlert](https://developer.apple.com/documentation/appkit/nsalert) | Native modal presentation, button responses, icons and layout. Read Apple's Markdown representation. |
| APPLE-RESOURCE | [Apple releases](https://developer.apple.com/news/releases/) | Public macOS 27.0 (26A428), September 14; macOS 27.2 beta (26B5086k), September 16, listed separately. No beta-specific API adopted. |

Local environment: Apple Silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a), SDK 27.0. The release binary's `LC_BUILD_VERSION` confirms minimum macOS 13.0.

## Verification

| Check | Result and limits |
| --- | --- |
| Debug build / existing tests | PASS: `swift test`, 58 tests, 0 failures, after the final entry-file rename. Includes shutdown coordination and recovery tests using substitutes for OS/device actions. |
| Packaging-compatible release build | PASS: `swift build -c release --build-system native --triple arm64-apple-macosx13.0`. Native backend deprecation warning only; retained because the packaging script uses it. |
| UI regression checks | PASS: preview `--check` for Japanese and English. No default button after layout; Escape key; monitoring → preparing → requested → monitoring gating; disabled/error/empty states; commands stay visible; resume-specific error title. |
| Visual inspection | PASS for actual native Japanese/light shutdown and English/dark resume alerts. Inspected computer-use screenshots for clipping, wrapping, action placement and visible focus. Native layout stacks longer English buttons. |
| Menu runtime semantics | PASS: Japanese monitoring menu shows count; shutdown-requested menu enables resume and disables shutdown. Inspected actual accessibility tree. Menu screenshot capture returned the owning window, so the menu's visual comparison is not verified. |
| Keyboard / recovery | PASS in the preview: Return leaves the shutdown confirmation open, Escape cancels, Tab moves from Cancel to Resume Monitoring, Space confirms simulated resume, and the preview returns to monitoring. Global `AppleKeyboardUIMode` was 2. |
| Accessibility tree | PASS for observed native roles, localized button names, disabled menu states, and initial Cancel focus in modal confirmations. This is not a VoiceOver task-execution test. |
| Older OS, VoiceOver, contrast/transparency/text-size preferences | NOT RUN. Native controls were retained, but macOS 13 runtime, VoiceOver speech/order, Increase Contrast, Reduce Transparency and enlarged system text were not exercised. |
| Motion / resizable content | NOT APPLICABLE to this change: no custom animation or resizable content window. |
| Production actions / installation | NOT RUN. Preview links only presentation code and cannot issue device or system actions. Installed agent, configuration and service registration were not replaced. |

An attempted offscreen bitmap render did not reproduce native alert backgrounds/buttons faithfully and was discarded as visual evidence. The visual results above come from visible native alert windows.

## Reproduce UI checks

Run in an interactive macOS session from the repository root:

```sh
mkdir -p .build/ui-review
swiftc -parse-as-library \
  Sources/VirtConnectorDaemon/AgentInterface.swift \
  Sources/VirtConnectorDaemon/AgentLocalizer.swift \
  scripts/preview-ui.swift -o .build/ui-review/preview-ui
.build/ui-review/preview-ui --check
.build/ui-review/preview-ui --ja
```

Use the preview state picker and Open Menu button to inspect all states. No preview action calls Shortcuts, XPC, or system shutdown. For isolated visual inspection, use `--ja --show-alert` or `--dark --show-alert --resume`; this displays the same laid-out native alert without running its modal action loop. Use the normal preview for interaction tests.

Build and test logs from this run are under `.build/ui-review/`; generated preview artifacts are ignored by Git. README menu labels and behavior descriptions were updated in both languages.
