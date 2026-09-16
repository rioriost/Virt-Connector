import Foundation

public struct ShutdownPerformer {
    private let configStore: ConfigStore
    private let actionExecutor: ActionExecutor
    private let processRunner: any ProcessRunning
    private let log: FileLog?

    public init(
        configStore: ConfigStore = ConfigStore(),
        actionExecutor: ActionExecutor = ActionExecutor(),
        processRunner: any ProcessRunning = ProcessRunner(),
        log: FileLog? = nil
    ) {
        self.configStore = configStore
        self.actionExecutor = actionExecutor
        self.processRunner = processRunner
        self.log = log
    }

    @discardableResult
    public func perform() throws -> ActionExecutionResult {
        let config = try configStore.load()
        let result = actionExecutor.execute(trigger: .powerOff, config: config)
        try result.requireSuccess()
        try requestShutdown()
        return result
    }

    public func requestShutdown() throws {
        log?.write("Requesting macOS shutdown after power_off actions")
        _ = try processRunner.run(
            "/usr/bin/osascript",
            ["-e", "tell application \"System Events\" to shut down"],
            timeout: 120
        )
    }
}
