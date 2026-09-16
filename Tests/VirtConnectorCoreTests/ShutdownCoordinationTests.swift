import Foundation
import XCTest
@testable import VirtConnectorCore

final class ShutdownCoordinationTests: XCTestCase {
    func testFailedActionsPreserveReasonsAndPreventSystemShutdown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(VirtConnectorConfig(devices: [
            ShortcutDevice(name: "First", onShortcut: "On", offShortcut: "Fail"),
            ShortcutDevice(name: "Second", onShortcut: "On", offShortcut: "Success")
        ]))
        let runner = RecordingProcessRunner()
        let executor = ActionExecutor(shortcutRunner: ShortcutRunner(processRunner: runner))
        let performer = ShutdownPerformer(configStore: store, actionExecutor: executor, processRunner: runner)
        XCTAssertThrowsError(try performer.perform()) { error in
            let result = (error as? ActionExecutionError)?.result
            XCTAssertEqual(result?.attempted, 2)
            XCTAssertEqual(result?.failed, 1)
            XCTAssertEqual(result?.failures.first?.device, "First")
            XCTAssertTrue(error.localizedDescription.contains("simulated failure"))
        }
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertFalse(runner.calls.contains { $0.0 == "/usr/bin/osascript" })
    }

    func testDisabledAndNoneActionsDoNotRunShortcuts() throws {
        let runner = RecordingProcessRunner()
        let executor = ActionExecutor(shortcutRunner: ShortcutRunner(processRunner: runner))
        let device = ShortcutDevice(
            name: "No action", onShortcut: "On", offShortcut: "Off",
            actions: TriggerActions(powerOff: .none)
        )
        XCTAssertEqual(executor.execute(trigger: .powerOff, config: VirtConnectorConfig(devices: [device])).attempted, 0)
        XCTAssertEqual(executor.execute(trigger: .displayOn, config: VirtConnectorConfig(enabled: false, devices: [device])).attempted, 0)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testShutdownWaitsForInflightActionDropsQueuedEventsAndDeduplicates() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let events = LockedValues<PowerTrigger>()
        let osCalls = LockedValues<Bool>()
        let coordinator = PowerEventCoordinator(execute: { trigger in
            events.append(trigger)
            if trigger == .displayOn {
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            }
            return ActionExecutionResult(attempted: 1)
        }, requestShutdown: { osCalls.append(true) })
        coordinator.handleDisplayEvent(.displayOn, reason: "test")
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        coordinator.handleDisplayEvent(.displayOff, reason: "queued")
        let first = expectation(description: "menu request")
        let duplicate = expectation(description: "OS notification")
        coordinator.shutdown { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            first.fulfill()
        }
        coordinator.shutdown(requestSystemShutdown: false) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            duplicate.fulfill()
        }
        release.signal()
        wait(for: [first, duplicate], timeout: 3)
        XCTAssertEqual(events.values, [.displayOn, .powerOff])
        XCTAssertEqual(osCalls.values.count, 1)
        let rejected = expectation(description: "manual operation rejected")
        coordinator.run(.displayOn) { result in
            if case .success = result { XCTFail("Manual action must be rejected during shutdown") }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
        XCTAssertEqual(events.values, [.displayOn, .powerOff])
    }

    func testTerminationDoesNotWaitForShutdownAppleEventResponse() {
        let osStarted = DispatchSemaphore(value: 0)
        let releaseOS = DispatchSemaphore(value: 0)
        let coordinator = PowerEventCoordinator(
            execute: { _ in ActionExecutionResult() },
            requestShutdown: {
                osStarted.signal()
                XCTAssertEqual(releaseOS.wait(timeout: .now() + 3), .success)
            }
        )
        let finished = expectation(description: "shutdown finished")
        coordinator.shutdown { _ in finished.fulfill() }
        XCTAssertEqual(osStarted.wait(timeout: .now() + 2), .success)
        let ready = expectation(description: "ready before OS reply")
        coordinator.whenReadyToTerminate { ready.fulfill() }
        wait(for: [ready], timeout: 1)
        releaseOS.signal()
        wait(for: [finished], timeout: 2)
    }

    func testFailureAllowsRetryAndCanceledShutdownCanResume() throws {
        let actions = LockedValues<PowerTrigger>()
        let osCalls = LockedValues<Bool>()
        let coordinator = PowerEventCoordinator(execute: { trigger in
            actions.append(trigger)
            if actions.values.count == 1 {
                return ActionExecutionResult(attempted: 1, failures: [
                    ActionFailure(device: "Lamp", shortcut: "Off", message: "offline")
                ])
            }
            return ActionExecutionResult(attempted: 1)
        }, requestShutdown: { osCalls.append(true) })
        let failed = expectation(description: "first request failed")
        coordinator.shutdown { result in
            if case .success = result { XCTFail("A failed action must prevent shutdown") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 2)
        XCTAssertTrue(osCalls.values.isEmpty)
        XCTAssertFalse(coordinator.canResume)
        let success = expectation(description: "retry succeeded")
        coordinator.shutdown { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            success.fulfill()
        }
        wait(for: [success], timeout: 2)
        XCTAssertTrue(coordinator.canResume)
        try coordinator.resumeAfterCancelledShutdown()
        XCTAssertFalse(coordinator.canResume)
        let display = expectation(description: "display resumed")
        coordinator.run(.displayOn) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            display.fulfill()
        }
        wait(for: [display], timeout: 2)
        XCTAssertEqual(actions.values, [.powerOff, .powerOff, .displayOn])
        XCTAssertEqual(osCalls.values.count, 1)
    }

    func testExternalShutdownDoesNotRequestAnotherSystemShutdown() {
        let actions = LockedValues<PowerTrigger>()
        let coordinator = PowerEventCoordinator(
            execute: { actions.append($0); return ActionExecutionResult() },
            requestShutdown: { XCTFail("must not issue another OS request") }
        )
        let completed = expectation(description: "external notification")
        coordinator.shutdown(requestSystemShutdown: false) { _ in completed.fulfill() }
        wait(for: [completed], timeout: 2)
        let duplicate = expectation(description: "duplicate")
        coordinator.shutdown { _ in duplicate.fulfill() }
        wait(for: [duplicate], timeout: 2)
        XCTAssertEqual(actions.values, [.powerOff])
    }

    func testOSRequestFailureReturnsToNormalEventHandling() {
        let events = LockedValues<PowerTrigger>()
        let coordinator = PowerEventCoordinator(
            execute: { events.append($0); return ActionExecutionResult(attempted: 1) },
            requestShutdown: { throw AgentCommunicationError("OS shutdown canceled") }
        )
        let canceled = expectation(description: "OS request canceled")
        coordinator.shutdown { result in
            if case .success = result { XCTFail("OS request failure must be reported") }
            canceled.fulfill()
        }
        wait(for: [canceled], timeout: 2)
        XCTAssertFalse(coordinator.isShutdownPending)
        XCTAssertFalse(coordinator.canResume)
        let resumed = expectation(description: "normal events resume")
        coordinator.run(.displayOn) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            resumed.fulfill()
        }
        wait(for: [resumed], timeout: 2)
        XCTAssertEqual(events.values, [.powerOff, .displayOn])
    }

    func testTerminationWaitsForPowerOffActionsButNotAdditionalNotifications() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readiness = LockedValues<Bool>()
        let coordinator = PowerEventCoordinator(execute: { _ in
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            return ActionExecutionResult()
        }, requestShutdown: { XCTFail("external shutdown") })
        let shutdown = expectation(description: "power off completed")
        coordinator.shutdown(requestSystemShutdown: false) { _ in shutdown.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let ready = expectation(description: "ready to terminate")
        coordinator.whenReadyToTerminate { readiness.append(true); ready.fulfill() }
        XCTAssertTrue(readiness.values.isEmpty)
        release.signal()
        wait(for: [shutdown, ready], timeout: 2)
        XCTAssertEqual(readiness.values.count, 1)
    }

    func testAgentStopDropsPendingShutdownWithoutPowerOff() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let actions = LockedValues<PowerTrigger>()
        let coordinator = PowerEventCoordinator(execute: { trigger in
            actions.append(trigger)
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            return ActionExecutionResult()
        }, requestShutdown: { XCTFail("agent stop must not request OS shutdown") })
        coordinator.handleDisplayEvent(.displayOn, reason: "in flight")
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let canceled = expectation(description: "queued shutdown canceled")
        coordinator.shutdown { result in
            if case .success = result { XCTFail("queued shutdown should not execute") }
            canceled.fulfill()
        }
        let stopped = expectation(description: "agent drained")
        coordinator.stop { stopped.fulfill() }
        release.signal()
        wait(for: [canceled, stopped], timeout: 2)
        XCTAssertEqual(actions.values, [.displayOn])
    }
}

final class RecordingProcessRunner: ProcessRunning {
    private let recorded = LockedValues<(String, [String])>()
    var calls: [(String, [String])] { recorded.values }

    func run(_ executable: String, _ arguments: [String], allowNonZeroExit: Bool, timeout: TimeInterval) throws -> ProcessResult {
        recorded.append((executable, arguments))
        if arguments.contains("Fail") {
            throw AgentCommunicationError("simulated failure")
        }
        return ProcessResult(terminationStatus: 0, standardOutput: "", standardError: "")
    }
}

final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
