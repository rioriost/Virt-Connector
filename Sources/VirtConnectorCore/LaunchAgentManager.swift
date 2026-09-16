import Foundation

public enum LaunchAgentError: LocalizedError {
    case invalidPlist(String)
    case invalidStartupTimeout
    case stateTransitionTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPlist(let path):
            return "Invalid managed LaunchAgent plist at \(path); reinstall with install-agent --daemon PATH."
        case .invalidStartupTimeout:
            return "LaunchAgent startup timeout must be finite and greater than zero."
        case .stateTransitionTimedOut(let state):
            return "LaunchAgent \(LaunchAgentManager.label) did not become \(state)."
        }
    }
}

public struct LaunchAgentManager {
    public static let label = "st.rio.virt-connectord"
    public static let commandTimeout: TimeInterval = 5

    private let processRunner: any ProcessRunning
    private let plistURL: URL
    private let logDirectory: URL
    private let configURL: URL
    private let startupTimeout: TimeInterval

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        plistURL: URL = ConfigStore.launchAgentsDirectoryURL().appendingPathComponent("\(LaunchAgentManager.label).plist"),
        logDirectory: URL = ConfigStore.logsDirectoryURL(),
        configURL: URL = ConfigStore.defaultConfigURL(),
        startupTimeout: TimeInterval = 5
    ) {
        self.processRunner = processRunner
        self.plistURL = plistURL.standardizedFileURL
        self.logDirectory = logDirectory.standardizedFileURL
        self.configURL = configURL.standardizedFileURL
        self.startupTimeout = startupTimeout
    }

    public func install(daemonPath: String) throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [URL(fileURLWithPath: daemonPath).standardizedFileURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ExitTimeOut": 30,
            "AssociatedBundleIdentifiers": [Self.label],
            "LimitLoadToSessionType": ["Aqua"],
            "MachServices": [Self.label: true],
            "StandardOutPath": logDirectory.appendingPathComponent("virt-connectord.out.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("virt-connectord.err.log").path,
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "VIRT_CONNECTOR_CONFIG": configURL.path,
                "VIRT_CONNECTOR_LOG_DIR": logDirectory.path
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    /// Refresh registration paths while preserving a previously selected custom daemon.
    /// The fallback is evaluated only when no managed plist exists.
    public func ensureRunning(daemonPath: @autoclosure () throws -> String) throws {
        let path: String
        if isInstalled {
            let data = try Data(contentsOf: plistURL)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["Label"] as? String == Self.label,
                  let arguments = plist["ProgramArguments"] as? [String],
                  arguments.count == 1, let executable = arguments.first, !executable.isEmpty else {
                throw LaunchAgentError.invalidPlist(plistURL.path)
            }
            path = executable
        } else {
            path = try daemonPath()
        }
        try install(daemonPath: path)
        try bootstrap()
    }

    public func bootstrap() throws {
        guard startupTimeout.isFinite, startupTimeout > 0 else {
            throw LaunchAgentError.invalidStartupTimeout
        }
        if try isLoaded() {
            _ = try launchctl(["bootout", serviceTarget()])
            try waitUntilUnloaded()
        }
        // A prior explicit launchctl disable otherwise prevents bootstrap.
        _ = try launchctl(["enable", serviceTarget()])
        _ = try launchctl(["bootstrap", serviceDomain(), plistURL.path])
        _ = try launchctl(["kickstart", serviceTarget()])
        try waitUntilRunning()
    }

    public func uninstall() throws {
        if try isLoaded() {
            _ = try launchctl(["bootout", serviceTarget()])
            try waitUntilUnloaded()
        }
        if isInstalled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    /// Only launchctl's explicit missing-service response means "not loaded".
    /// Permission errors, unavailable GUI domains and timeouts remain errors.
    public func isLoaded() throws -> Bool {
        let result = try launchctl(["print", serviceTarget()], allowNonZeroExit: true)
        if result.terminationStatus == 0 { return true }
        if isMissingService(result) { return false }
        throw commandError(["print", serviceTarget()], result: result)
    }

    /// A loaded job can be spawn-scheduled or crashed without a running process.
    public func isRunning() throws -> Bool {
        let result = try launchctl(["print", serviceTarget()], allowNonZeroExit: true)
        return try runningProcessID(result) != nil
    }

    public func printStatus() throws -> String {
        let result = try launchctl(["print", serviceTarget()], allowNonZeroExit: true)
        guard result.terminationStatus == 0 || isMissingService(result) else {
            throw commandError(["print", serviceTarget()], result: result)
        }
        return result.standardOutput + result.standardError
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public var installedPlistPath: String {
        plistURL.path
    }

    private func serviceDomain() -> String {
        "gui/\(getuid())"
    }

    private func serviceTarget() -> String {
        "\(serviceDomain())/\(Self.label)"
    }

    private func launchctl(
        _ arguments: [String], allowNonZeroExit: Bool = false,
        timeout: TimeInterval = LaunchAgentManager.commandTimeout
    ) throws -> ProcessResult {
        try processRunner.run(
            "/bin/launchctl", arguments,
            allowNonZeroExit: allowNonZeroExit, timeout: timeout
        )
    }

    private func isMissingService(_ result: ProcessResult) -> Bool {
        result.terminationStatus == 113
            && result.standardError.contains("Could not find service \"\(Self.label)\"")
    }

    private func commandError(_ arguments: [String], result: ProcessResult) -> ProcessRunnerError {
        .nonZeroExit(
            executable: "/bin/launchctl", arguments: arguments,
            status: result.terminationStatus, stderr: result.standardError
        )
    }

    private func waitUntilUnloaded() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if try !isLoaded() { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LaunchAgentError.stateTransitionTimedOut("unloaded")
    }

    private func runningProcessID(_ result: ProcessResult) throws -> Int32? {
        guard result.terminationStatus == 0 else {
            if isMissingService(result) { return nil }
            throw commandError(["print", serviceTarget()], result: result)
        }
        guard serviceField("state", in: result.standardOutput) == "running",
              let value = serviceField("pid", in: result.standardOutput),
              let pid = Int32(value), pid > 0 else {
            return nil
        }
        return pid
    }

    private func serviceField(_ name: String, in output: String) -> String? {
        // launchctl print indents job fields once; ignore similarly named nested fields.
        let prefix = "\t\(name) = "
        return output.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    private func waitUntilRunning() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
        var previousPID: Int32?
        var lastState = "unknown"
        var lastExit = "unknown"
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw LaunchAgentError.stateTransitionTimedOut(
                    "running with a stable PID (last state: \(lastState), last exit code: \(lastExit))"
                )
            }
            let result = try launchctl(
                ["print", serviceTarget()], allowNonZeroExit: true,
                timeout: min(Self.commandTimeout, remaining)
            )
            let pid = try runningProcessID(result)
            if let pid, pid == previousPID { return }
            previousPID = pid
            lastState = serviceField("state", in: result.standardOutput) ?? "not running"
            lastExit = serviceField("last exit code", in: result.standardOutput) ?? "unknown"
            Thread.sleep(forTimeInterval: min(0.1, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
    }
}
