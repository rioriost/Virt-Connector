import Foundation

public struct LaunchAgentManager {
    public static let label = "st.rio.virt-connectord"

    private let processRunner: ProcessRunner
    private let plistURL: URL
    private let logDirectory: URL

    public init(
        processRunner: ProcessRunner = ProcessRunner(),
        plistURL: URL = ConfigStore.launchAgentsDirectoryURL().appendingPathComponent("\(LaunchAgentManager.label).plist"),
        logDirectory: URL = ConfigStore.logsDirectoryURL()
    ) {
        self.processRunner = processRunner
        self.plistURL = plistURL
        self.logDirectory = logDirectory
    }

    public func install(daemonPath: String) throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(Self.label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(escapePlist(daemonPath))</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>ExitTimeOut</key>
          <integer>30</integer>
          <key>AssociatedBundleIdentifiers</key>
          <array>
            <string>st.rio.virt-connectord</string>
          </array>
          <key>LimitLoadToSessionType</key>
          <array>
            <string>Aqua</string>
          </array>
          <key>StandardOutPath</key>
          <string>\(escapePlist(logDirectory.appendingPathComponent("virt-connectord.out.log").path))</string>
          <key>StandardErrorPath</key>
          <string>\(escapePlist(logDirectory.appendingPathComponent("virt-connectord.err.log").path))</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
          </dict>
        </dict>
        </plist>
        """

        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    public func bootstrap() throws {
        _ = try? processRunner.run("/bin/launchctl", ["bootout", serviceTarget()], allowNonZeroExit: true)
        waitUntilUnloaded()
        _ = try processRunner.run("/bin/launchctl", ["bootstrap", serviceDomain(), plistURL.path])
        _ = try processRunner.run("/bin/launchctl", ["enable", "\(serviceDomain())/\(Self.label)"])
        _ = try processRunner.run("/bin/launchctl", ["kickstart", "-k", "\(serviceDomain())/\(Self.label)"])
    }

    public func uninstall() throws {
        _ = try? processRunner.run("/bin/launchctl", ["bootout", serviceTarget()], allowNonZeroExit: true)
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    public func printStatus() throws -> String {
        let result = try processRunner.run(
            "/bin/launchctl",
            ["print", "\(serviceDomain())/\(Self.label)"],
            allowNonZeroExit: true
        )
        return result.standardOutput + result.standardError
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

    private func waitUntilUnloaded() {
        for _ in 0..<30 {
            let result = try? processRunner.run("/bin/launchctl", ["print", serviceTarget()], allowNonZeroExit: true)
            if result?.terminationStatus != 0 {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func escapePlist(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
