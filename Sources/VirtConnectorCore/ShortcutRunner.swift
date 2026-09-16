import Foundation

public struct ShortcutRunner {
    private let processRunner: any ProcessRunning
    private let shortcutsPath: String

    public init(processRunner: any ProcessRunning = ProcessRunner(), shortcutsPath: String = "/usr/bin/shortcuts") {
        self.processRunner = processRunner
        self.shortcutsPath = shortcutsPath
    }

    public func runShortcut(named name: String, timeout: TimeInterval = 30) throws {
        _ = try processRunner.run(shortcutsPath, ["run", name], timeout: timeout)
    }

    public func listShortcuts() throws -> [String] {
        let result = try processRunner.run(shortcutsPath, ["list"])
        return result.standardOutput
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
