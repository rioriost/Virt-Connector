import Foundation
import Darwin

public final class FileLog {
    private let url: URL
    private let formatter: ISO8601DateFormatter
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public static func daemonLog() -> FileLog {
        FileLog(url: ConfigStore.logsDirectoryURL().appendingPathComponent("virt-connectord.log"))
    }

    public func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        fputs(line, stdout)

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            fputs("failed to write log: \(error)\n", stderr)
        }
    }
}
