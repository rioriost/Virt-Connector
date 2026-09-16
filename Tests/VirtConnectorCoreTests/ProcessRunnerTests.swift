import Darwin
import Foundation
import XCTest
@testable import VirtConnectorCore

final class ProcessRunnerTests: XCTestCase {
    private let runner = ProcessRunner()
    private let megabyte = 1024 * 1024
    private let python = "/usr/bin/python3"

    func testSmallOutputAndPublicResultInitializer() throws {
        let result = try runner.run("/bin/sh", ["-c", "printf hello; printf warning >&2"])
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, "hello")
        XCTAssertEqual(result.standardError, "warning")
        XCTAssertEqual(ProcessResult(terminationStatus: 7, standardOutput: "out", standardError: "err").terminationStatus, 7)
    }

    func testOneMiBStandardOutput() throws {
        let result = try runPython("import sys; sys.stdout.write('o' * \(megabyte))")
        XCTAssertEqual(result.standardOutput, String(repeating: "o", count: megabyte))
        XCTAssertEqual(result.standardError, "")
    }

    func testOneMiBStandardError() throws {
        let result = try runPython("import sys; sys.stderr.write('e' * \(megabyte))")
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.standardError, String(repeating: "e", count: megabyte))
    }

    func testOneMiBOnBothStreamsConcurrently() throws {
        let result = try runPython("""
            import sys, threading
            threads = [
                threading.Thread(target=lambda: sys.stdout.write('o' * \(megabyte))),
                threading.Thread(target=lambda: sys.stderr.write('e' * \(megabyte)))
            ]
            for thread in threads: thread.start()
            for thread in threads: thread.join()
            """)
        XCTAssertEqual(result.standardOutput, String(repeating: "o", count: megabyte))
        XCTAssertEqual(result.standardError, String(repeating: "e", count: megabyte))
    }

    func testNonZeroExitIncludesStandardError() throws {
        XCTAssertThrowsError(try runner.run("/bin/sh", ["-c", "printf 'failure\\n' >&2; exit 17"])) { error in
            guard case let ProcessRunnerError.nonZeroExit(executable, arguments, status, stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(executable, "/bin/sh")
            XCTAssertEqual(arguments.first, "-c")
            XCTAssertEqual(status, 17)
            XCTAssertEqual(stderr, "failure")
        }
        let result = try runner.run("/bin/sh", ["-c", "printf detail >&2; exit 17"], allowNonZeroExit: true)
        XCTAssertEqual(result.terminationStatus, 17)
        XCTAssertEqual(result.standardError, "detail")
    }

    func testStartupFailureIsTyped() {
        let missing = FileManager.default.currentDirectoryPath + "/process-runner-missing-\(UUID().uuidString)"
        XCTAssertThrowsError(try runner.run(missing)) { error in
            guard case let ProcessRunnerError.launchFailed(executable, _, reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(executable, missing)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testPrecancelledTokenPreventsLaunch() {
        let cancellation = ProcessCancellation()
        XCTAssertFalse(cancellation.isCancelled)
        cancellation.cancel()
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)

        let runner = ProcessRunner(cancellation: cancellation)
        let missing = FileManager.default.currentDirectoryPath + "/process-runner-cancelled-\(UUID().uuidString)"
        XCTAssertThrowsError(try runner.run(missing, ["never-launched"], allowNonZeroExit: true)) { error in
            guard case let ProcessRunnerError.cancelled(executable, arguments, stdout, stderr) = error else {
                return XCTFail("Cancellation must be checked before attempting to launch: \(error)")
            }
            XCTAssertEqual(executable, missing)
            XCTAssertEqual(arguments, ["never-launched"])
            XCTAssertEqual(stdout, "")
            XCTAssertEqual(stderr, "")
        }
    }

    func testActiveCancellationStopsOwnedGroupAndReapsRootPromptly() throws {
        try requirePython()
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/process-runner-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let cancellation = ProcessCancellation()
        let runner = ProcessRunner(maximumOutputBytes: 1024, cancellation: cancellation)
        let cancellationSent = expectation(description: "Cancellation sent after the child is running")
        DispatchQueue.global().async {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !FileManager.default.fileExists(atPath: ready.path)
                && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            cancellation.cancel()
            cancellationSent.fulfill()
        }

        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try runner.run(python, ["-c", """
            import os, signal, subprocess, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            child = subprocess.Popen([
                \(String(reflecting: python)), '-c',
                'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'
            ])
            print(os.getpid(), child.pid, flush=True)
            print('cancellation detail', file=sys.stderr, flush=True)
            with open(\(String(reflecting: ready.path)), 'w') as ready: ready.write('ready')
            time.sleep(60)
            """], allowNonZeroExit: true, timeout: 5)) { error in
            guard case let ProcessRunnerError.cancelled(_, _, stdout, stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stderr, "cancellation detail\n")
            let pids = stdout.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            XCTAssertEqual(pids.count, 2)
            for pid in pids { assertGone(pid) }
            if let root = pids.first {
                var status: Int32 = 0
                XCTAssertEqual(waitpid(root, &status, WNOHANG), -1)
                XCTAssertEqual(errno, ECHILD, "The cancelled root must already have been reaped")
            }
        }
        wait(for: [cancellationSent], timeout: 1)
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    func testTimeoutKillsAndReapsTERMResistantChildWithinThreeSeconds() throws {
        try requirePython()
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: python)
        unrelated.arguments = ["-c", "import time; time.sleep(60)"]
        try unrelated.run()
        defer {
            if unrelated.isRunning { kill(unrelated.processIdentifier, SIGKILL) }
            unrelated.waitUntilExit()
        }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try runner.run(python, ["-c", """
            import os, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            print(os.getpid(), flush=True)
            print('timeout detail', file=sys.stderr, flush=True)
            time.sleep(60)
            """], timeout: 1)) { error in
            guard case let ProcessRunnerError.timedOut(_, _, timeout, stdout, stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(timeout, 1)
            XCTAssertEqual(stderr, "timeout detail\n")
            guard let pid = pid_t(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return XCTFail("Missing child PID: \(stdout)")
            }
            assertGone(pid)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD, "Root must already have been reaped")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        XCTAssertTrue(unrelated.isRunning, "A sibling outside the runner's process group must not be signalled")
    }

    func testTimeoutKillsDescendantWithInheritedDescriptors() throws {
        try requirePython()
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try runner.run(python, ["-c", """
            import os, signal, subprocess, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            child = subprocess.Popen([
                \(String(reflecting: python)), '-c',
                'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'
            ])
            print(os.getpid(), child.pid, flush=True)
            time.sleep(60)
            """], allowNonZeroExit: true, timeout: 1)) { error in
            guard case let ProcessRunnerError.timedOut(_, _, _, stdout, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            let pids = stdout.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            XCTAssertEqual(pids.count, 2)
            for pid in pids { assertGone(pid) }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    func testExitedRootDoesNotWaitForInheritedPipeDescriptors() throws {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try runPython("""
            import subprocess
            child = subprocess.Popen([
                \(String(reflecting: python)), '-c',
                'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'
            ])
            print(child.pid, flush=True)
            """, timeout: 1)
        XCTAssertEqual(result.terminationStatus, 0)
        let pid = try XCTUnwrap(pid_t(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
        assertGone(pid)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    func testOutputLimitStopsChildAndIncludesBoundedOutput() throws {
        try requirePython()
        let bounded = ProcessRunner(maximumOutputBytes: 1024)
        XCTAssertThrowsError(try bounded.run(python, ["-c", """
            import sys, time
            print('diagnostic', file=sys.stderr, flush=True)
            sys.stdout.write('x' * \(megabyte))
            sys.stdout.flush()
            time.sleep(60)
            """], timeout: 1)) { error in
            guard case let ProcessRunnerError.outputLimitExceeded(_, _, limit, stdout, stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(limit, 1024)
            XCTAssertEqual(stdout, String(repeating: "x", count: 1024))
            XCTAssertEqual(stderr, "diagnostic\n")
        }
    }

    func testStandardErrorHasAnIndependentOutputLimit() throws {
        try requirePython()
        let bounded = ProcessRunner(maximumOutputBytes: 1024)
        XCTAssertThrowsError(try bounded.run(python, ["-c", """
            import sys
            print('diagnostic', flush=True)
            sys.stderr.write('e' * \(megabyte))
            """], timeout: 1)) { error in
            guard case let ProcessRunnerError.outputLimitExceeded(_, _, limit, stdout, stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(limit, 1024)
            XCTAssertEqual(stdout, "diagnostic\n")
            XCTAssertEqual(stderr, String(repeating: "e", count: 1024))
        }
    }

    func testInvalidUTF8IsNotSilentlyDiscarded() throws {
        let result = try runPython("import os; os.write(1, b'prefix\\xffsuffix')")
        XCTAssertEqual(result.standardOutput, "prefix\u{fffd}suffix")
    }

    func testInvalidTimeoutDoesNotLaunch() {
        for timeout in [0, -1, .infinity, .nan] {
            XCTAssertThrowsError(try runner.run("/bin/sh", ["-c", "exit 99"], timeout: timeout)) { error in
                guard case ProcessRunnerError.invalidTimeout = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testProtocolConveniencesForwardToRequiredMethod() throws {
        final class RecordingRunner: ProcessRunning {
            var calls: [(String, [String], Bool, TimeInterval)] = []
            func run(_ executable: String, _ arguments: [String], allowNonZeroExit: Bool, timeout: TimeInterval) throws -> ProcessResult {
                calls.append((executable, arguments, allowNonZeroExit, timeout))
                return ProcessResult(terminationStatus: 0)
            }
        }
        let recording = RecordingRunner()
        let runner: any ProcessRunning = recording
        try runner.run("first")
        try runner.run("second", ["arg"], allowNonZeroExit: true)
        try runner.run("third", timeout: 2)
        try runner.run("fourth", [], allowNonZeroExit: true, timeout: 3)
        XCTAssertEqual(recording.calls.map(\.0), ["first", "second", "third", "fourth"])
        XCTAssertEqual(recording.calls.map(\.1), [[], ["arg"], [], []])
        XCTAssertEqual(recording.calls.map(\.2), [false, true, false, true])
        XCTAssertEqual(recording.calls.map(\.3), [30, 30, 2, 3])
    }

    private func runPython(_ script: String, timeout: TimeInterval = 5) throws -> ProcessResult {
        try requirePython()
        return try runner.run(python, ["-c", script], timeout: timeout)
    }

    private func requirePython() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "System Python is needed for safe output fixtures")
    }

    private func assertGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(kill(pid, 0), -1, "Owned PID \(pid) is still present", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}
