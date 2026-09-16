import Foundation

public struct ActionFailure: Codable, Equatable {
    public let device: String
    public let shortcut: String
    public let message: String
}

public struct ActionExecutionResult: Codable, Equatable {
    public let attempted: Int
    public let failures: [ActionFailure]
    public var failed: Int { failures.count }

    public init(attempted: Int = 0, failures: [ActionFailure] = []) {
        self.attempted = attempted
        self.failures = failures
    }

    public func requireSuccess() throws {
        if !failures.isEmpty {
            throw ActionExecutionError(result: self)
        }
    }
}

public struct ActionExecutionError: LocalizedError {
    public let result: ActionExecutionResult

    public var errorDescription: String? {
        let details = result.failures.map { "\($0.device) [\($0.shortcut)]: \($0.message)" }
        return "Shortcut actions failed: attempted=\(result.attempted) failed=\(result.failed)\n"
            + details.joined(separator: "\n")
    }
}

public struct ActionExecutor {
    private let shortcutRunner: ShortcutRunner
    private let log: FileLog?

    public init(shortcutRunner: ShortcutRunner = ShortcutRunner(), log: FileLog? = nil) {
        self.shortcutRunner = shortcutRunner
        self.log = log
    }

    @discardableResult
    public func execute(trigger: PowerTrigger, config: VirtConnectorConfig) -> ActionExecutionResult {
        guard config.enabled else {
            log?.write("Skipping \(trigger.rawValue): monitoring is disabled")
            return ActionExecutionResult()
        }

        var attempted = 0
        var failures: [ActionFailure] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 120

        for device in config.devices where device.enabled {
            let action = device.actions.action(for: trigger)
            guard let shortcutName = device.shortcutName(for: action) else {
                log?.write("Skipping \(device.name) for \(trigger.rawValue): action is none")
                continue
            }

            attempted += 1
            log?.write("Running shortcut '\(shortcutName)' for \(device.name) on \(trigger.rawValue)")

            do {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    throw ActionDeadlineError()
                }
                try shortcutRunner.runShortcut(named: shortcutName, timeout: min(30, remaining))
            } catch {
                failures.append(ActionFailure(
                    device: device.name, shortcut: shortcutName, message: error.localizedDescription
                ))
                log?.write("Shortcut '\(shortcutName)' failed for \(device.name): \(error.localizedDescription)")
            }
        }

        log?.write("Completed \(trigger.rawValue): attempted=\(attempted) failed=\(failures.count)")
        return ActionExecutionResult(attempted: attempted, failures: failures)
    }
}

private struct ActionDeadlineError: LocalizedError {
    var errorDescription: String? { "The event's 120-second action deadline was exceeded" }
}
