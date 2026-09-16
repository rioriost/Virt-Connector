import Foundation
import XCTest
@testable import VirtConnectorCore

final class CLIValidationTests: XCTestCase {
    private var validatedExecutable: URL?

    func testInvalidArgumentsReturnUsageErrorWithoutChangingConfiguration() throws {
        try requireNonRoot()
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(VirtConnectorConfig(devices: [
            ShortcutDevice(name: "Review", onShortcut: "NeverRunOn", offShortcut: "NeverRunOff")
        ]))
        let original = try Data(contentsOf: store.configURL)
        let commands: [[String]] = [
            ["device", "set", "Review", "--enabled"],
            ["device", "set", "Review", "--display-of", "none"],
            ["device", "set", "Review", "--on", "--off", "NeverRunOff"],
            ["device", "set", "Review", "--enabled", "invalid"],
            ["device", "set", "Review", "--power-off", "invalid"],
            ["device", "set", "Review", "--name", "New", "--unknown", "value"],
            ["device", "set", "Review", "--name", "New", "extra"],
            ["device", "set", "Review", "--enabled", "true", "--enabled", "false"],
            ["device", "set", "Review", "--name", ""],
            ["device", "set", "Review"],
            ["device", "remove", "Review", "extra"],
            ["device", "add", "New", "--on", "On", "--off"],
            ["device", "add", "New", "--on", "On", "--off", "Off", "--enabled", "false"],
            ["setup", "--device", "New", "--unknown", "value"],
            ["setup", "--daemon"],
            ["install-agent", "--on", "NeverRun"],
            ["install-agent", "--daemon", "/unused", "extra"],
            ["status", "--unknown"],
            ["enable", "--unknown"],
            ["disable", "extra"],
            ["devices", "extra"],
            ["restore-agent", "extra"],
            ["restart-agent", "--daemon", "/unused"],
            ["uninstall-agent", "extra"],
            ["shortcuts", "extra"],
            ["run", "display-on", "extra"],
            ["run", "--unknown"],
            ["shutdown", "extra"],
            ["resume", "extra"],
            ["resume", "--unknown"],
            ["help", "extra"]
        ]
        for arguments in commands {
            let result = try invoke(arguments, directory: directory)
            XCTAssertEqual(result.terminationStatus, 2, "\(arguments): \(result.standardError)")
            XCTAssertTrue(result.standardError.contains("error:"), "\(arguments)")
            XCTAssertEqual(try Data(contentsOf: store.configURL), original, "\(arguments)")
        }
    }

    func testMalformedConfigurationNeverGetsOverwrittenByMutationCommands() throws {
        try requireNonRoot()
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        for json in ["{", #"{"enabled":true}"#, #"{"devices":[{}]}"#, #"{"devices":"invalid"}"#] {
            let original = Data(json.utf8)
            try original.write(to: url)
            for arguments in [
                ["disable"], ["enable"],
                ["setup", "--daemon", "/unused/daemon"],
                ["device", "add", "New", "--on", "NeverRunOn", "--off", "NeverRunOff"],
                ["device", "set", "Review", "--enabled", "false"],
                ["device", "remove", "Review"],
                ["devices"], ["status"]
            ] {
                let result = try invoke(arguments, directory: directory)
                XCTAssertEqual(result.terminationStatus, 1, "\(arguments), \(json): \(result.standardError)")
                XCTAssertTrue(result.standardError.contains(url.path))
                XCTAssertEqual(try Data(contentsOf: url), original, "\(arguments)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("agents").path))
            }
        }
    }

    func testUnreadableConfigurationIsPreservedByCLI() throws {
        try requireNonRoot()
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = Data(#"{"enabled":true,"devices":[]}"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        for arguments in [["disable"], ["enable"], ["setup", "--daemon", "/unused/daemon"]] {
            let result = try invoke(arguments, directory: directory)
            XCTAssertEqual(result.terminationStatus, 1, "\(arguments): \(result.standardError)")
            XCTAssertTrue(result.standardError.contains(url.path))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOnlyInitialCreationCommandsAcceptMissingConfiguration() throws {
        try requireNonRoot()
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        for arguments in [["enable"], ["disable"], ["devices"], ["status"]] {
            let result = try invoke(arguments, directory: directory)
            XCTAssertEqual(result.terminationStatus, 1, "\(arguments): \(result.standardError)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.configURL.path))
        }
        let added = try invoke([
            "device", "add", "New", "--on", "NeverRunOn", "--off", "NeverRunOff", "--power-off", "none"
        ], directory: directory)
        XCTAssertEqual(added.terminationStatus, 0, added.standardError)
        let config = try store.load()
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.devices.count, 1)
        XCTAssertEqual(config.devices[0].actions.powerOff, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("agents").path))
    }

    func testDeviceUpdatesPreserveDisabledAndNoneBehavior() throws {
        try requireNonRoot()
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(VirtConnectorConfig(devices: [
            ShortcutDevice(name: "Review", onShortcut: "NeverRunOn", offShortcut: "NeverRunOff")
        ]))
        let result = try invoke([
            "device", "set", "Review", "--enabled", "false", "--display-off", "none"
        ], directory: directory)
        XCTAssertEqual(result.terminationStatus, 0, result.standardError)
        let config = try store.load()
        XCTAssertFalse(config.devices[0].enabled)
        XCTAssertEqual(config.devices[0].actions.displayOff, .none)
        XCTAssertEqual(config.devices[0].actions.displayOn, .on)
        let disabled = try invoke(["disable"], directory: directory)
        XCTAssertEqual(disabled.terminationStatus, 0, disabled.standardError)
        XCTAssertFalse(try store.load().enabled)
    }

    func testEnableReportsStartupFailureSeparatelyFromEnabledConfiguration() throws {
        try requireNonRoot()
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(VirtConnectorConfig(enabled: false))
        let manager = LaunchAgentManager(
            plistURL: directory.appendingPathComponent("agents/\(LaunchAgentManager.label).plist"),
            logDirectory: directory.appendingPathComponent("logs"), configURL: store.configURL
        )
        try manager.install(daemonPath: "/custom/never-executed-daemon")

        // The sandbox prevents launchctl from executing; this exercises the real CLI failure path.
        let result = try invoke(["enable"], directory: directory)
        XCTAssertEqual(result.terminationStatus, 1, result.standardError)
        XCTAssertTrue(result.standardError.contains("Configuration is enabled, but the LaunchAgent could not be started"))
        XCTAssertFalse(result.standardOutput.contains("Monitoring enabled"))
        XCTAssertTrue(try store.load().enabled)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: manager.installedPlistPath)), format: nil
        ) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/custom/never-executed-daemon"])
    }

    func testRestartRefreshesLegacyPlistBeforeBlockedStartup() throws {
        try requireNonRoot()
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plistURL = directory.appendingPathComponent("agents/\(LaunchAgentManager.label).plist")
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy: [String: Any] = [
            "Label": LaunchAgentManager.label,
            "ProgramArguments": ["/custom/never-executed-daemon"]
        ]
        try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0).write(to: plistURL)
        let result = try invoke(["restart-agent"], directory: directory)
        XCTAssertEqual(result.terminationStatus, 1, result.standardError)
        XCTAssertFalse(result.standardOutput.contains("Restarted LaunchAgent"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/custom/never-executed-daemon"])
        XCTAssertEqual(plist["MachServices"] as? [String: Bool], [LaunchAgentManager.label: true])
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(environment["VIRT_CONNECTOR_CONFIG"], directory.appendingPathComponent("config.json").path)
        XCTAssertEqual(environment["VIRT_CONNECTOR_LOG_DIR"], directory.appendingPathComponent("logs").path)
    }

    private func requireNonRoot() throws {
        guard getuid() != 0 else { throw XCTSkip("The CLI intentionally rejects root") }
    }

    private func invoke(_ arguments: [String], directory: URL) throws -> ProcessResult {
        let executable = try cliExecutable(directory: directory)
        return try runInSandbox(executable, arguments, permittedExecutable: executable, directory: directory)
    }

    private func runInSandbox(
        _ executable: URL, _ arguments: [String], permittedExecutable: URL, directory: URL
    ) throws -> ProcessResult {
        let home = try XCTUnwrap(FileManager.default.homeDirectory(forUser: NSUserName()))
        // Deny service execution and writes to the real managed paths even if validation regresses.
        let profile = """
        (version 1)
        (allow default)
        (deny process-exec (require-not (literal "\(sandboxEscape(permittedExecutable.path))")))
        (deny process-exec
            (literal "/bin/launchctl")
            (literal "/usr/bin/shortcuts")
            (literal "/usr/bin/osascript"))
        (deny file-write*
            (subpath "\(sandboxEscape(home.appendingPathComponent(".config/virt-connector").path))")
            (subpath "\(sandboxEscape(home.appendingPathComponent("Library/LaunchAgents").path))")
            (subpath "\(sandboxEscape(home.appendingPathComponent("Library/Logs").path))")
            (subpath "/Library") (subpath "/usr/local") (subpath "/opt/homebrew"))
        (deny mach-lookup (global-name "\(LaunchAgentManager.label)"))
        """
        return try ProcessRunner().run(
            "/usr/bin/env",
            [
                "VIRT_CONNECTOR_CONFIG=\(directory.appendingPathComponent("config.json").path)",
                "VIRT_CONNECTOR_LOG_DIR=\(directory.appendingPathComponent("logs").path)",
                "VIRT_CONNECTOR_LAUNCH_AGENTS_DIR=\(directory.appendingPathComponent("agents").path)",
                "TMPDIR=\(directory.path)/",
                "/usr/bin/sandbox-exec", "-p", profile, executable.path
            ] + arguments,
            allowNonZeroExit: true, timeout: 5
        )
    }

    private func cliExecutable(directory: URL) throws -> URL {
        if let validatedExecutable { return validatedExecutable }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("sandbox-exec is unavailable; refusing to run CLI subprocess tests without isolation")
        }
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("virt-connector")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build virt-connector alongside the test bundle before running CLI integration tests")
        }
        let probe = try runInSandbox(
            URL(fileURLWithPath: "/usr/bin/true"), [], permittedExecutable: executable, directory: directory
        )
        guard probe.terminationStatus != 0 else {
            XCTFail("Sandbox did not block the harmless execution probe; no CLI command will be run")
            throw XCTSkip("Sandbox isolation is not enforced")
        }
        let help = try runInSandbox(executable, ["--help"], permittedExecutable: executable, directory: directory)
        guard help.terminationStatus == 0 else {
            throw XCTSkip(
                "Sandboxed CLI preflight failed; refusing an unsandboxed fallback: \(help.standardError)"
            )
        }
        guard help.standardOutput.contains("setup and device add may create a missing configuration.") else {
            throw XCTSkip("Rebuild virt-connector; refusing to test a stale CLI with unsafe argument handling")
        }
        validatedExecutable = executable
        return executable
    }

    private func sandboxEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
