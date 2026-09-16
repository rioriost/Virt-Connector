import Foundation
import XCTest
@testable import VirtConnectorCore

private final class RecordingLaunchctl: ProcessRunning {
    var loaded = false
    var calls: [[String]] = []
    var timeouts: [TimeInterval] = []
    var failureCommand: String?
    var printResult: ProcessResult?
    var bootstrapLoadsService = true
    var state = "running"
    var processID: Int32? = 12345
    var lastExitCode = 0
    var runningOutputs: [String] = []

    func run(
        _ executable: String, _ arguments: [String],
        allowNonZeroExit: Bool, timeout: TimeInterval
    ) throws -> ProcessResult {
        XCTAssertEqual(executable, "/bin/launchctl")
        calls.append(arguments)
        timeouts.append(timeout)
        if arguments.first == failureCommand {
            throw ProcessRunnerError.nonZeroExit(
                executable: executable, arguments: arguments, status: 1, stderr: "Denied"
            )
        }
        switch arguments.first {
        case "print":
            if let printResult { return printResult }
            if !loaded {
                return ProcessResult(
                    terminationStatus: 113, standardOutput: "",
                    standardError: "Could not find service \"\(LaunchAgentManager.label)\" in domain for user gui"
                )
            }
            let output = runningOutputs.isEmpty
                ? "service = {\n\tstate = \(state)\n\tpid = \(processID.map(String.init) ?? "")\n\tlast exit code = \(lastExitCode)\n}"
                : runningOutputs.removeFirst()
            return ProcessResult(terminationStatus: 0, standardOutput: output, standardError: "")
        case "bootstrap": loaded = bootstrapLoadsService
        case "bootout": loaded = false
        default: break
        }
        return ProcessResult(terminationStatus: 0, standardOutput: "loaded", standardError: "")
    }
}

final class LaunchAgentManagerTests: XCTestCase {
    func testCustomResolvedPathsAndMachServiceAreWrittenWithoutInheritedSecrets() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        let plist = directory.appendingPathComponent("agents/agent.plist")
        let config = directory.appendingPathComponent("custom & <config>/config.json")
        let logs = directory.appendingPathComponent("custom & <logs>")
        let daemon = directory.appendingPathComponent("custom & <daemon>").path
        let manager = LaunchAgentManager(processRunner: runner, plistURL: plist, logDirectory: logs, configURL: config)
        try manager.install(daemonPath: daemon)
        let object = try readPlist(plist)
        let environment = try XCTUnwrap(object["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(Set(environment.keys), ["PATH", "VIRT_CONNECTOR_CONFIG", "VIRT_CONNECTOR_LOG_DIR"])
        XCTAssertEqual(environment["VIRT_CONNECTOR_CONFIG"], config.path)
        XCTAssertEqual(environment["VIRT_CONNECTOR_LOG_DIR"], logs.path)
        XCTAssertEqual(object["MachServices"] as? [String: Bool], [LaunchAgentManager.label: true])
        XCTAssertEqual(object["ProgramArguments"] as? [String], [daemon])
        XCTAssertEqual(object["StandardOutPath"] as? String, logs.appendingPathComponent("virt-connectord.out.log").path)
        XCTAssertTrue(runner.calls.isEmpty, "Writing a plist must not execute launchctl")
    }

    func testEnsureRunningInstallsAndBootstrapsAnUnloadedAgent() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        let manager = makeManager(directory, runner: runner)
        XCTAssertFalse(manager.isInstalled)
        try manager.ensureRunning(daemonPath: "/custom/daemon")
        XCTAssertTrue(manager.isInstalled)
        XCTAssertTrue(try manager.isLoaded())
        XCTAssertEqual(runner.calls.map { $0[0] }, ["print", "enable", "bootstrap", "kickstart", "print", "print", "print"])
        XCTAssertTrue(runner.timeouts.allSatisfy { $0 > 0 && $0 <= LaunchAgentManager.commandTimeout })
    }

    func testEnsureRunningPreservesRegisteredCustomDaemonAndRefreshesEnvironment() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        let manager = makeManager(directory, runner: runner)
        try manager.install(daemonPath: "/custom/selected-daemon")
        let plistURL = URL(fileURLWithPath: manager.installedPlistPath)
        var legacyPlist = try readPlist(plistURL)
        legacyPlist.removeValue(forKey: "MachServices")
        legacyPlist["EnvironmentVariables"] = ["PATH": "/usr/bin"]
        try PropertyListSerialization.data(fromPropertyList: legacyPlist, format: .xml, options: 0).write(to: plistURL)
        let newConfig = directory.appendingPathComponent("new/config.json")
        let updatedManager = LaunchAgentManager(
            processRunner: runner, plistURL: URL(fileURLWithPath: manager.installedPlistPath),
            logDirectory: directory.appendingPathComponent("logs"), configURL: newConfig
        )
        func unexpectedFallback() throws -> String {
            XCTFail("An installed custom daemon must not require default daemon discovery")
            throw LaunchAgentError.invalidPlist("unused")
        }
        try updatedManager.ensureRunning(daemonPath: try unexpectedFallback())
        let plist = try readPlist(URL(fileURLWithPath: manager.installedPlistPath))
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/custom/selected-daemon"])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?["VIRT_CONNECTOR_CONFIG"], newConfig.path)
        XCTAssertEqual(plist["MachServices"] as? [String: Bool], [LaunchAgentManager.label: true])
        XCTAssertTrue(try manager.isLoaded())
        XCTAssertTrue(try manager.isRunning())
    }

    func testBootstrapWaitsForUnloadAndVerifiesLoad() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        runner.loaded = true
        let manager = makeManager(directory, runner: runner)
        try manager.bootstrap()
        XCTAssertEqual(runner.calls.map { $0[0] }, ["print", "bootout", "print", "enable", "bootstrap", "kickstart", "print", "print"])
    }

    func testBootstrapAndBootoutFailuresAreNotHidden() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for command in ["bootout", "enable", "bootstrap", "kickstart"] {
            let runner = RecordingLaunchctl()
            runner.loaded = command == "bootout"
            runner.failureCommand = command
            let manager = makeManager(directory, runner: runner)
            XCTAssertThrowsError(try manager.bootstrap(), command)
            XCTAssertEqual(runner.calls.last?.first, command)
        }
        let runner = RecordingLaunchctl()
        runner.bootstrapLoadsService = false
        XCTAssertThrowsError(try makeManager(directory, runner: runner).bootstrap())
    }

    func testLoadedDetectionOnlyAcceptsExplicitMissingService() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        let manager = makeManager(directory, runner: runner)
        XCTAssertFalse(try manager.isLoaded())
        for (status, message) in [
            (1, "Operation not permitted"),
            (113, "Could not find domain for user gui"),
            (113, "Unexpected launchctl failure"),
            (1, "Could not find service \"\(LaunchAgentManager.label)\"")
        ] {
            runner.printResult = ProcessResult(terminationStatus: Int32(status), standardOutput: "", standardError: message)
            XCTAssertThrowsError(try manager.isLoaded(), message)
            XCTAssertThrowsError(try manager.isRunning(), message)
            XCTAssertThrowsError(try manager.printStatus(), message)
        }
        runner.failureCommand = "print"
        XCTAssertThrowsError(try manager.isLoaded())
    }

    func testRunningRequiresTopLevelRunningStateAndPositivePID() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        let manager = makeManager(directory, runner: runner)
        XCTAssertFalse(try manager.isRunning())
        runner.loaded = true
        for (state, pid, expected) in [
            ("running", Int32(123), true),
            ("running", Int32(0), false),
            ("running", Int32(-1), false),
            ("running", nil, false),
            ("spawn scheduled", nil, false),
            ("exited", Int32(123), false)
        ] {
            runner.state = state
            runner.processID = pid
            XCTAssertTrue(try manager.isLoaded())
            XCTAssertEqual(try manager.isRunning(), expected, "\(state), \(String(describing: pid))")
        }
        runner.printResult = ProcessResult(
            terminationStatus: 0,
            standardOutput: "service = {\n\tstate = spawn scheduled\n\tenvironment = {\n\t\tstate = running\n\t\tpid = 123\n\t}\n}",
            standardError: ""
        )
        XCTAssertFalse(try manager.isRunning(), "Nested fields must not make a failed job appear running")
    }

    func testBootstrapRejectsLoadedSpawnFailuresWithinStartupDeadline() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (state, exitCode) in [("spawn scheduled", 78), ("exited", 1), ("running", 0)] {
            let runner = RecordingLaunchctl()
            runner.state = state
            runner.processID = nil
            runner.lastExitCode = exitCode
            let manager = makeManager(directory, runner: runner, startupTimeout: 0.02)
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try manager.bootstrap()) { error in
                XCTAssertTrue(error.localizedDescription.contains("stable PID"))
                XCTAssertTrue(error.localizedDescription.contains("last exit code: \(exitCode)"))
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
            XCTAssertTrue(runner.loaded, "Loaded registration alone must not count as startup success")
            XCTAssertFalse(try manager.isRunning())
            XCTAssertTrue(runner.timeouts.allSatisfy { $0 > 0 && $0 <= LaunchAgentManager.commandTimeout })
        }
    }

    func testTransientRunningPIDFollowedByCrashDoesNotCountAsStarted() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        runner.state = "spawn scheduled"
        runner.processID = nil
        runner.lastExitCode = 78
        runner.runningOutputs = ["service = {\n\tstate = running\n\tpid = 123\n}"]
        let manager = makeManager(directory, runner: runner, startupTimeout: 0.25)
        XCTAssertThrowsError(try manager.bootstrap())
        XCTAssertFalse(try manager.isRunning())
    }

    func testChangedPIDMustBeObservedAgainBeforeStartupSucceeds() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        runner.runningOutputs = [123, 456, 456].map { "service = {\n\tstate = running\n\tpid = \($0)\n}" }
        try makeManager(directory, runner: runner, startupTimeout: 0.5).bootstrap()
        XCTAssertTrue(runner.runningOutputs.isEmpty)
        XCTAssertEqual(runner.calls.filter { $0.first == "print" }.count, 4)
    }

    func testInvalidStartupTimeoutDoesNotExecuteLaunchctl() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for timeout in [0, -1, TimeInterval.infinity, TimeInterval.nan] {
            let runner = RecordingLaunchctl()
            XCTAssertThrowsError(try makeManager(directory, runner: runner, startupTimeout: timeout).bootstrap())
            XCTAssertTrue(runner.calls.isEmpty)
        }
    }

    func testUninstallRetainsPlistWhenBootoutFails() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        runner.loaded = true
        runner.failureCommand = "bootout"
        let manager = makeManager(directory, runner: runner)
        try manager.install(daemonPath: "/custom/daemon")
        XCTAssertThrowsError(try manager.uninstall())
        XCTAssertTrue(manager.isInstalled)
        runner.failureCommand = nil
        try manager.uninstall()
        XCTAssertFalse(manager.isInstalled)
        XCTAssertFalse(runner.loaded)
    }

    func testInvalidRegisteredPlistIsNotOverwritten() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingLaunchctl()
        let manager = makeManager(directory, runner: runner)
        let url = URL(fileURLWithPath: manager.installedPlistPath)
        let data = Data("invalid plist".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try manager.ensureRunning(daemonPath: "/default/daemon"))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    private func makeManager(
        _ directory: URL, runner: RecordingLaunchctl, startupTimeout: TimeInterval = 0.5
    ) -> LaunchAgentManager {
        LaunchAgentManager(
            processRunner: runner, plistURL: directory.appendingPathComponent("agent.plist"),
            logDirectory: directory.appendingPathComponent("logs"),
            configURL: directory.appendingPathComponent("config.json"),
            startupTimeout: startupTimeout
        )
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
}
