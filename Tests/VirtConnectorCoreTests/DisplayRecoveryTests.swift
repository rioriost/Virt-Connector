import Foundation
import XCTest
@testable import VirtConnectorCore

final class DisplayRecoveryTests: XCTestCase {
    private let failed = ActionExecutionResult(attempted: 1, failures: [
        ActionFailure(device: "LED", shortcut: "On", message: "temporarily unavailable")
    ])

    func testWakeRetriesTransientFailureThenStopsAfterSuccess() {
        let recovered = expectation(description: "wake recovered")
        var calls = 0
        let coordinator = PowerEventCoordinator(execute: { _ in
            calls += 1
            if calls == 1 { return self.failed }
            if calls == 2 { recovered.fulfill() }
            return ActionExecutionResult(attempted: 1)
        }, requestShutdown: {}, displayRetryDelays: [0.02, 0.02])
        coordinator.handleDisplayEvent(.displayOn, reason: "wake")
        wait(for: [recovered], timeout: 1)
        let drained = expectation(description: "queue drained")
        coordinator.run(.displayOff) { _ in
            XCTAssertEqual(calls, 3) // two wake attempts, then the manual action
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
    }

    func testNewSleepCancelsPendingWakeRetry() {
        let failedWake = expectation(description: "wake failed")
        let slept = expectation(description: "slept")
        let unwantedRetry = expectation(description: "no wake retry after sleep")
        unwantedRetry.isInverted = true
        var wakeCalls = 0
        let coordinator = PowerEventCoordinator(execute: { trigger in
            if trigger == .displayOff { slept.fulfill(); return ActionExecutionResult() }
            wakeCalls += 1
            if wakeCalls == 1 { failedWake.fulfill() } else { unwantedRetry.fulfill() }
            return self.failed
        }, requestShutdown: {}, displayRetryDelays: [0.05])
        coordinator.handleDisplayEvent(.displayOn, reason: "wake")
        wait(for: [failedWake], timeout: 1)
        coordinator.handleDisplayEvent(.displayOff, reason: "sleep")
        wait(for: [slept, unwantedRetry], timeout: 0.2)
    }

    func testWakeRetriesAreBounded() {
        let attempts = expectation(description: "initial plus two retries")
        attempts.expectedFulfillmentCount = 3
        attempts.assertForOverFulfill = true
        let coordinator = PowerEventCoordinator(execute: { _ in
            attempts.fulfill()
            return self.failed
        }, requestShutdown: {}, displayRetryDelays: [0.01, 0.01])
        coordinator.handleDisplayEvent(.displayOn, reason: "wake")
        wait(for: [attempts], timeout: 1)
    }

    func testManualOffCancelsWakeRetry() {
        let wake = expectation(description: "first wake")
        let off = expectation(description: "manual off")
        let retry = expectation(description: "no retry")
        retry.isInverted = true
        var calls = 0
        let coordinator = PowerEventCoordinator(execute: { trigger in
            if trigger == .displayOff { return ActionExecutionResult() }
            calls += 1
            if calls == 1 { wake.fulfill() } else { retry.fulfill() }
            return self.failed
        }, requestShutdown: {}, displayRetryDelays: [0.05])
        coordinator.handleDisplayEvent(.displayOn, reason: "wake")
        wait(for: [wake], timeout: 1)
        coordinator.run(.displayOff) { _ in off.fulfill() }
        wait(for: [off, retry], timeout: 0.2)
    }
}
