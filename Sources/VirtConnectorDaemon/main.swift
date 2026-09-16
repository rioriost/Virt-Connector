import AppKit
import Foundation
import VirtConnectorCore

@main
final class VirtConnectorDaemon: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private let log = FileLog.daemonLog()
    private let cancellation = ProcessCancellation()
    private lazy var executor = ActionExecutor(
        shortcutRunner: ShortcutRunner(processRunner: ProcessRunner(cancellation: cancellation)),
        log: log
    )
    private lazy var shutdownPerformer = ShutdownPerformer(
        configStore: configStore,
        actionExecutor: executor,
        processRunner: ProcessRunner(cancellation: cancellation),
        log: log
    )

    private lazy var coordinator: PowerEventCoordinator = PowerEventCoordinator(
        execute: { [unowned self] trigger in
            let config = try self.configStore.load()
            return self.executor.execute(trigger: trigger, config: config)
        },
        requestShutdown: { [unowned self] in try self.shutdownPerformer.requestShutdown() },
        log: { [log] message in log.write(message) },
        stateChanged: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.shutdownMenuItem?.isEnabled = !self.coordinator.isShutdownPending
                self.resumeMenuItem?.isEnabled = self.coordinator.canResume
            }
        }
    )
    private let ownership = AgentOwnershipLock()
    private var ipcServer: AgentIPCServer?
    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem?
    private var shutdownMenuItem: NSMenuItem?
    private var resumeMenuItem: NSMenuItem?
    private let localizer = AgentLocalizer()

    static func main() {
        let daemon = VirtConnectorDaemon()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = daemon
        do {
            try daemon.start()
            withExtendedLifetime(daemon) { app.run() }
        } catch {
            daemon.log.write("Unable to start agent: \(error.localizedDescription)")
            exit(1)
        }
    }

    private func start() throws {
        guard try ownership.acquire() else {
            throw AgentCommunicationError("Another agent or standalone command owns device execution.")
        }
        log.write("virt-connectord starting")
        _ = executor
        _ = shutdownPerformer
        let server = AgentIPCServer(coordinator: coordinator, configURL: configStore.configURL)
        ipcServer = server
        server.start()
        ProcessInfo.processInfo.disableSuddenTermination()
        log.write("NSApplication initialized with accessory activation policy")
        installStatusMenu()
        observeDisplayPowerEvents()
        observePowerOff()
        observeSignals()
        log.write("virt-connectord started")
    }

    private func observeDisplayPowerEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator.handleDisplayEvent(.displayOff, reason: "NSWorkspace.screensDidSleepNotification")
        }

        workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator.handleDisplayEvent(.displayOn, reason: "NSWorkspace.screensDidWakeNotification")
        }

        workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator.handleDisplayEvent(.displayOff, reason: "NSWorkspace.willSleepNotification")
        }

        workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator.handleDisplayEvent(.displayOn, reason: "NSWorkspace.didWakeNotification")
        }

        log.write("Installed NSWorkspace display sleep/wake observers")
    }

    private func observePowerOff() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.log.write("Received NSWorkspace.willPowerOffNotification")
            self.coordinator.shutdown(requestSystemShutdown: false) { [log = self.log] result in
                if case .failure(let error) = result {
                    log.write("Best-effort power_off failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func observeSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.log.write("Received signal \(signalNumber), canceling work without power_off action")
                self.cancellation.cancel()
                self.ipcServer?.stop()
                self.coordinator.stop { exit(0) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func installStatusMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: 32)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = makeStatusImage()
            button.imagePosition = .imageOnly
            button.toolTip = "VirtConnector"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let shutdownItem = NSMenuItem(
            title: localizer.shutdownMenuTitle,
            action: #selector(confirmAndShutdown),
            keyEquivalent: ""
        )
        shutdownItem.target = self
        menu.addItem(shutdownItem)
        self.shutdownMenuItem = shutdownItem
        let resumeItem = NSMenuItem(
            title: localizer.resumeMenuTitle, action: #selector(resumeMonitoring), keyEquivalent: ""
        )
        resumeItem.target = self
        resumeItem.isEnabled = false
        menu.addItem(resumeItem)
        resumeMenuItem = resumeItem

        statusItem.menu = menu
        log.write("Installed status menu")
    }

    @objc private func confirmAndShutdown() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = localizer.shutdownDialogTitle
        alert.informativeText = localizer.shutdownDialogMessage
        alert.alertStyle = .warning
        alert.icon = makeShutdownAlertIcon()
        alert.addButton(withTitle: localizer.shutdownButtonTitle)
        alert.addButton(withTitle: localizer.cancelButtonTitle)

        guard alert.runModal() == .alertFirstButtonReturn else {
            log.write("Menu shutdown canceled")
            return
        }

        shutdownMenuItem?.isEnabled = false
        log.write("Menu shutdown requested")

        coordinator.shutdown { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let outcome):
                self.log.write("Menu shutdown action completed: attempted=\(outcome.attempted) failed=\(outcome.failed)")
            case .failure(let error):
                DispatchQueue.main.async {
                    self.showShutdownError(error)
                }
            }
        }
    }

    @objc private func resumeMonitoring() {
        let alert = NSAlert()
        alert.messageText = localizer.resumeMenuTitle
        alert.informativeText = localizer.resumeMessage
        alert.addButton(withTitle: localizer.resumeButtonTitle)
        alert.addButton(withTitle: localizer.cancelButtonTitle)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try coordinator.resumeAfterCancelledShutdown()
        } catch {
            showShutdownError(error)
        }
    }

    private func showShutdownError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = localizer.shutdownFailedTitle
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func makeStatusImage() -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: "power.circle",
            accessibilityDescription: "VirtConnector"
        ) else {
            return nil
        }

        let image = NSImage(size: NSSize(width: 28, height: 22))
        image.lockFocus()

        let symbolSize = NSSize(width: 17, height: 17)
        let rect = NSRect(
            x: (image.size.width - symbolSize.width) / 2,
            y: (image.size.height - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        symbol.draw(in: rect)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func makeShutdownAlertIcon() -> NSImage? {
        NSImage(systemSymbolName: "power.circle.fill", accessibilityDescription: localizer.shutdownDialogTitle)
            ?? NSImage(named: NSImage.cautionName)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        if coordinator.isShutdownPending {
            coordinator.whenReadyToTerminate(reply)
        } else {
            cancellation.cancel()
            coordinator.stop(completion: reply)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer?.stop()
        log.write("Application terminating without additional power_off actions")
    }
}

private struct AgentLocalizer {
    private let languageCode: String

    init(preferredLanguages: [String] = Locale.preferredLanguages) {
        languageCode = preferredLanguages.first?.lowercased() ?? "en"
    }

    var shutdownMenuTitle: String {
        isJapanese ? "システム終了..." : "Shut Down..."
    }

    var shutdownDialogTitle: String {
        isJapanese ? "このMacをシステム終了しますか？" : "Shut Down This Mac?"
    }

    var shutdownDialogMessage: String {
        if isJapanese {
            return "設定済みの電源オフ動作に成功した後、macOSのシステム終了を要求します。動作に失敗した場合は終了を中止します。"
        }
        return "VirtConnector requests macOS shutdown only after configured power-off actions succeed. Failed actions cancel this request."
    }

    var shutdownButtonTitle: String {
        isJapanese ? "システム終了" : "Shut Down"
    }

    var cancelButtonTitle: String {
        isJapanese ? "キャンセル" : "Cancel"
    }

    var shutdownFailedTitle: String {
        isJapanese ? "システム終了に失敗しました" : "Shutdown Failed"
    }

    var resumeMenuTitle: String {
        isJapanese ? "終了キャンセル後に監視を再開..." : "Resume After Canceled Shutdown..."
    }

    var resumeButtonTitle: String {
        isJapanese ? "監視を再開" : "Resume Monitoring"
    }

    var resumeMessage: String {
        if isJapanese {
            return "macOSの終了をキャンセル済みの場合だけ再開してください。この操作自体はmacOSの終了要求を取り消しません。"
        }
        return "Resume only after canceling macOS shutdown. This action does not cancel the operating system's shutdown request."
    }

    private var isJapanese: Bool {
        languageCode == "ja" || languageCode.hasPrefix("ja-") || languageCode.hasPrefix("ja_")
    }
}
