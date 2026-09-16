import Foundation
import Darwin

public struct ProcessResult {
    public var terminationStatus: Int32
    public var standardOutput: String
    public var standardError: String

    public init(terminationStatus: Int32, standardOutput: String = "", standardError: String = "") {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessRunning {
    @discardableResult
    func run(
        _ executable: String,
        _ arguments: [String],
        allowNonZeroExit: Bool,
        timeout: TimeInterval
    ) throws -> ProcessResult
}

public extension ProcessRunning {
    @discardableResult
    func run(
        _ executable: String,
        _ arguments: [String] = [],
        allowNonZeroExit: Bool = false
    ) throws -> ProcessResult {
        try run(executable, arguments, allowNonZeroExit: allowNonZeroExit, timeout: 30)
    }

    @discardableResult
    func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        try run(executable, arguments, allowNonZeroExit: false, timeout: timeout)
    }
}

/// One-way cancellation shared by runners. Use from normal threads or dispatch handlers,
/// not a raw POSIX signal handler: locking is not async-signal-safe.
public final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

public enum ProcessRunnerError: LocalizedError {
    case nonZeroExit(executable: String, arguments: [String], status: Int32, stderr: String)
    case invalidTimeout(TimeInterval)
    case launchFailed(executable: String, arguments: [String], reason: String)
    case timedOut(executable: String, arguments: [String], timeout: TimeInterval, stdout: String, stderr: String)
    case cancelled(executable: String, arguments: [String], stdout: String, stderr: String)
    case outputLimitExceeded(executable: String, arguments: [String], limit: Int, stdout: String, stderr: String)
    case outputReadFailed(executable: String, arguments: [String], reason: String, stdout: String, stderr: String)
    case cleanupFailed(executable: String, arguments: [String], reason: String, stdout: String, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .nonZeroExit(executable, arguments, status, stderr):
            let command = ([executable] + arguments).joined(separator: " ")
            return "`\(command)` exited with status \(status): \(stderr)"
        case let .invalidTimeout(timeout):
            return "Process timeout must be finite and greater than zero (received \(timeout))."
        case let .launchFailed(executable, arguments, reason):
            return "`\(([executable] + arguments).joined(separator: " "))` could not launch: \(reason)"
        case let .timedOut(executable, arguments, timeout, stdout, stderr):
            return describe(executable, arguments, "timed out after \(timeout) seconds", stdout, stderr)
        case let .cancelled(executable, arguments, stdout, stderr):
            return describe(executable, arguments, "was cancelled", stdout, stderr)
        case let .outputLimitExceeded(executable, arguments, limit, stdout, stderr):
            return describe(executable, arguments, "exceeded the \(limit)-byte per-stream output limit", stdout, stderr)
        case let .outputReadFailed(executable, arguments, reason, stdout, stderr):
            return describe(executable, arguments, "could not collect output: \(reason)", stdout, stderr)
        case let .cleanupFailed(executable, arguments, reason, stdout, stderr):
            return describe(executable, arguments, "could not complete cleanup: \(reason)", stdout, stderr)
        }
    }

    private func describe(_ executable: String, _ arguments: [String], _ reason: String, _ stdout: String, _ stderr: String) -> String {
        "`\(([executable] + arguments).joined(separator: " "))` \(reason).\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
    }
}

public struct ProcessRunner: ProcessRunning {
    /// Capture is bounded independently for stdout and stderr. Exceeding either limit stops the subprocess.
    public let maximumOutputBytes: Int
    private let cancellation: ProcessCancellation?

    public init(maximumOutputBytes: Int = 4 * 1024 * 1024, cancellation: ProcessCancellation? = nil) {
        precondition(maximumOutputBytes >= 0)
        self.maximumOutputBytes = maximumOutputBytes
        self.cancellation = cancellation
    }

    /// Execution is followed by a 0.15-second termination budget and a 0.5-second pipe cleanup budget.
    ///
    /// The child starts in its own process group, and remaining group members are stopped even after
    /// a successful root exit. Deliberately detached descendants (setsid/setpgid) are not group members;
    /// their inherited pipes are closed after the cleanup deadline rather than waited on indefinitely.
    @discardableResult
    public func run(
        _ executable: String,
        _ arguments: [String] = [],
        allowNonZeroExit: Bool = false,
        timeout: TimeInterval = 30
    ) throws -> ProcessResult {
        guard timeout.isFinite && timeout > 0 else {
            throw ProcessRunnerError.invalidTimeout(timeout)
        }
        try checkCancellation(executable, arguments)
        let outputPipe: CapturePipe
        let errorPipe: CapturePipe
        let pid: pid_t
        do {
            guard !([executable] + arguments).contains(where: { $0.utf8.contains(0) }) else {
                throw POSIXError(.EINVAL)
            }
            outputPipe = try CapturePipe()
            errorPipe = try CapturePipe()
            pid = try spawn(executable, arguments, output: outputPipe, error: errorPipe)
        } catch let error as ProcessRunnerError {
            throw error
        } catch {
            throw ProcessRunnerError.launchFailed(executable: executable, arguments: arguments, reason: error.localizedDescription)
        }
        outputPipe.closeWriter()
        errorPipe.closeWriter()

        let pipes = [outputPipe, errorPipe]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var failure: CaptureFailure?
        var rootExited = false
        var ownershipLost = false
        var cleanupError: String?
        let deadline = ProcessInfo.processInfo.systemUptime + timeout

        func collectOutput() {
            for pipe in pipes {
                do {
                    if try pipe.drain(into: &buffer, limit: maximumOutputBytes), failure == nil {
                        failure = .limit
                    }
                } catch {
                    if failure == nil { failure = .read(error.localizedDescription) }
                    pipe.closeReader()
                }
            }
        }

        func observeExit() {
            guard !rootExited && !ownershipLost else { return }
            var info = siginfo_t()
            // Keep the leader unreaped until the final group signal: its PID/PGID cannot be reused.
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                rootExited = info.si_pid == pid
            } else if errno != EINTR {
                cleanupError = "waitid: \(String(cString: strerror(errno)))"
                ownershipLost = errno == ECHILD
            }
        }

        func waitForOutput() {
            var descriptors = pipes.map { pollfd(fd: $0.reader, events: Int16(POLLIN), revents: 0) }
            if poll(&descriptors, nfds_t(descriptors.count), 10) < 0 && errno != EINTR && failure == nil {
                failure = .read("poll: \(String(cString: strerror(errno)))")
            }
        }

        // Nonblocking, fair reads multiplex both streams while the child is still running.
        while failure == nil && cleanupError == nil && !rootExited {
            if cancellation?.isCancelled == true { failure = .cancelled }
            collectOutput()
            observeExit()
            if failure == nil && !rootExited && ProcessInfo.processInfo.systemUptime >= deadline {
                failure = .timeout
            }
            if failure == nil && cleanupError == nil && !rootExited { waitForOutput() }
        }

        if !ownershipLost {
            if !rootExited {
                kill(-pid, SIGTERM)
                let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.15
                while !rootExited && !ownershipLost && ProcessInfo.processInfo.systemUptime < graceDeadline {
                    collectOutput()
                    observeExit()
                    if !rootExited { waitForOutput() }
                }
            }
            if !ownershipLost {
                // A fresh process group is established atomically by posix_spawn, never by a racy
                // setpgid after Process.run(). Only this invocation's group is signalled.
                kill(-pid, SIGKILL)
                let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 0.5
                while (!rootExited || pipes.contains(where: { $0.reader >= 0 }))
                    && !ownershipLost && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
                    collectOutput()
                    observeExit()
                    if !rootExited || pipes.contains(where: { $0.reader >= 0 }) { waitForOutput() }
                }
            }
        }

        if pipes.contains(where: { $0.reader >= 0 }) && failure == nil {
            failure = .read("Inherited output descriptors remained open after subprocess group cleanup.")
        }
        pipes.forEach { $0.closeReader() }

        var status: Int32 = 0
        if !ownershipLost {
            var waited: pid_t
            repeat {
                waited = waitpid(pid, &status, WNOHANG)
            } while waited < 0 && errno == EINTR
            if waited != pid {
                cleanupError = "The child has not been reaped after SIGKILL."
                if waited == 0 {
                    // SIGKILL may be delayed by kernel I/O. Never turn that into an unbounded caller
                    // wait; a dedicated, PID-specific reaper retains responsibility for this child.
                    DispatchQueue.global(qos: .utility).async {
                        var finalStatus: Int32 = 0
                        while waitpid(pid, &finalStatus, 0) < 0 && errno == EINTR {}
                    }
                }
            }
        }

        let output = String(decoding: outputPipe.data, as: UTF8.self)
        let error = String(decoding: errorPipe.data, as: UTF8.self)
        if let cleanupError {
            throw ProcessRunnerError.cleanupFailed(
                executable: executable, arguments: arguments, reason: cleanupError, stdout: output, stderr: error
            )
        }
        switch failure {
        case .timeout:
            throw ProcessRunnerError.timedOut(
                executable: executable, arguments: arguments, timeout: timeout, stdout: output, stderr: error
            )
        case .cancelled:
            throw ProcessRunnerError.cancelled(
                executable: executable, arguments: arguments, stdout: output, stderr: error
            )
        case .limit:
            throw ProcessRunnerError.outputLimitExceeded(
                executable: executable, arguments: arguments, limit: maximumOutputBytes, stdout: output, stderr: error
            )
        case let .read(reason):
            throw ProcessRunnerError.outputReadFailed(
                executable: executable, arguments: arguments, reason: reason, stdout: output, stderr: error
            )
        case nil:
            break
        }

        let terminationStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status & 0x7f
        if terminationStatus != 0 && !allowNonZeroExit {
            throw ProcessRunnerError.nonZeroExit(
                executable: executable,
                arguments: arguments,
                status: terminationStatus,
                stderr: error.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return ProcessResult(
            terminationStatus: terminationStatus,
            standardOutput: output,
            standardError: error
        )
    }

    private func checkCancellation(_ executable: String, _ arguments: [String]) throws {
        if cancellation?.isCancelled == true {
            throw ProcessRunnerError.cancelled(executable: executable, arguments: arguments, stdout: "", stderr: "")
        }
    }

    private func spawn(_ executable: String, _ arguments: [String], output: CapturePipe, error: CapturePipe) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }

        try checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0))
        try checkPOSIX(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        ))
        var signals = sigset_t()
        sigemptyset(&signals)
        try checkPOSIX(posix_spawnattr_setsigmask(&attributes, &signals))
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGHUP] { sigaddset(&signals, signal) }
        try checkPOSIX(posix_spawnattr_setsigdefault(&attributes, &signals))
        if fcntl(STDIN_FILENO, F_GETFD) >= 0 {
            try checkPOSIX(posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO))
        }
        try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, output.writer, STDOUT_FILENO))
        try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, error.writer, STDERR_FILENO))
        for descriptor in [output.reader, output.writer, error.reader, error.writer] {
            try checkPOSIX(posix_spawn_file_actions_addclose(&actions, descriptor))
        }

        var argv = ([executable] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { environment.forEach { free($0) } }
        guard !argv.contains(where: { $0 == nil }), !environment.contains(where: { $0 == nil }) else {
            throw POSIXError(.ENOMEM)
        }
        argv.append(nil)
        environment.append(nil)
        var pid: pid_t = 0
        try checkCancellation(executable, arguments)
        try checkPOSIX(posix_spawn(&pid, executable, &actions, &attributes, &argv, &environment))
        return pid
    }
}

private enum CaptureFailure {
    case timeout
    case cancelled
    case limit
    case read(String)
}

private func checkPOSIX(_ code: Int32) throws {
    if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
}

private final class CapturePipe {
    private(set) var reader: Int32 = -1
    private(set) var writer: Int32 = -1
    private(set) var data = Data()

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        reader = descriptors[0]
        writer = descriptors[1]
        do {
            // Keep pipe endpoints away from stdio even if the caller has closed one of fd 0/1/2.
            reader = try prepare(reader)
            writer = try prepare(writer)
            guard fcntl(reader, F_SETFL, O_NONBLOCK) >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } catch {
            closeReader()
            closeWriter()
            throw error
        }
    }

    deinit {
        closeReader()
        closeWriter()
    }

    func closeReader() {
        if reader >= 0 { close(reader); reader = -1 }
    }

    func closeWriter() {
        if writer >= 0 { close(writer); writer = -1 }
    }

    func drain(into buffer: inout [UInt8], limit: Int) throws -> Bool {
        guard reader >= 0 else { return false }
        let count = Darwin.read(reader, &buffer, buffer.count)
        if count == 0 {
            closeReader()
            return false
        }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return false }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let available = limit - data.count
        data.append(contentsOf: buffer.prefix(min(count, available)))
        return count > available
    }

    private func prepare(_ descriptor: Int32) throws -> Int32 {
        if descriptor < STDERR_FILENO + 1 {
            let replacement = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard replacement >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            close(descriptor)
            return replacement
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }
}
