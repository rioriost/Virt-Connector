import AppKit

enum AgentMenuState {
    case monitoring(deviceCount: Int)
    case disabled
    case configurationUnavailable
    case preparingShutdown
    case shutdownRequested
}

/// Native presentation shared by the agent and the side-effect-free UI preview.
final class AgentInterface {
    let menu = NSMenu(title: "VirtConnector")
    private let localizer: AgentLocalizer
    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let shutdownItem: NSMenuItem
    private let resumeItem: NSMenuItem

    var accessibilitySummary: String {
        "VirtConnector — \(statusItem.title). \(detailItem.title)"
    }

    init(localizer: AgentLocalizer, target: AnyObject, shutdownAction: Selector, resumeAction: Selector) {
        self.localizer = localizer
        shutdownItem = NSMenuItem(title: localizer.shutdownMenuTitle, action: shutdownAction, keyEquivalent: "")
        resumeItem = NSMenuItem(title: localizer.resumeMenuTitle, action: resumeAction, keyEquivalent: "")
        shutdownItem.target = target
        resumeItem.target = target
        menu.autoenablesItems = false

        let heading = NSMenuItem(title: "VirtConnector", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        statusItem.isEnabled = false
        detailItem.isEnabled = false
        menu.addItem(heading)
        menu.addItem(statusItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())
        menu.addItem(resumeItem)
        menu.addItem(.separator())
        menu.addItem(shutdownItem)
        update(.configurationUnavailable)
    }

    func update(_ state: AgentMenuState) {
        statusItem.title = localizer.statusTitle(state)
        detailItem.title = localizer.statusDetail(state)
        switch state {
        case .preparingShutdown:
            shutdownItem.isEnabled = false
            resumeItem.isEnabled = false
        case .shutdownRequested:
            shutdownItem.isEnabled = false
            resumeItem.isEnabled = true
        case .configurationUnavailable:
            shutdownItem.isEnabled = false
            resumeItem.isEnabled = false
        case .monitoring, .disabled:
            shutdownItem.isEnabled = true
            resumeItem.isEnabled = false
        }
    }

    static func statusImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "power.circle", accessibilityDescription: "VirtConnector")?
            .withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
        image?.isTemplate = true
        return image
    }

    func shutdownAlert() -> NSAlert {
        confirmation(title: localizer.shutdownDialogTitle, message: localizer.shutdownDialogMessage,
                     action: localizer.shutdownButtonTitle, symbol: "power.circle.fill")
    }

    func resumeAlert() -> NSAlert {
        confirmation(title: localizer.resumeDialogTitle, message: localizer.resumeMessage,
                     action: localizer.resumeButtonTitle, symbol: "arrow.clockwise.circle")
    }

    private func confirmation(title: String, message: String, action: String, symbol: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let actionButton = alert.addButton(withTitle: action)
        let cancelButton = alert.addButton(withTitle: localizer.cancelButtonTitle)
        // Neither Return nor a default Cancel should bypass reading the consequences.
        actionButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = nil
        alert.window.initialFirstResponder = cancelButton
        return alert
    }

    func errorAlert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        return alert
    }
}
