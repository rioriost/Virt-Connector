import AppKit
import Foundation
import VirtConnectorCore

@main
final class VirtConnectorDaemon: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
                self.refreshStatusMenu()
            }
        }
    )
    private let ownership = AgentOwnershipLock()
    private var ipcServer: AgentIPCServer?
    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem?
    private let localizer = AgentLocalizer()
    private lazy var interface = AgentInterface(localizer: localizer, target: self,
        shutdownAction: #selector(confirmAndShutdown), resumeAction: #selector(resumeMonitoring))

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
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = AgentInterface.statusImage()
            button.imagePosition = .imageOnly
            button.toolTip = "VirtConnector"
        }

        interface.menu.delegate = self
        statusItem.menu = interface.menu
        refreshStatusMenu()
        log.write("Installed status menu")
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        let state: AgentMenuState
        if coordinator.canResume {
            state = .shutdownRequested
        } else if coordinator.isShutdownPending {
            state = .preparingShutdown
        } else {
            do {
                let config = try configStore.load()
                let count = config.devices.filter(\.enabled).count
                state = config.enabled ? .monitoring(deviceCount: count) : .disabled
            } catch {
                state = .configurationUnavailable
            }
        }
        interface.update(state)
        statusItem?.button?.toolTip = interface.accessibilitySummary
        statusItem?.button?.setAccessibilityLabel(interface.accessibilitySummary)
    }

    @objc private func confirmAndShutdown() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = interface.shutdownAlert()

        guard alert.runModal() == .alertFirstButtonReturn else {
            log.write("Menu shutdown canceled")
            return
        }

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
        NSApp.activate(ignoringOtherApps: true)
        let alert = interface.resumeAlert()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try coordinator.resumeAfterCancelledShutdown()
        } catch {
            showError(error, title: localizer.resumeFailedTitle)
        }
    }

    private func showShutdownError(_ error: Error) {
        showError(error, title: localizer.shutdownFailedTitle)
    }

    private func showError(_ error: Error, title: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = interface.errorAlert(title: title, message: error.localizedDescription)
        alert.runModal()
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
