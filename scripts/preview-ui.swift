// Compile with AgentInterface.swift and AgentLocalizer.swift; see the GUI review record.
// No core, IPC, configuration writes, Shortcuts, or shutdown services are linked.
import AppKit

@main
final class InterfacePreview: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var presentedAlert: NSAlert?
    private var interface: AgentInterface!
    private var statusItem: NSStatusItem!
    private let statePicker = NSPopUpButton()
    private let resultLabel = NSTextField(labelWithString: "No action performed")
    private let states: [AgentMenuState] = [
        .monitoring(deviceCount: 2), .monitoring(deviceCount: 0), .disabled,
        .configurationUnavailable, .preparingShutdown, .shutdownRequested
    ]

    static func main() {
        let app = NSApplication.shared
        let delegate = InterfacePreview()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let localizer = AgentLocalizer(preferredLanguages: [CommandLine.arguments.contains("--ja") ? "ja" : "en"])
        interface = AgentInterface(localizer: localizer, target: self,
            shutdownAction: #selector(shutdown), resumeAction: #selector(resume))
        if CommandLine.arguments.contains("--check") {
            checkSafetyAndRecovery()
            print("UI checks passed: Return safety, Escape, state gating, recovery, labels, localization")
            NSApp.terminate(nil)
            return
        }
        NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        if CommandLine.arguments.contains("--show-alert") {
            let alert = CommandLine.arguments.contains("--resume") ? interface.resumeAlert() : interface.shutdownAlert()
            presentedAlert = alert
            alert.layout()
            alert.window.title = "VirtConnector Alert Preview"
            alert.window.center()
            alert.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AgentInterface.statusImage()
        statusItem.menu = interface.menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 290),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "VirtConnector UI Preview"
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "VirtConnector · UI Preview")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(NSTextField(labelWithString: "Sample data only. No device or system actions."))
        statePicker.addItems(withTitles: ["Monitoring · 2 devices", "No enabled devices", "Automation off",
                                         "Configuration unavailable", "Preparing shutdown", "Shutdown requested"])
        statePicker.target = self
        statePicker.action = #selector(changeState)
        statePicker.setAccessibilityLabel("Preview state")
        stack.addArrangedSubview(statePicker)
        for (title, action) in [("Open Menu", #selector(openMenu(_:))),
                                ("Shutdown Dialog", #selector(shutdown)),
                                ("Resume Error", #selector(showError))] {
            stack.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(resultLabel)
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24)
        ])
        changeState()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func changeState() {
        interface.update(states[statePicker.indexOfSelectedItem])
        statusItem.button?.setAccessibilityLabel(interface.accessibilitySummary)
        statusItem.button?.toolTip = interface.accessibilitySummary
    }

    @objc private func openMenu(_ sender: NSButton) {
        interface.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func shutdown() {
        let result = interface.shutdownAlert().runModal()
        resultLabel.stringValue = result == .alertFirstButtonReturn ? "Confirmed (preview only)" : "Canceled"
        if result == .alertFirstButtonReturn {
            statePicker.selectItem(at: 5)
            changeState()
        }
    }

    @objc private func resume() {
        let result = interface.resumeAlert().runModal()
        resultLabel.stringValue = result == .alertFirstButtonReturn ? "Resumed (preview only)" : "Canceled"
        if result == .alertFirstButtonReturn {
            statePicker.selectItem(at: 0)
            changeState()
        }
    }

    @objc private func showError() {
        let localizer = AgentLocalizer(preferredLanguages: [CommandLine.arguments.contains("--ja") ? "ja" : "en"])
        interface.errorAlert(title: localizer.resumeFailedTitle,
            message: "The agent is stopping; no additional device actions will be started.").runModal()
    }

    private func checkSafetyAndRecovery() {
        for language in ["ja-JP", "en-US"] {
            let strings = AgentLocalizer(preferredLanguages: [language])
            let ui = AgentInterface(localizer: strings, target: self,
                shutdownAction: #selector(shutdown), resumeAction: #selector(resume))
            for alert in [ui.shutdownAlert(), ui.resumeAlert()] {
                alert.layout()
                precondition(alert.window.defaultButtonCell == nil)
                precondition(alert.buttons[0].keyEquivalent.isEmpty)
                precondition(alert.buttons[1].keyEquivalent == "\u{1b}")
            }
            let shutdown = ui.menu.items.first { $0.action == #selector(shutdown) }!
            let resume = ui.menu.items.first { $0.action == #selector(resume) }!
            for (state, canShutdown, canResume) in [
                (AgentMenuState.monitoring(deviceCount: 2), true, false),
                (.preparingShutdown, false, false), (.shutdownRequested, false, true),
                (.monitoring(deviceCount: 2), true, false), (.disabled, true, false),
                (.configurationUnavailable, false, false), (.monitoring(deviceCount: 0), true, false)
            ] {
                ui.update(state)
                precondition(shutdown.isEnabled == canShutdown && resume.isEnabled == canResume)
                precondition(!resume.isHidden && !shutdown.isHidden)
                precondition(!ui.accessibilitySummary.isEmpty)
            }
            precondition(strings.resumeFailedTitle != strings.shutdownFailedTitle)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
